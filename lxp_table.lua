local lxp = require "lxp" -- http://www.keplerproject.org/luaexpat
local lxp_table = {}

-- Parse an XML document and return corresponding Lua tables.
-- f - a file object to read from
function lxp_table.parse_xml(f)
    local root = {}
    local node = root
    local parser = lxp.new(
      {
        Comment = function(parser, string)
            table.insert(node, {name="#comment", value=string})
        end,
        StartElement = function(parser, element_name, attributes)
            local new_node =
              {
                name = element_name,
                attr = attributes or {},
                parent = node
              }
            table.insert(node, new_node)
            node = new_node
        end,
        EndElement = function(parser, element_name)
            assert(node.name == element_name, "Mismatched tags")
            node = node.parent
        end,
        Default = function(parser, string)
            -- Omit whitespace
            if string:find("[^ \t\n]") then
              table.insert(node, string)
            end
        end,
      }
    )
    -- Read the whole input file
    while true do
        local buf, err = f:read(1024)
        if not buf then
            if err then
                error(err)
            end
            break
        end
        local status, msg, line, col = parser:parse(buf)
        if not status then
            error(string.format("<xml>:%d:%d: %s", line, col, msg))
        end
    end
    parser:close()
    return root
end

return lxp_table
