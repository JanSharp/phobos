
-- when running Lua files in this repository you have to use this entry_point.lua file
-- in order for package.path and package.cpath to be setup for `lfs` and `src` files to be found
-- example:
-- bin/windows/lua52.exe -- entry_point.lua src debugging/main.lua temp/test.lua

-- arg 1: main dir path (src or when desired the path to some bin/** sub dir)
-- arg 2: actual entry point. may be binary or text
-- the rest: passed along to the actual entry point as vararg. the global `arg` remains broken

local lua_executable_path
do
  local i = 0
  while arg[i] do
    lua_executable_path = arg[i]
    i = i - 1
  end
end

local operating_system = lua_executable_path:match("bin[\\/](%w+)")

-- TODO: is it also .dll on linux and osx?
package.cpath = package.cpath..";bin/"..operating_system.."/?.dll"

package.path = package.path..";"..arg[1].."/?.lua"

local file = assert(io.open(arg[2], "rb"))
local is_binary = not not file:read("*l"):find("^\x1bLua") -- check for lua bytecode signature
if not is_binary then
  assert(file:close())
  file = assert(io.open(arg[2], "r"))
end
local contents = file:read("*a")
assert(file:close())

local main_chunk = assert(load(contents, "@"..arg[2], is_binary and "b" or "t"))

main_chunk(table.unpack(arg, 3))
