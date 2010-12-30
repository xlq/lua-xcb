local f = io.open("/usr/include/X11/keysymdef.h", "r")
print("return {")
for line in f:lines() do
    local name, value = string.match(line, "^%s*#define%s*([A-Za-z0-9_]+)%s*([^/%s]+)")
    if name then
        print(string.format("    %s = %s;", name, value))
    end
end
print("}")
