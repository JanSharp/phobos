
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")

local function mkdir_recursive(path)
  path = Path.new(path)

  -- i thought for sure you could just mkdir multiple dir levels at once... but i guess not?
  for i = 1, #path do
    if not path:sub(1, i):exists() then
      -- this might fail, for example for drive letters,
      -- but that doesn't matter, as long as the output file
      -- can get created (=> asserted)
      lfs.mkdir(path:sub(1, i):str())
    end
  end
end

local function copy(from, to)
  from = Path.new(from)
  to = Path.new(to)

  mkdir_recursive(to:sub(1, -2))

  local file = assert(io.open(from:str(), "rb"))
  local contents = file:read("*a")
  assert(file:close())

  file = assert(io.open(to:str(), "wb"))
  file:write(contents)
  assert(file:close())
end

local function move(from, to)
  from = Path.new(from)
  to = Path.new(to)

  copy(from, to)

  os.remove(from:str())
end

return {
  mkdir_recursive = mkdir_recursive,
  copy = copy,
  move = move,
}
