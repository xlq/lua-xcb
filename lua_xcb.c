#define LUA_LIB
#include "lua_xcb.h"
#include "lua_xcb_xproto.h"
#include "xcb/xcbext.h"
#include "xcb/xcb_event.h"
#include "stdlib.h"

#if LUA_VERSION_NUM < 502
#define lua_getuservalue(L, n) lua_getfenv((L), (n))
#define lua_setuservalue(L, n) lua_setfenv((L), (n))
#endif

static void protect_metatable(lua_State *L)
{
    lua_pushboolean(L, false);
    lua_setfield(L, -2, "__metatable");
}

/* Convert a stack index to a positive one. */
static int abs_index(lua_State *L, int index)
{
    if (index > 0 || index < LUA_REGISTRYINDEX) return index;
    else return lua_gettop(L) + index + 1;
}

static int auto_ptr_gc(lua_State *L)
{
    void **p = lua_touserdata(L, 1);
    if (*p){
        free(*p);
        *p = NULL;
    }
    return 0;
}

/* Push a Lua userdata that will automatically free a block of memory
   by calling free(). */
static void **new_auto_ptr(lua_State *L)
{
    void **p = lua_newuserdata(L, sizeof *p);
    *p = NULL;
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, auto_ptr_gc);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    return p;
}

void lua_xcb_checkfield(lua_State *L, int index, const char *k)
{
    lua_getfield(L, index, k);
    if (lua_isnil(L, -1)){
        luaL_error(L, "Missing field: %s.", k);
    }
}

/* Push Lua representation of an xcb_generic_error_t.
   Obviously, e is not freed. */
void lua_xcb_push_generic_error(lua_State *L, xcb_generic_error_t *e)
{
    lua_createtable(L, 0, 8);
    lua_pushinteger(L, e->response_type);       lua_setfield(L, -2, "response_type");
    lua_pushinteger(L, e->error_code);          lua_setfield(L, -2, "error_code");
    lua_pushinteger(L, e->sequence);            lua_setfield(L, -2, "sequence");
    lua_pushinteger(L, e->resource_id);         lua_setfield(L, -2, "resource_id");
    lua_pushinteger(L, e->minor_code);          lua_setfield(L, -2, "minor_code");
    lua_pushinteger(L, e->major_code);          lua_setfield(L, -2, "major_code");
    lua_pushinteger(L, e->full_sequence);       lua_setfield(L, -2, "full_sequence");
    lua_pushstring(L, xcb_event_get_error_label(e->error_code)); lua_setfield(L, -2, "error_label");
}

xcb_connection_t *lua_xcb_to_conn(lua_State *L, int index)
{
    return *(xcb_connection_t **) luaL_checkudata(L, index, LUA_XCB_CONN_MT);
}

xcb_connection_t *lua_xcb_check_conn(lua_State *L, int index)
{
    xcb_connection_t *c = lua_xcb_to_conn(L, index);
    if (!c) luaL_error(L, "Attempt to use NULL xcb_connection_t *.");
    return c;
}

lua_xcb_cookie_t *lua_xcb_new_cookie(lua_State *L, int conn_index)
{
    conn_index = abs_index(L, conn_index);
    lua_xcb_check_conn(L, conn_index);
    lua_xcb_cookie_t *cookie = lua_newuserdata(L, sizeof *cookie); /* cookie */
    cookie->sequence = 0;
    cookie->push_func = NULL; /* Cookie is not in use yet. */
    /* Create environment table for cookie. */
    lua_createtable(L, 1, 0);           /* cookie env */
    /* Put reference to the connection in the environment table. */
    lua_pushvalue(L, conn_index);       /* cookie env conn */
    lua_rawseti(L, -2, 1);              /* cookie env */
    /* Set environment table. */
    lua_setuservalue(L, -2);            /* cookie */
    /* Set up the metatable. */
    luaL_getmetatable(L, LUA_XCB_COOKIE_MT);
    lua_setmetatable(L, -2);
    /* There. */
    return cookie;
}

