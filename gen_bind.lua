local lxp_table = require "lxp_table"
local iters = require "charon.iters"  -- https://github.com/xlq/charon/blob/master/iters.lua
local repr = require "charon.repr"    -- https://github.com/xlq/charon/blob/master/repr.lua

-- Memoise a unary function
function memoise(f)
    local cache = {}
    return function(x)
        local result = cache[x]
        if not result then
            result = f(x)
            cache[x] = result
        end
        return result
    end
end

---- Name functions
-- These functions handle xcb identifiers.
-- There are three types of name:
--   1. "XML names" are the names directly from the XML
--   2. "XCB names" are identifiers used in XCB (which usually start with "xcb_")
--   3. "Lua names" are identifiers used in the Lua binding.

-- Split an XML name into pieces
-- "EatGhost" -> {"Eat", "Ghost"}
local split_name = memoise(function (xml_name)
    local bits = {}
    for x in string.gmatch(xml_name, "[%u%d]+%f[^%u%d][^%d%u]*") do
        if x ~= "" then
            table.insert(bits, x)
        end
    end
    if not next(bits) then
        bits[1] = xml_name
    end
    return bits
end)

-- Return the XCB name of a field
local function xcb_obj_name(xml_name)
    local special = {
        class = "_class",
        new = "_new",
    }
    return special[xml_name] or xml_name
end

-- "FooBarBletch" -> "foo_bar_bletch"
local function underscore(s)
    return (string.gsub(
      iters.concat(
        iters.map(
          string.lower,
          split_name(s)
        ), "_"
      ),
      "__+", "_"))
end

local core_types = {
    CARD8   = "uint8_t",
    CARD16  = "uint16_t",
    CARD32  = "uint32_t",
    INT8    = "int8_t",
    INT16   = "int16_t",
    INT32   = "int32_t",
    char    = "char",
    BYTE    = "uint8_t",
    BOOL    = "uint8_t",
}

-- Return the XCB name of a request function
local function xcb_request_function(xml_name)
    return "xcb_" .. underscore(xml_name)
end

-- Return the XCB name of an XML type name
local function xcb_type_name(xml_name, omit_suffix)
    return core_types[xml_name] or "xcb_" .. underscore(xml_name) .. (omit_suffix and "" or "_t")
end

-- Return the XCB name of an iterator type
local function xcb_iterator(xml_name)
    return xcb_type_name(xml_name, true) .. "_iterator_t"
end

-- Remove _reply suffix (since iterator function names never contain it)
local function remove_reply(xcb_name)
    return string.gsub(xcb_name, "_reply$", "")
end

-- Return the Lua name of a request function
local function lua_request_name(xml_name)
    return underscore(xml_name)
end

-- Return the Lua name of a reply function
local function lua_reply_name(xml_name)
    return lua_request_name(xml_name) + "_reply"
end

-- Return the Lua name of an enum element
local function lua_enum_el_name(xml_enum_name, xml_el_name)
    return string.upper(
      underscore(xml_enum_name) .. "_" .. underscore(xml_el_name)
    )
end

---- Symbols

-- Global constants (including enum elements)
-- [name] = value
local constants = {}

-- Event functions to register
-- [number] = func name
local event_pushers = {}

-- Event name lookup
-- [xmlname] = number
local event_numbers = {}

-- Types from the XML
local types = {}

-- Functions to register in the package
local reg_functions = {}

---- Output

local function new_output(file)
    local self = {
        file = file,
        indent_level = 0,
        is_line_start = true
    }
    function self:out(...)
        local s = string.format(...)
        for line, line_end in string.gmatch(s, "([^\n]+)(\n?)") do
            if line ~= "" and self.is_line_start then
                self.file:write(string.rep("    ", self.indent_level))
            end
            self.file:write(line)
            if line_end == "\n" then
                self.file:write("\n")
                self.is_line_start = true
            else
                self.is_line_start = false
            end
        end
    end

    function self:blank_line()
        if not self.is_line_start then self.file:write("\n") end
        self.file:write("\n")
        self.is_line_start = true
    end

    function self:indent()
        self.indent_level = self.indent_level + 1
    end

    function self:undent()
        if self.indent_level > 0 then
            self.indent_level = self.indent_level - 1
        end
    end

    return self
