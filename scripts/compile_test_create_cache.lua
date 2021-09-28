
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
local serpent = require("lib.serpent")
local filenames = require("debugging.util").find_lua_source_files()
if not Path.new("temp"):exists() then
  assert(lfs.mkdir("temp"))
end
local cache_file = io.open("temp/test_filename_cache.lua", "w")
cache_file:write(serpent.dump(filenames))
cache_file:close()