lua_xcb_cookie_t *lua_xcb_to_cookie(lua_State *L, int index)
{
    return luaL_checkudata(L, index, LUA_XCB_COOKIE_MT);
}

void lua_xcb_reset_cookie(lua_State *L, int index)
{
    lua_xcb_cookie_t *cookie = lua_xcb_to_cookie(L, index);
    cookie->push_func = NULL;
}

static int cookie_tostring(lua_State *L)
{
    lua_xcb_cookie_t *cookie = lua_xcb_to_cookie(L, 1);
    if (lua_xcb_cookie_pending(cookie)){
        lua_pushfstring(L, "<lua_xcb_cookie_t: %p; sequence: %d>",
          (void *) cookie, (int) cookie->sequence);
    } else {
        lua_pushfstring(L, "<lua_xcb_cookie_t: %p; expired>",
          (void *) cookie);
    }
    return 1;
}

static int cookie_gc(lua_State *L)
{
    lua_xcb_cookie_t *cookie = lua_xcb_to_cookie(L, 1);
    xcb_connection_t *c;
    if (lua_xcb_cookie_pending(cookie)){
        /* The cookie is being GCed, but the reply wasn't claimed.
           Therefore, discard the reply. */
        /* Get the connection object from the environment table. */
        lua_getuservalue(L, 1);     /* cookie env */
        lua_rawgeti(L, -1, 1);      /* cookie env conn */
        lua_replace(L, -2);         /* cookie conn */
        c = lua_xcb_to_conn(L, -1);
        if (c){ /* The connection might have been closed. */
            xcb_discard_reply(c, cookie->sequence);
        }
        cookie->push_func = NULL;
    }
    return 0;
}

/* cookie:wait() - wait for a reply.
   If the request failed, nil, err is returned, where err represents
     an xcb_generic_error_t.
   If the request succeeded, but there's no reply structure
     (this happens with an xxx_checked function), true is returned.
   If the request succeeded, and there's a reply structure,
     the Lua representation of it is returned.
   Note that what exactly is returned is determined by the push_func
     function pointer from the lua_xcb_cookie_t. */
static int cookie_wait(lua_State *L)
{
    lua_xcb_cookie_t *cookie = lua_xcb_to_cookie(L, 1);
    xcb_connection_t *c;
    void **preply = new_auto_ptr(L);
    void **perror = new_auto_ptr(L);
    xcb_generic_error_t *error;
    int (* push_func)(lua_State *, void *);

    if (lua_xcb_cookie_pending(cookie)){
        push_func = cookie->push_func;
        lua_getuservalue(L, 1);
        lua_rawgeti(L, -1, 1);
        lua_replace(L, -2);
        c = lua_xcb_to_conn(L, -1);
        if (!c){
            lua_pushnil(L);
            lua_pushliteral(L, "Attempt to use cookie from a closed display.");
            return 2;
        }
        /* NOTE: This uses a function from xcbext.h, because the functions
           one's supposed to use are all request-specific. */
        if (cookie->push_func == &lua_xcb_request_checker){
            /* This request has no corresponding reply.
               We need to use xcb_request_check. */
            *perror = error = xcb_request_check(c, (xcb_void_cookie_t) {cookie->sequence});
        } else {
            *preply = xcb_wait_for_reply(c, cookie->sequence, &error);
            *perror = error;
        }
        /* We have received the reply, or an error. Before we risk losing
           control flow, set the cookie to the unused state. */
        cookie->push_func = NULL;
        /* Anything xcb_wait_for_reply or xcb_request_check allocated is now
           managed by a userdata, so we don't need to free any memory. */
        if (error){
            lua_pushnil(L);
            lua_xcb_push_generic_error(L, error);
            return 2;
        }
        /* Push and return the reply structure. */
        return push_func(L, *preply);
    } else {
        lua_pushnil(L);
        lua_pushliteral(L, "Attempt to use a cookie twice.");
        return 2;
    }
}

