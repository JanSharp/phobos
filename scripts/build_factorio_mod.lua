
local args = {...}
local profile = args[1]
local include_src_in_source_name = args[2] == "--include-src-in-source-name"
local output = "out/factorio/"..profile.."/phobos"

loadfile("src/main.lua")(
  "--source", "src",
  "--temp", "../temp",
  "--output", "../"..output,
  "--ignore", "main.lua", "phobos.lua", "lib/LFSClasses", "lib/LuaPath",
  "--use-load",
  "--pho-extension", ".lua",
  "--source-name", "@__phobos__/"..(include_src_in_source_name and "src/" or "").."?"
)

---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
local function copy(from, to)
  to = Path.new(to)
  if not to:sub(1, -2):exists() then
    for i = 1, #to - 1 do
      lfs.mkdir(to:sub(1, i):str())
    end
  end

  local file = assert(io.open(from, "rb"))
  local contents = file:read("*a")
  assert(file:close())
  file = assert(io.open(to:str(), "wb"))
  file:write(contents)
  assert(file:close())
end

local function copy_from_root_to_output(filename)
  copy(filename, output.."/"..filename)
end

copy_from_root_to_output("info.json")
copy_from_root_to_output("readme.md")
copy_from_root_to_output("changelog.txt")
copy_from_root_to_output("LICENSE.txt")
copy_from_root_to_output("LICENSE_THIRD_PARTY.txt")
