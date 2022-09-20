
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
Path.set_main_separator("/")

local function find_lua_source_files()
  local filenames = {}
  local function find_files(dir)
    for entry_name in lfs.dir(dir and dir:str() or ".") do
      if entry_name ~= "." and entry_name ~= ".."
        and entry_name:sub(1, 1) ~= "."
        and entry_name ~= "bin"
        and entry_name ~= "out"
        and entry_name ~= "temp"
      then
        local relative_path = dir
          and dir:combine(entry_name)
          or Path.new(entry_name)
        if relative_path:attr("mode") == "directory" then
          find_files(relative_path)
        elseif relative_path:extension() == ".lua" then
          filenames[#filenames+1] = relative_path:str()
        end
      end
    end
  end
  find_files()
  return filenames
end

return {
  find_lua_source_files = find_lua_source_files,
}
