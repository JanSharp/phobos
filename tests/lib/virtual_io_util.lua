
---@type LFS
local lfs = require("lfs")
local Path = require("lib.path")
local util = require("util")
local vfs = require("lib.virtual_file_system")
local io_util = require("io_util")

local io_util_copy = util.shallow_copy(io_util)

---only `nil` when unhooked or when `new_fs` was never called
---@type VirtualFileSystem
local fs

local function new_fs()
  fs = vfs.new_fs()
end

local fake_io_util = {}

local function ensure_is_path(path)
  util.debug_assert(path, "Missing path argument.")
  return Path.new(path)
end

function fake_io_util.mkdir_recursive(path)
  path = ensure_is_path(path)
  for i = 1, #path do
    if not fs:exists(path:sub(1, i):str()) then
      fs:add_dir(path:sub(1, i):str())
    end
  end
end

function fake_io_util.rmdir_recursive(path)
  path = ensure_is_path(path)
  local dirs = {}
  local files = {}
  for entry in fs:enumerate(path:str()) do
    if fs:get_entry_type((path / entry):str(), true) == "directory" then
      dirs[#dirs+1] = path / entry
    else
      files[#files+1] = path / entry
    end
  end
  for _, dir_path in ipairs(dirs) do
    fake_io_util.rmdir_recursive(dir_path)
  end
  for _, file_path in ipairs(files) do
    fs:remove(file_path:str())
  end
  fs:remove(path:str())
end

function fake_io_util.read_file(path)
  path = ensure_is_path(path)
  return fs:get_contents(path:str())
end

function fake_io_util.write_file(path, contents)
  path = ensure_is_path(path)
  fake_io_util.mkdir_recursive(path:sub(1, -2))
  if not fs:exists(path:str()) then
    fs:add_file(path:str())
  end
  fs:set_contents(path:str(), contents)
end

function fake_io_util.copy(from, to)
  local contents = fake_io_util.read_file(from)
  fake_io_util.write_file(to, contents)
end

function fake_io_util.delete_file(path)
  path = ensure_is_path(path)
  fs:remove(path:str())
end

function fake_io_util.move(from, to)
  from = ensure_is_path(from)
  fake_io_util.copy(from, to)
  fs:remove(from:str())
end

function fake_io_util.symlink(old, new)
  old = ensure_is_path(old)
  new = ensure_is_path(new)
  fs:add_symlink(old:str(), new:str())
end

function fake_io_util.exists(path)
  path = ensure_is_path(path)
  return fs:exists(path:str())
end

function fake_io_util.enumerate(path)
  path = ensure_is_path(path)
  -- the fs:enumerate function already doesn't return `"."` or `".."`
  -- so we can just return it's result as is
  return fs:enumerate(path:str())
end

function fake_io_util.set_working_dir(path)
  path = ensure_is_path(path)
  fs:set_cwd(path:str())
end

function fake_io_util.get_working_dir()
  return fs:get_cwd()
end

function fake_io_util.get_working_dir_path()
  return Path.new(fs:get_cwd())
end

function fake_io_util.get_modification(path)
  path = ensure_is_path(path)
  return fs:get_modification(path:str())
end

-- ensure there are fake functions for all real functions
do
  local missing_functions_lut = util.shallow_copy(io_util)
  for k in pairs(fake_io_util) do
    missing_functions_lut[k] = nil
  end
  local missing_names = {}
  for k in pairs(missing_functions_lut) do
    missing_names[#missing_names+1] = k
  end
  table.sort(missing_names)
  if missing_names[1] then
    util.debug_abort("Missing fake io_util functions: "..table.concat(missing_names, ", "))
  end
end

local fake_lfs = {}

function fake_lfs.dir(path)
  local iter, start_state, start_key = fs:enumerate(path)
  local dot = true
  local dot_dot = true
  return function(state, key)
    if dot then
      dot = false
      return "."
    end
    if dot_dot then
      dot_dot = false
      return ".."
    end
    ---@diagnostic disable-next-line:redundant-parameter
    return iter(state, key)
  end, start_state, start_key
end

local function attributes_helper(path, request_name, do_not_follow_symlinks)
  if type(request_name) == "table" then
    util.debug_abort("Table argument is not supported.")
  end
  if not request_name then
    util.debug_abort("Absent mode is not supported.")
  end
  return (({
    ["mode"] = function()
      local entry_type = fs:get_entry_type(path, do_not_follow_symlinks)
      if entry_type == "symlink" then
        entry_type = "link"
      end
      return entry_type
    end,
    ["modification"] = function()
      return fs:get_modification(path, do_not_follow_symlinks)
    end,
    ["dev"] = function()
      return fs:exists(path) and 1 or nil -- I only use this to test for existence in Path:exists()
    end,
  })[request_name] or function()
    util.debug_abort("Request name '"..request_name.."' is not supported.")
  end)()
end

function fake_lfs.attributes(path, request_name)
  return attributes_helper(path, request_name, false)
end

function fake_lfs.symlinkattributes(path, request_name)
  return attributes_helper(path, request_name, true)
end

function fake_lfs.currentdir()
  return fs:get_cwd()
end

---replace the lfs upvalue for all Path functions
---@param replace_with "real"|"fake"
local function replace_path_lfs_upvalue(replace_with)
  local dummy_upval_idx
  local value_to_replace
  if replace_with == "real" then
    value_to_replace = fake_lfs
    dummy_upval_idx = 1
  elseif replace_with == "fake" then
    value_to_replace = lfs
    dummy_upval_idx = 2
  else
    util.debug_abort("Invalid replace_with '"..tostring(replace_with).."'.")
  end

  ---cSpell:ignore nups
  local function dummy() return lfs, fake_lfs end
  local function replace_lfs_upvals(func)
    for i = 1, debug.getinfo(func, "u").nups do
      local _, upval_value = debug.getupvalue(func, i)
      if upval_value == value_to_replace then
        debug.upvaluejoin(func, i, dummy, dummy_upval_idx)
      end
    end
  end

  for _, value in pairs(Path) do
    if type(value) == "function" then
      replace_lfs_upvals(value)
    end
  end
end

local function replace_io_util(to_replace_with)
  for k, v in pairs(to_replace_with) do
    io_util[k] = v
  end
end

---initializes a new, empty file system and replaces all functions interacting with it
local function hook()
  new_fs()
  replace_path_lfs_upvalue("fake")
  replace_io_util(fake_io_util)
end

---reverts all replaced functions
local function unhook()
  fs = (nil)--[[@as VirtualFileSystem]]
  replace_path_lfs_upvalue("real")
  replace_io_util(io_util_copy)
end

return {
  hook = hook,
  unhook = unhook,
  new_fs = new_fs,
}
