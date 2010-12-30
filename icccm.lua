-- This file contains some ICCCM-related functions.
-- Note: This doesn't use the util/icccm that xcb
-- provides.

local xcb    = require "xcb"
               require "xcb.xproto"
local struct = require "struct"        -- http://www.inf.puc-rio.br/~roberto/struct/
local tables = require "charon.tables" -- https://www.github.com/xlq/charon/blob/master/tables.lua

local icccm = {}

--------  WM_SIZE_HINTS  --------

tables.merge(icccm, {
    SIZE_HINT_US_POSITION   = 0x001;
    SIZE_HINT_US_SIZE       = 0x002;
    SIZE_HINT_P_POSITION    = 0x004;
    SIZE_HINT_P_SIZE        = 0x008;
    SIZE_HINT_P_MIN_SIZE    = 0x010;
    SIZE_HINT_P_MAX_SIZE    = 0x020;
    SIZE_HINT_P_RESIZE_INC  = 0x040;
    SIZE_HINT_P_ASPECT      = 0x080;
    SIZE_HINT_BASE_SIZE     = 0x100;
    SIZE_HINT_P_WIN_GRAVITY = 0x200;
})

-- flags, x, y, width, height, min_width, min_height, max_width, max_height,
--   width_inc, height_inc, min_aspect_num, min_aspect_den, max_aspect_num,
--   max_aspect_den, base_width, base_height, win_gravity
local xcb_size_hints_t = "I4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4i4I4"

function icccm.set_wm_normal_hints(c, window, ...)
    local packed = struct.pack(xcb_size_hints_t, ...)
    return c:change_property(xcb.PROP_MODE_REPLACE,
      window, xcb.ATOM_WM_NORMAL_HINTS, xcb.ATOM_WM_SIZE_HINTS,
      32, #packed/4, packed)
end

return icccm
