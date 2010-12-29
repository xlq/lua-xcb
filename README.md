lua-xcb
=======

## Introduction

_lua-xcb_ is a Lua binding to XCB (<http://xcb.freedesktop.org/>).
It consists of a core binding, `lua_xcb.c` and `lua_xcb.h`, and then
bindings generated from the XCB XML protocol definitions. These can be
compiled, and then linked together either as one shared object or
separate shared objects.

Except objects that represent resources allocated in C (connections,
cookies), all values are converted to and from the Lua equivalents.
Integers, including XIDs, are converted to/from Lua numbers. Structures are
converted to/from tables.

## Compatibility

It works with Lua 5.2, 5.1.4 and should work with other 5.1 versions.

## Dependencies.

The binding generator, `gen_bind.lua`, requires luaexpat
(<http://www.keplerproject.org/luaexpat/>) and some utilities from
Charon (<https://www.github.com/xlq/charon/>). These aren't needed
once `xcb.so` is built.

## Building

The Makefile is simple, so when it goes wrong, you can easily hammer it
into shape. When it's finished, install `xcb.so` into your Lua path, eg.
in `/usr/lib/lua/5.1`.

## Functions

Most of the _lua-xcb_ functions you use are in the table the module
returns (the table returned by `require "xcb"`). These functions are
also available through connection objects, so `xcb.flush(c)` is
equivalent to `c:flush()`.

Constants are included in the same table, as Lua numbers. They have the
same name as in XCB, but without the "XCB_" prefix.

Since most of the provided functions are equivalent to the corresponding
C functions, they are not documented here. The XCB documentation, and
the documentation of the X protocols, may be helpful.

#### response_type
`response_type(n)`
Returns `n & XCB_EVENT_RESPONSE_TYPE_MASK`. `n` should be the
response_type from an event. The value returned represents the actual
event number.

#### disconnect
`disconnect(c)`
Equivalent to `xcb_disconnect`. The connection object is set to a NULL
state, in which attempting to use it again will raise an error.
**Note:** Connection objects will be garbage-collected anyway, although
you might run out of file descriptors if you create lots of connections
without garbage collecting them.

#### flush
`flush(c)`
Equivalent to `xcb_flush`.

#### get_file_descriptor
`get_file_descriptor(c)`
Returns the file descriptor (as a Lua number) behind the connection
object.

#### connection_has_error
`connection_has_error(c)`
Equivalent to `xcb_connection_has_error`. Returns true if the connection
has encountered an error, false if it hasn't.
**Note:** This doesn't indicate X protocol errors that have been
returned from the server. It indicates when the underlying connection
has failed, for example if the server disconnected.

#### wait_for_event
`wait_for_event(c)`
Equivalent to `xcb_wait_for_event`. Waits for an event, and returns it,
as a Lua table, with all the correct fields included. It doesn't get
much easier than this!

#### poll_for_event
`poll_for_event(c)`
Equivalent to `xcb_poll_for_event`. Like `wait_for_event`, but returns
nil if no event is immediately available.

#### connect
`connect([display_name])`
Equivalent to `xcb_connect`. Returns a new connection object.
It also returns the preferred screen number as its second value.

#### generate_id
`generate_id(c)`
Nearly to `xcb_generate_id`. Returns a freshly allocated XID, as a Lua
number. If allocation fails, it will return nil plus an error message.

#### get_setup
`get_setup(c)`
Equivalent to `xcb_get_setup`. Returns the setup structure, as a Lua
table.

## Protocol functions

To use the functions generated from the XML protocol descriptions, load
the correct module:
    require "xcb.xproto"
The XCB module table will be populated with the constants and request
functions, etc. Functions returning events gain the ability to construct
the correct Lua tables at this point.

Functions have the same name as their equivalent in C, except without
the leading "xcb_".

The correspondence between Lua and C parameters are as follows:
* All enumeration and integer types, including XIDs, are passed as Lua
  numbers.
* Structs are passed as Lua tables, with keys of the same names as the C
  structures. Superfluous keys will be ignored. Missing keys will cause
  an error to be raised.
  **Exception:** Some C and C++ keywords, such as "new" and "class", are
  avoided by xcb, by prepending an underscore, The Lua field names do
  not contain such an underscore.
* List parameters are passed as Lua tables with integer keys, starting
  at 1. If the list has a single fieldref in the XML for its length
  (i.e. the number of array elements is given as a parameter to the C
  function), then the length parameter is taken from the length of the
  passed Lua table, with `lua_rawlen`.

  > **In most cases, list lengths are completely omitted from the
  > Lua functions.**

  Some requests, such as ChangeProperty, are more complicated. These
  need a length argument, which is then validated.

    Example:
    c:free_colors(cmap, 0, {pel1, pel2}) -- length is implicit
    c:change_property(xcb.PROP_MODE_REPLACE,
      xwindow, WM_PROTOCOLS, xcb.ATOM_ATOM,
      32, 1, struct.pack("I4", WM_DELETE_WINDOW))
        -- item size and count is explicit, because it is not a simple length parameter

* Value list parameters consist of a set of flags and a list item for
  each bit set in the flags. The mask and list are passed as separate
  parameters; a number and a table, respectively.
  As with list parameters, the table is 1-based.

    Example:
    c:change_gc(xgc, xcb.GC_FOREGROUND + xcb.GC_FUNCTION,
      {xcb.GX_COPY, xscreen.black_pixel)

  Notes:
  ** Lua has no built-in bitwise operators, but as long as none of the
  bits overlap, you can add flags together.
  ** Make sure you get the values in the right order! The value
  corresponding to the lowest bit goes first.

## Cookies

Checked requests return cookie objects. Because cookies can represent
replies stored by xcb, abandoning cookies can lead to leaking memory
allocated to replies, at least until the connection is closed.
Therefoce, _lua-xcb_ implements cookies as userdata objects, which, when
garbage-collected, will discard the reply if it hasn't already been
received.

Checked requests (those ending in "_checked" or those which have
corresponding replies) return a cookie object.

Cookies have the following methods:

#### wait
`cookie:wait()`
If the cookie was returned from a normally checked request function (one
with a corresponding reply), this method corresponds to the
`xcb_*_reply` functions, and will wait for and return the reply object
(as a Lua table).

If the cookie was returned by a "_checked" function, this method
corresponds to `xcb_request_check`, and will return _true_ instead of a
reply object. 

In either case, if the request failed, _wait_ will return nil, followed
by the Lua representation of an xcb_generic_error_t structure. 

Calling this method twice on the same cookie will result in an error.

#### discard
`cookie:discard()`
Corresponds to `xcb_discard_reply`. Throws away the reply.

## Sandbox safety
Not tested at all. You can't get at/tamper with the userdata's
metatables, but there are probably some request functions that'll UB
with some dodgy input.

## Efficiency

I designed the bindings to call XCB's request functions, because it was
easy and they work. However, for list and value fields in requests,
_lua-xcb_ copies values from Lua tables into C arrays, and then passes
them to XCB, which copies them into its output buffer. Should this
be problematically slow, _lua-xcb_ could generate the request structures
itself.
