
local args = {...}
local profile = args[1]
local include_src_in_source_name = args[2] == "--include-src-in-source-name"
local output = "out/factorio/"..profile.."/phobos"

loadfile(assert(__source_dir).."/main.lua")(table.unpack{
  "--source", "src",
  "--temp", "../temp",
  "--output", "../"..output,
  "--use-load",
  "--pho-extension", ".lua",
  "--source-name", "@__phobos__/"..(include_src_in_source_name and "src/" or "").."?",
  "--ignore",
  "io_util.lua",
  "lib/LFSClasses",
  "lib/LuaPath",
  "main.lua",
  "phobos.lua",
})

local io_util = require("io_util")
local function copy_from_root_to_output(filename)
  io_util.copy(filename, output.."/"..filename)
end

copy_from_root_to_output("info.json")
copy_from_root_to_output("readme.md")
copy_from_root_to_output("changelog.txt")
copy_from_root_to_output("LICENSE.txt")
copy_from_root_to_output("LICENSE_THIRD_PARTY.txt")