end

local input_xml, output_c, output_h -- file names
local c, h -- C source and header files

---- C generation helpers

local function follow_typedefs(xml_type)
    while true do
        local tp = types[xml_type]
        if tp and tp.typedef then
            xml_type = tp.typedef
        else
            break
        end
    end
    return xml_type
end

local integer_types = {
    CARD8=true, CARD16=true, CARD32=true,
    INT8=true, INT16=true, INT32=true,
    BYTE=true,
}

local function is_scalar(xml_type)
    xml_type = follow_typedefs(xml_type)
    if integer_types[xml_type] then return true
    elseif xml_type == "BOOL"
        or xml_type == "char" then return true
    else
        local type = types[xml_type]
        if type and type.is_enum then return true
        else return false end
    end
end

-- Generate code to push a value on the Lua stack.
-- c_expr - a C expression to push
local function gen_push(xml_type, c_expr)
    xml_type = follow_typedefs(xml_type)
    if integer_types[xml_type] then
        c:out("lua_pushinteger(L, %s);\n", c_expr)
    elseif xml_type == "BOOL" then
        c:out("lua_pushboolean(L, %s);\n", c_expr)
    elseif xml_type == "char" then
        c:out("lua_pushlstring(L, &(%s), 1);\n", c_expr)
    else
        local type = types[xml_type]
        if type then
            if type.is_enum then
                c:out("lua_pushinteger(L, %s);\n", c_expr)
            else
                c:out("lua_xcb_push_%s(L, &(%s));\n", underscore(xml_type), c_expr);
            end
        else
            error("Unknown XML type: " .. tostring(xml_type))
        end
    end
end

-- Generate code to convert a Lua value to a C value.
-- index is a C expression for the stack index.
-- dest is an lvalue to assign to.
local function gen_get(xml_type, index, dest)
    xml_type = follow_typedefs(xml_type)
    if integer_types[xml_type]
    or xml_type == "void" then -- treat void data as bytes
        c:out("%s = luaL_checkinteger(L, %s);\n", dest, index)
    elseif xml_type == "BOOL" then
        c:out("%s = lua_toboolean(L, %s);\n", dest, index)
    else
        local type = types[xml_type]
        if type then
            if type.is_enum then
                -- TODO: range-check?
                c:out("%s = luaL_checkinteger(L, %s);\n", dest, index)
            else
                c:out("lua_xcb_get_%s(L, %s, &(%s));\n", underscore(xml_type), index, dest)
            end
        else
            error("Unknown XML type: " .. tostring(xml_type))
        end
    end
end

---- XML processing functions

-- Get an attribute from a node, ensuring it is actually present
local function gattr(node, name)
    return assert(
        assert(node.attr, "This XML node type has no attributes")
      [name],
      "Missing attribute: " .. name
    )
end

-- Write beginnings of C source files
local function write_header(package_name, input_xml)
    h:out("/* This file is automatically generated from %s.\n", input_xml)
    h:out("   Editing it is futile! */\n")
    h:out("#ifndef LUA_XCB_%s_H\n", package_name:upper())
    h:out("#define LUA_XCB_%s_H\n", package_name:upper())
    h:out("#include \"lua_xcb.h\"\n")
    h:blank_line()
    c:out("/* This file is automatically generated from %s.\n", input_xml)
    c:out("   Editing it is futile! */\n")
    c:out("#define LUA_LIB\n")
    c:out("#include \"%s\"\n", output_h)
    c:out("#include \"xcb/xcbext.h\"\n") -- for xcb_popcount
    c:blank_line()