int lua_xcb_request_checker(lua_State *L, void *reply)
{
    /* Note: reply will be NULL. */
    lua_pushboolean(L, 1);
    return 1;
}

#define toconn(L, n) lua_xcb_check_conn(L, n)

static int conn_tostring(lua_State *L)
{
    xcb_connection_t **pp = luaL_checkudata(L, 1, LUA_XCB_CONN_MT);
    lua_pushfstring(L, "<xcb_connection_t: %p>", (void *) *pp);
    return 1;
}

static int conn_is_valid(lua_State *L)
{
    lua_pushboolean(L, 
      *(xcb_connection_t **) luaL_checkudata(L, 1, LUA_XCB_CONN_MT) != NULL);
    return 1;
}

static int conn_gc(lua_State *L)
{
    xcb_connection_t **pp = luaL_checkudata(L, 1, LUA_XCB_CONN_MT);
    if (*pp){
        puts("GCing conn.");
        xcb_disconnect(*pp);
        *pp = NULL;
    }
    return 0;
}

static int conn_flush(lua_State *L)
{
    lua_pushinteger(L, xcb_flush(toconn(L, 1)));
    return 1;
}

static int conn_get_file_descriptor(lua_State *L)
{
    lua_pushinteger(L, xcb_get_file_descriptor(toconn(L, 1)));
    return 1;
}

static int conn_has_error(lua_State *L)
{
    lua_pushboolean(L, xcb_connection_has_error(toconn(L, 1)));
    return 1;
}

static int push_event(lua_State *L, xcb_generic_event_t *event)
{
    luaL_newmetatable(L, LUA_XCB_EVENT_TABLE);
    lua_rawgeti(L, -1, event->response_type & XCB_EVENT_RESPONSE_TYPE_MASK);
    lua_replace(L, -2);
    if (lua_isnil(L, -1)){
        /* Unknown event type. */
        lua_pop(L, 1);
        lua_createtable(L, 0, 3);
        lua_pushinteger(L, event->response_type); lua_setfield(L, -2, "response_type");
        lua_pushinteger(L, event->sequence);      lua_setfield(L, -2, "sequence");
        lua_pushinteger(L, event->full_sequence); lua_setfield(L, -2, "full_sequence");
        return 1;
    } else {
        luaL_checktype(L, -1, LUA_TUSERDATA);
        return (*(lua_xcb_event_func_t *) lua_touserdata(L, -1))(L, event);
    }
}

static int conn_get_event(lua_State *L, xcb_generic_event_t *(* f)(xcb_connection_t *), const char *f_name)
{
    lua_settop(L, 1);
    void **pe = new_auto_ptr(L);
    xcb_generic_event_t *event = f(toconn(L, 1));
    *pe = event;
    if (!event){
        lua_pushnil(L);
        if (f == xcb_poll_for_event){
            /* It is quite normal for xcb_poll_for_event to return NULL. */
            return 1;
        } else {
            lua_pushfstring(L, "%s failed.", f_name);
            return 2;
        }
    }
    return push_event(L, event);
}

static int conn_wait_for_event(lua_State *L)
{
    return conn_get_event(L, xcb_wait_for_event, "xcb_wait_for_event");
}

static int conn_poll_for_event(lua_State *L)
{
    return conn_get_event(L, xcb_poll_for_event, "xcb_poll_for_event");
}
    

/* connect([displayname]) -> conn, screenp */
static int connect(lua_State *L)
{
    const char *displayname = luaL_optstring(L, 1, NULL);
    int screenp;
    xcb_connection_t **pp = lua_newuserdata(L, sizeof *pp);
    *pp = NULL;
    luaL_getmetatable(L, LUA_XCB_CONN_MT);
    lua_setmetatable(L, -2);
    *pp = xcb_connect(displayname, &screenp);
    if (!*pp || xcb_connection_has_error(*pp)){
        lua_pushnil(L);
        lua_pushliteral(L, "xcb_connect failed (XCB provides no further information)");
        return 2;
    }
    lua_pushinteger(L, screenp);
    return 2;
}

