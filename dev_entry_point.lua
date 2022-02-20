
-- when running Lua files in this repository you have to use this dev_entry_point.lua file
-- in order for package.path and package.cpath to be setup for `lfs` and `src` files to be found
-- example:
-- bin/windows/lua -- dev_entry_point.lua src debugging/main.lua temp/test.lua

-- arg 1: main dir path (`src` or when desired the path to some `out/src/<platform>` sub dir)
-- arg 2: actual entry point. may be binary or text
-- the rest: passed along to the actual entry point as vararg. the global `arg` remains broken

-- just a note for the future, since i typed it out so nicely:
--
-- have to use `_G` (to set a global usable by other files)
-- because the local lua debugger... how to say this nicely...
-- the local lua debugger does a great job at hiding itself... yea, sarcasm will do it
--
-- the more professional explanation is that the local lua debugger only sets _ENV
-- to the sand-boxed _ENV in the main chunk, any other file ran from the main chunk
-- gets the real _ENV which then "hides" any globals created in the main chunk
-- but luckily local lua debugger does not set _G in the sand boxed _ENV to the
-- sand-boxed _ENV which means we can escape the sandbox by using _G
-- note that this might only be an issue with `load` and `loadfile`, but i'm quite sure
-- i've observed the same behavior when `require`ing files

local lua_executable_path
do
  local i = 0
  while arg[i] do
    lua_executable_path = arg[i]
    i = i - 1
  end
end
local operating_system = lua_executable_path:match("bin[\\/](%w+)")

-- get the first line from package.config
local path_sep = package.config:match("^([^\n]*)")
-- get the second line from package.config
local template_sep = package.config:match("^[^\n]*\n([^\n]*)")
-- get the third line from package.config
local substitution = package.config:match("^[^\n]*\n[^\n]*\n([^\n]*)")

package.cpath = package.cpath
  ..(package.cpath == "" and "" or template_sep)
  .."bin"..path_sep..operating_system..path_sep..substitution
  ..(operating_system == "windows" and ".dll" or ".so")

package.path = package.path
  ..(package.path == "" and "" or template_sep)
  ..arg[1]..path_sep..substitution..".lua"

local file = assert(io.open(arg[2], "rb"))
local is_binary = file:read(4) == "\x1bLua" -- check for lua bytecode signature
if not is_binary then
  assert(file:close())
  file = assert(io.open(arg[2], "r"))
else
  file:seek("set")
end
local contents = file:read("*a")
assert(file:close())

local main_chunk = assert(load(contents, "@"..arg[2], is_binary and "b" or "t"))

main_chunk(table.unpack(arg, 3))