end

-- Mark a field as a length field
local function mark_length_field(fields, length_field_name)
    for _, field in ipairs(fields) do
        if field.name == length_field_name then
            field.is_length = true
        end
    end
end

-- Return a table of fields from a struct-like entity
-- Return reply node as a second value, if found
local function do_fields(node)
    local fields = {}
    local reply_node = nil
    for _, chnode in ipairs(node) do
        if chnode.name == "field" then
            table.insert(fields,
              {
                ftype =  "field",
                name = gattr(chnode, "name"),
                type = gattr(chnode, "type"),
              }
            )
        elseif chnode.name == "pad" then
            -- We can ignore padding, because we use the struct definitions
            -- from the XCB headers, which already have the right padding.
        elseif chnode.name == "list" then
            local new_field = 
              {
                ftype = "list",
                name = gattr(chnode, "name"),
                type = gattr(chnode, "type"),
                length_node = chnode[1],
              }
            if new_field.length_node then
                -- Find length field
                if new_field.length_node.name == "fieldref" then
                    new_field.length_field = tostring(new_field.length_node[1])
                    mark_length_field(fields, new_field.length_field)
                elseif new_field.length_node.name == "value" then
                    new_field.length_const = tonumber(new_field.length_node[1])
                else
                    -- It's a whole expression.
                end
            else
                -- Create length field automatically
                table.insert(fields,
                  {
                    ftype = "field",
                    name = new_field.name .. "_len",
                    type = "CARD32",
                    is_length = true,
                  }
                )
                new_field.length_field = new_field.name .. "_len"
            end
            table.insert(fields, new_field)
        elseif chnode.name == "valueparam" then
            local mask_name = gattr(chnode, "value-mask-name")
            local mask_type = gattr(chnode, "value-mask-type")
            local list_name = gattr(chnode, "value-list-name")
            local mask_already_defined = false
            -- Sometimes value-mask-name is already defined, sometimes not
            for _, field in ipairs(fields) do
                if field.name == mask_name then
                    mask_already_defined = true
                    break
                end
            end
            if not mask_already_defined then
                -- Define the mask field
                table.insert(fields,
                  {
                    ftype = "field",
                    name = mask_name,
                    type = mask_type,
                  }
                )
            end
            table.insert(fields,
              {
                ftype = "values",
                name = list_name,
                type = "CARD32",
                mask_name = mask_name,
              }
            )
        elseif chnode.name == "reply" then
            reply_node = chnode
        elseif chnode.name then
            io.stderr:write("Unknown struct member type: ", chnode.name, "\n")
        end
    end
    return fields, reply_node
end