static int conn_generate_id(lua_State *L)
{
    uint32_t xid = xcb_generate_id(toconn(L, 1));
    if (xid == (uint32_t) -1){
        lua_pushnil(L);
        lua_pushliteral(L, "xcb_generate_id failed");
        return 2;
    }
    lua_pushinteger(L, xid);
    return 1;
}

static int conn_get_setup(lua_State *L)
{
    lua_xcb_push_setup(L, xcb_get_setup(toconn(L, 1)));
    return 1;
}

/* Return masked version of a response_type field. */
static int response_type(lua_State *L)
{
    lua_pushinteger(L, luaL_checkinteger(L, 1) & XCB_EVENT_RESPONSE_TYPE_MASK);
    return 1;
}

static int warn_missing_key(lua_State *L)
{
    return luaL_error(L, "Attempt to use xcb.%s, which doesn't exist.", lua_tostring(L, 2));
}

static void constant(lua_State *L, const char *name, long val)
{
    lua_pushinteger(L, val);
    lua_setfield(L, -2, name);
}

/* Exported functions.
   These are also available through connection objects. */
static const luaL_Reg conn_functions[] = {
    {"response_type", response_type},
    {"is_valid", conn_is_valid},
    {"disconnect", conn_gc},
    {"flush", conn_flush},
    {"get_file_descriptor", conn_get_file_descriptor},
    {"connection_has_error", conn_has_error},
    {"wait_for_event", conn_wait_for_event},
    {"poll_for_event", conn_poll_for_event},
    {"connect", connect},
    {"generate_id", conn_generate_id},
    {"get_setup", conn_get_setup},
    {NULL, NULL}
};

static const luaL_Reg connection_metamethods[] = {
    {"__tostring", conn_tostring},
    {"__gc", conn_gc},
    {NULL, NULL}
};

static const luaL_Reg cookie_methods[] = {
    {"__tostring", cookie_tostring},
    {"__gc", cookie_gc},
    {"discard", cookie_gc},
    {"wait", cookie_wait},
    {NULL, NULL}
};

LUALIB_API int luaopen_xcb(lua_State *L)
{
    /* Create table to return.
       Submodules install their functions in the same table.
       They're then available through connection objects.
       Therefore, put the table in the registry, too. */
    luaL_newmetatable(L, LUA_XCB_CONN_METHODS);
    luaL_setfuncs(L, conn_functions, 0);

    /* Warn when an absent key is read. */
    lua_createtable(L, 0, 1);
    lua_pushcfunction(L, warn_missing_key);
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2);

    constant(L, "X_PROTOCOL", X_PROTOCOL);
    constant(L, "X_PROTOCOL_REVISION", X_PROTOCOL_REVISION);
    constant(L, "X_TCP_PORT", X_TCP_PORT);
    constant(L, "NONE", XCB_NONE);
    constant(L, "COPY_FROM_PARENT", XCB_COPY_FROM_PARENT);
    constant(L, "CURRENT_TIME", XCB_CURRENT_TIME);
    constant(L, "NO_SYMBOL", XCB_NO_SYMBOL);

    /* Create metatable for connection. */
    luaL_newmetatable(L, LUA_XCB_CONN_MT);
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "__index"); /* Expose methods from package table. */
    protect_metatable(L);
    luaL_setfuncs(L, connection_metamethods, 0);
    lua_pop(L, 1);

    /* Create metatable for cookies. */
    luaL_newmetatable(L, LUA_XCB_COOKIE_MT);
    protect_metatable(L);
    luaL_setfuncs(L, cookie_methods, 0);
    /* Point metatable at itself, so that the metatable can contain
       the methods. And pop the metatable */
    lua_setfield(L, -1, "__index");

    /* Create event table. */
    luaL_newmetatable(L, LUA_XCB_EVENT_TABLE);
    lua_pop(L, 1);

    return 1;
}
