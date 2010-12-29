#ifndef LUA_XCB_H
#define LUA_XCB_H

#include "lua.h"
#include "lauxlib.h"
#include "stdbool.h"
#include "xcb/xcb.h"

/* Registry field for connection object methods.
   Submodules add their methods to this table. */
#define LUA_XCB_CONN_METHODS "methods of xcb_connection_t *"

/* xcb_connection_t userdata */

#define LUA_XCB_CONN_MT "xcb_connection_t *"

/* Return connection pointer from userdata.
   Returned pointer may be NULL. */
xcb_connection_t *lua_xcb_to_conn(lua_State *L, int index);

/* Return connection pointer from userdata.
   This raises an error if the pointer is NULL or invalid. */
xcb_connection_t *lua_xcb_check_conn(lua_State *L, int index);

/* Cookie userdata
   
             connection
                 ^
                 |
                 |
    cookie ---> env
       |
       v
    metatable
*/

typedef struct {
    /* Sequence number from the cookie. */
    unsigned int sequence;
    
    /* Pointer to a function that converts reply pointer
       to the corrent reply structure pointer, and pushes
       a Lua representation of it.
       This is set to NULL when the cookie object is not in use. */
    int (* push_func)(lua_State *L, void *reply);
} lua_xcb_cookie_t;

#define LUA_XCB_COOKIE_MT "lua_xcb_cookie_t"

/* Push a new cookie object.
   conn_index is the index to the connection object. */
lua_xcb_cookie_t *lua_xcb_new_cookie(lua_State *L, int conn_index);

/* Get pointer to the cookie at index, raising an error if it is
   not a cookie. */
lua_xcb_cookie_t *lua_xcb_to_cookie(lua_State *L, int index);

/* Does the cookie represent an unreceived reply? */
static inline bool lua_xcb_cookie_pending(const lua_xcb_cookie_t *c)
{
    return c->push_func != NULL;
}

/* Reset a cookie to the unused state.
   This does not retrieve or discard the XCB reply - do that first. */
void lua_xcb_reset_cookie(lua_State *L, int index);

/* This can be used as push_func for requests without replies.
   It uses xcb_request_check. */
int lua_xcb_request_checker(lua_State *L, void *reply);

/* Like lua_getfield but raises an error if the key is missing. */
void lua_xcb_checkfield(lua_State *L, int index, const char *k);

/* A Lua table of functions to convert events into Lua form, is maintained.
   This is the name of that table in the registry.
   It is indexed by event number.
   The values are userdata containing lua_xcb_event_func_t. */
#define LUA_XCB_EVENT_TABLE "lua_xcb_event_table"
typedef int (* lua_xcb_event_func_t)(lua_State *, xcb_generic_event_t *);

#endif
