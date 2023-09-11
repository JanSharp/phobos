
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")

-- overwrite enumerate to not return `"."` and `".."` entries

---@diagnostic disable-next-line: duplicate-set-field
function Path:enumerate()
  local iter, start_state, start_index = lfs.dir(self:str())
  return function(state, index)
    repeat
      index = iter(state, index)
    until index ~= "." and index ~= ".."
    return index
  end, start_state, start_index
end

return Path
