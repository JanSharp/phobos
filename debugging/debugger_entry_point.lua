
local args = {...}

package.path = package.path:gsub("%.[\\/]%?%.lua", "./bin/"..args[1].."/?.lua")

local file = assert(io.open("./bin/"..args[1].."/"..args[2], args[3] == "binary" and "rb" or "r"))
local text = file:read("*a")
file:close()

local main_chunk = assert(load(text, "@"..args[2], args[3] == "binary" and "b" or "t"))

main_chunk(table.unpack(args, 4))