-- Do a struct declaration.
-- modif(fields) is called to modify the fields table.
local function do_struct(node, name, modif)
    name = name or gattr(node, "name")
    local fields = do_fields(node)

    if modif then modif(fields) end

    -- Define a C function to convert C -> Lua
    h:out("void lua_xcb_push_%s(lua_State *L, const xcb_%s_t *x);\n", underscore(name), underscore(name))
    c:out("void lua_xcb_push_%s(lua_State *L, const xcb_%s_t *x)\n", underscore(name), underscore(name))
    c:out("{\n")
    c:indent()
    c:out("lua_createtable(L, 0, %d);\n", #fields)
    for _, field in ipairs(fields) do
        if field.ftype == "field" then
            gen_push(field.type, "x->" .. xcb_obj_name(field.name))
            c:out("lua_setfield(L, -2, \"%s\");\n", field.name)
            -- TODO: omit useless length fields
        elseif field.ftype == "list" then
            if field.type == "char"
            or field.type == "BYTE"
            or field.type == "void" then
                -- It's really a string
                -- XXX: This assumes a uint8_t can fit in a char!
                c:out("lua_pushlstring(L, %s%s_%s(x), %s_%s_length(x));\n",
                  field.type == "char" and "" or "(char *) ",
                  remove_reply(xcb_type_name(name, true)),
                  field.name,
                  remove_reply(xcb_type_name(name, true)),
                  field.name)
            else
                local use_iter
                if field.length_const or is_scalar(field.type) then
                    -- Use pointers for some special cases (for when there is no *_iterator function)
                    use_iter = false
                else
                    use_iter = true
                end
                c:out("lua_newtable(L);\n")
                if field.length_const then
                    c:out("{   const %s *iter = x->%s;\n",
                      xcb_type_name(field.type),
                      xcb_obj_name(field.name))
                elseif use_iter then
                    c:out("{   %s iter = %s_%s_iterator(x);\n",
                      xcb_iterator(field.type),
                      remove_reply(xcb_type_name(name, true)),
                      field.name)
                else
                    c:out("{   %s *iter = %s_%s(x);\n",
                      xcb_type_name(field.type),
                      remove_reply(xcb_type_name(name, true)),
                      field.name)
                end
                c:indent()
                c:out("int i;\n")
                if field.length_const then
                    c:out("const int len = %d;\n", field.length_const)
                else
                    c:out("int len = %s_%s_length(x);\n",
                      remove_reply(xcb_type_name(name, true)),
                      field.name)
                end
                c:out("for (i=1; i<=len; ++i){\n")
                c:indent()
                if use_iter then
                    gen_push(field.type, "*iter.data")
                else
                    gen_push(field.type, "iter[i-1]")
                end
                c:out("lua_rawseti(L, -2, i);\n")
                if use_iter then
                    c:out("%s_next(&iter);\n",
                      xcb_type_name(field.type, true))
                end
                c:undent()
                c:out("}\n")
                c:undent()
                c:out("}\n")
            end
            c:out("lua_setfield(L, -2, \"%s\");\n", field.name)
        end
    end
    c:undent()
    c:out("}\n")
    c:blank_line()

    -- Define a C function to convert Lua -> C
    h:out("void lua_xcb_get_%s(lua_State *L, int index, xcb_%s_t *x);\n", underscore(name), underscore(name))
    c:out("void lua_xcb_get_%s(lua_State *L, int index, xcb_%s_t *x)\n", underscore(name), underscore(name))
    c:out("{\n")
    c:indent()
    local index = 1
    for _, field in ipairs(fields) do
        if field.ftype == "field" then
            c:out("lua_xcb_checkfield(L, index, \"%s\");\n", field.name)
            gen_get(field.type, "-1", "x->" .. xcb_obj_name(field.name))
            c:out("lua_pop(L, 1);\n")
        else
            c:out("luaL_error(L, \"List fields not implemented in Lua -> C conversion\");\n")
        end
        index = index + 1
    end
    c:undent()
    c:out("}\n")
    c:blank_line()

    types[name] = {
        is_struct = true
    }
end

-- Process an expression. Return string of C expression.
local function do_expression(node)
    if node.name == "value" then return node[1]
    elseif node.name == "bit" then return "1 << " .. node[1]
    elseif node.name == "op" then
        return string.format("(%s) %s (%s)",
          do_expression(node[1]), gattr(node, "op"), do_expression(node[2]))
    elseif node.name == "fieldref" then
        return xcb_obj_name(node[1])
    else error("Unknown expression node: " .. repr(node)) end
end

local function do_enum(node)
    -- These enum names are used elsewhere, so we special-case them
    -- and append "Enum"
    local special = {
        Window = true,
        Atom = true,
        Colormap = true,
        Cursor = true,
        Pixmap = true,
        Font = true
    }
    local last_value, last_inc
    local xml_name_base = gattr(node, "name")

    local function do_item(el)
        if el.name == "item" then
            local xml_el_name = gattr(el, "name")
            local value
            if el[1] then
                -- Read new value
                value = do_expression(el[1])
                last_value = value
                last_inc = 0
            else
                -- Increment last value
                last_inc = last_inc + 1
                value = "(" .. last_value .. ") + " .. last_inc
            end
            constants[lua_enum_el_name(xml_name_base, xml_el_name)] = value
        elseif el.name then
            io.stderr:write("Unknown enum element type: ", el.name, "\n")
        end
    end

    --[[
    if special[xml_name_base] then
        xml_name_base = xml_name_base .. "Enum"
    end
    --]]

    for _, el in ipairs(node) do
        do_item(el)
    end

    types[gattr(node, "name")] = {
        is_enum = true
    }
end

local function do_xidtype(node)
    types[gattr(node, "name")] = {
        typedef = "CARD32"
    }
end

local function do_typedef(node)
    types[gattr(node, "newname")] = {
        typedef = gattr(node, "oldname")
    }
end

local function do_request(node)
    local name = gattr(node, "name")
    local suffix
    -- Collect fields
    local fields, reply_node = do_fields(node)
    
    if reply_node then
        -- Do reply structure.
        do_struct(reply_node, name.."Reply",
          function(fields)
            table.insert(fields, 1, { ftype="field", name="response_type", type="CARD8" })
            table.insert(fields, 3, { ftype="field", name="sequence", type="CARD16" })
            table.insert(fields, 4, { ftype="field", name="length", type="CARD32" })
          end)
        -- Produce a push_func compatible function.
        c:out("static int push_%s_reply(lua_State *L, void *p)\n",
          lua_request_name(name))
        c:out("{\n")
        c:indent()
        c:out("lua_xcb_push_%s_reply(L, p);\n",
          lua_request_name(name))
        c:out("return 1;\n")
        c:undent()
        c:out("}\n")
        c:blank_line()
    end

    -- Generate request wrappers
    -- H == 1   --> unchecked
    -- H == 2   --> checked
    for H = 1, 2 do
        if H == 1 and not reply_node
        or H == 2 and reply_node then
            suffix = ""
        elseif H == 1 and reply_node then
            suffix = "_unchecked"
        else
            suffix = "_checked"
        end
        c:out("static int %s(lua_State *L)\n", lua_request_name(name) .. suffix)
        c:out("{\n")
        c:indent()
        c:out("size_t i;\n")
        c:out("xcb_connection_t *c = lua_xcb_check_conn(L, 1);\n")
        local param_n = 2 -- 1 is for the connection object
        for _, field in ipairs(fields) do
            if field.ftype == "field" then
                c:out("%s %s;\n", xcb_type_name(field.type), xcb_obj_name(field.name))
                if field.is_length then
                    -- This is a length field - don't consume a Lua parameter.
                    -- Get the length from the list field, later.
                else
                    gen_get(field.type, tostring(param_n), xcb_obj_name(field.name))
                    param_n = param_n + 1
                end
            elseif field.ftype == "list" then
                if field.type == "char" or field.type == "void" then
                    c:out("const char *%s = luaL_checklstring(L, %d, &i);\n",
                      xcb_obj_name(field.name), param_n)
                    if field.length_field then
                        c:out("%s = i;\n", xcb_obj_name(field.length_field))
                    else
                        if field.length_node then
                            -- There's a length expression.
                            -- Generate code to make sure the lengths match.
                            local lenexprs = do_expression(field.length_node)
                            c:out("if (i != (%s))\n", lenexprs)
                            c:indent()
                            c:out("return luaL_error(L, \"Length field/string length mismatch.\");\n")
                            c:undent()
                        else
                            -- What to do now???
                        end
                    end
                else
                    local len_expr
                    if field.length_field then
                        -- Store the length of the list
                        len_expr = xcb_obj_name(field.length_field)
                        c:out("%s = lua_rawlen(L, %d);\n",
                          len_expr, param_n)
                    else
                        len_expr = string.format("lua_rawlen(L, %d)", param_n)
                    end
                    c:out("%s %s[(luaL_checktype(L, %d, LUA_TTABLE), %s)];\n",
                      --field.type == "void" and "unsigned char" or xcb_type_name(field.type),
                      xcb_type_name(field.type),
                      xcb_obj_name(field.name),
                      param_n, len_expr)
                    c:out("for (i=0; i<sizeof %s/sizeof *%s; ++i){\n",
                      xcb_obj_name(field.name), xcb_obj_name(field.name))
                    c:indent()
                    c:out("lua_rawgeti(L, %d, i + 1);\n", param_n)
                    gen_get(field.type, "-1", xcb_obj_name(field.name).."[i]")
                    c:out("lua_pop(L, 1);\n")
                    c:undent()
                    c:out("}\n")
                end
                param_n = param_n + 1
            elseif field.ftype == "values" then
                c:out("uint32_t %s[xcb_popcount(%s)];\n",
                  xcb_obj_name(field.name),
                  xcb_obj_name(field.mask_name))
                c:out("for (i=0; i<sizeof %s/sizeof *%s; ++i){\n",
                  xcb_obj_name(field.name), xcb_obj_name(field.name))
                c:indent()
                c:out("lua_rawgeti(L, %d, i + 1);\n", param_n)
                gen_get(field.type, "-1", xcb_obj_name(field.name).."[i]")
                c:out("lua_pop(L, 1);\n")
                c:undent()
                c:out("}\n")
                param_n = param_n + 1
            else
                c:out("luaL_error(L, \"Not implemented.\");\n")
            end
        end
        -- TODO COOKIE
        if H == 2 then
            -- This is the checked function. Return a cookie.
            c:out("lua_xcb_cookie_t *cookie = lua_xcb_new_cookie(L, 1);\n")
            if reply_node then
                c:out("cookie->push_func = &push_%s_reply;\n",
                  lua_request_name(name))
            else
                c:out("cookie->push_func = &lua_xcb_request_checker;\n")
            end
            c:out("cookie->sequence = ")
        end
        c:out("%s(c", xcb_request_function(name)..suffix)
        for _, field in ipairs(fields) do
            c:out(", %s", xcb_obj_name(field.name))
        end
        if H == 2 then
            -- Checked function.
            c:out(").sequence;\n");
            c:out("return 1;\n");
        else
            c:out(");\n")
            c:out("return 0;\n")
        end
        c:undent()
        c:out("}\n")
        c:blank_line()
        table.insert(reg_functions, lua_request_name(name)..suffix)
    end
end

local function do_event(node)
    local name = gattr(node, "name")
    local number = tonumber((gattr(node, "number")))
    constants[underscore(name):upper()] = number
    do_struct(node, name.."Event",
      function(fields)
        table.insert(fields, 1, { ftype="field", name="response_type", type="CARD8" })
      end)
    -- Define a type-compatible pusher function
    local pusher_name = "pusher_" .. underscore(name.."Event")
    c:out("static int %s(lua_State *L, xcb_generic_event_t *event)\n", pusher_name)
    c:out("{\n")
    c:indent()
    c:out("return lua_xcb_push_%s(L, (void *) event), 1;\n",
      underscore(name.."Event"))
    c:undent()
    c:out("}\n")
    c:blank_line()
    event_pushers[number] = pusher_name
    event_numbers[name] = number
end

local function do_event_copy(node)
    local name = gattr(node, "name")
    local number = tonumber((gattr(node, "number")))
    constants[underscore(name):upper()] = number
    event_pushers[number] = event_pushers[event_numbers[gattr(node, "ref")]]
    event_numbers[name] = number
end

-- Do a top-level entity
local function do_thing(node)
    if node.name == "struct" then do_struct(node)
    -- For now, treat unions as structs.
    -- In C -> Lua conversion, most fields will be junk.
    -- In Lua -> C conversion, everything will go horribly wrong.
    elseif node.name == "union" then do_struct(node)
    elseif node.name == "enum" then do_enum(node)
    elseif node.name == "xidtype" or node.name == "xidunion" then do_xidtype(node)
    elseif node.name == "typedef" then do_typedef(node)
    elseif node.name == "request" then do_request(node)
    elseif node.name == "event" then do_event(node)
    elseif node.name == "eventcopy" then do_event_copy(node)
    elseif node.name then
        io.stderr:write("Unknown node type: ", node.name, "\n")
    end
end

-- Output a static table of constants
local function do_constants()
    c:out("static const struct {\n")
    c:indent()
    c:out("const char *name;\n")
    c:out("lua_Integer value;\n")
    c:undent()
    c:out("} constants[] = {\n")
    c:indent()
    for k, v in pairs(constants) do
        c:out("{\"%s\", %s},\n", k, v)
    end
    c:undent()
    c:out("};\n")
    c:blank_line()
end

-- Output a static table of event pushers
local function do_pushers()
    c:out("static const struct {\n")
    c:indent()
    c:out("int number;\n")
    c:out("lua_xcb_event_func_t func;\n")
    c:undent()
    c:out("} event_pushers[] = {\n")
    c:indent()
    for k, v in pairs(event_pushers) do
        c:out("{%d, %s},\n", k, v)
    end
    c:undent()
    c:out("};\n")
    c:blank_line()
end

-- Generate entry point function
local function do_entry(package_name)
    c:out("static const luaL_Reg funcs[] = {\n")
    c:indent()
    for _, x in ipairs(reg_functions) do
        c:out("{\"%s\", %s},\n", x, x)
    end
    c:out("{NULL, NULL}\n")
    c:undent()
    c:out("};\n")
    c:blank_line()
    c:out("LUALIB_API int luaopen_xcb_%s(lua_State *L)\n", package_name)
    c:out("{\n")
    c:indent()
    --c:out("luaL_register(L, \"xcb.%s\", funcs);\n",
    --  package_name)
    --c:out("luaL_register(L, \"xcb\", funcs);\n")
    c:out [[
luaL_newmetatable(L, LUA_XCB_CONN_METHODS);
luaL_setfuncs(L, funcs, 0);
/* Add constants. */
{
    size_t i;
    for (i=0; i<sizeof constants / sizeof *constants; ++i){
        lua_pushinteger(L, constants[i].value);
        lua_setfield(L, -2, constants[i].name);
    }
}
/* Add pusher functions. */
{
    luaL_newmetatable(L, LUA_XCB_EVENT_TABLE);
    size_t i;
    for (i=0; i<sizeof event_pushers / sizeof *event_pushers; ++i){
        *(lua_xcb_event_func_t *) lua_newuserdata(L, sizeof(lua_xcb_event_func_t))
          = event_pushers[i].func;
        lua_rawseti(L, -2, event_pushers[i].number);
    }
    lua_pop(L, 1);
}
]]
    c:out("return 1;\n")
    c:undent();
    c:out("}\n")
end

local function do_all(node, input_xml)
    local top
    for i = 1, #node do
        top = node[i]
        if top.name and top.name ~= "#comment" then
            break
        end
    end
    local package_name = gattr(top, "header")
    write_header(package_name, input_xml)
    for _, thing in ipairs(top) do
        do_thing(thing)
    end

    do_constants()
    do_pushers()
    do_entry(package_name)
    h:blank_line()
    h:out("#endif\n")
end

local argv = {...}

if #argv ~= 3 then
    print(string.format("Usage: %s input_xml output_c output_h", debug.getinfo(1, "S").short_src))
    os.exit(1)
end

input_xml, output_c, output_h = table.unpack(argv)
c = new_output(io.open(output_c, "w"))
h = new_output(io.open(output_h, "w"))

local xml_root = lxp_table.parse_xml(
  assert(io.open(input_xml, "r"))
)

do_all(xml_root, input_xml)
