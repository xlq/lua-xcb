LUA ?= lua
C99 ?= c99
CFLAGS ?= -fPIC -Wall -Wextra -pedantic -Wno-unused
LDFLAGS ?= -shared
LIBS ?= -lxcb -lxcb-event
XMLDIR ?= /usr/share/xcb
HEADERS = lua_xcb.h lua_xcb_xproto.h

.PHONY: all

all: xcb.so

xcb.so: lua_xcb.o lua_xcb_xproto.o
	$(C99) $(LDFLAGS) -o xcb.so lua_xcb.o lua_xcb_xproto.o $(LIBS)

%.o: %.c $(HEADERS)
	$(C99) $(CFLAGS) -c -o $@ $<

lua_xcb_xproto.c lua_xcb_xproto.h: gen_bind.lua $(XMLDIR)/xproto.xml
	$(LUA) gen_bind.lua $(XMLDIR)/xproto.xml lua_xcb_xproto.c lua_xcb_xproto.h || { $(RM) lua_xcb_xproto.c; exit 1; }

.PHONY: clean

clean:
	$(RM) xcb.so lua_xcb.o lua_xcb_xproto.o lua_xcb_xproto.c lua_xcb_xproto.h
