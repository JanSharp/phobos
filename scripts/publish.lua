
---@type LFS
local lfs = require("lfs")

local function escape_arg(arg)
  return '"'..arg:gsub("[$`\"\\]", "\\%0")..'"'
end

local function run(...)
  local pipe = assert(io.popen(table.concat({...}, " "), "r"))
  local result = {}
  for line in pipe:read("*a"):gmatch("[^\n]*\n") do
    result[#result+1] = line
  end
  pipe:close()
  return result
end

local function git(...)
  return run("git", ...)
end

local function gh(...)
  return run("gh", ...)
end

local foo = git("status", "--porcelain", "-b")
assert((foo[1]:find("^## master%.%.%.")))
local bar = gh()
local b
