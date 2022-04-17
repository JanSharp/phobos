
local Path = require("lib.path")
local util = require("util")

local entry_type_enum = {
  file = 0,
  directory = 1,
  symlink = 2,
}
local entry_type_lut = {
  [0] = "file",
  [1] = "directory",
  [2] = "symlink",
}

local get_path

local function assert_entry_type(entry, expected_type)
  util.debug_assert(entry.entry_type == expected_type, "Expected entry type '"
    ..entry_type_lut[expected_type].."', got '"..entry_type_lut[entry.entry_type].."' for entry '"
    ..get_path(entry):str().."'."
  )
end

---@class VirtualFileSystem
local FS = {}
FS.__index = FS

local function touch(entry)
  entry.modification = entry.fs.next_modification_time
  entry.fs.next_modification_time = entry.fs.next_modification_time + 1
end

---@return VirtualFileSystem
local function new_fs()
  local root = {
    entry_type = entry_type_enum.directory,
    is_root = true,
    children = {},
    enumerating_count = 0,
    first_child = nil,
    last_child = nil,
  }
  local fs = setmetatable({
    cwd = root,
    root = root,
    next_modification_time = 0,
  }, FS)
  root.fs = fs
  touch(root)
  return fs
end

local follow_links

function get_path(entry)
  local path = Path.new("/")
  local entries = path.entries
  local function add(entry_to_add)
    if not entry_to_add.is_root then
      add(entry_to_add.parent)
    end
    entries[#entries+1] = entry_to_add.entry_name
  end
  if not entry.is_root then
    add(entry)
    path.force_directory = false
  end
  return path
end

local function try_get_entry(fs, path)
  local current_entry = fs.root
  for _, entry in ipairs(path.entries) do
    current_entry = follow_links(current_entry)
    assert_entry_type(current_entry, entry_type_enum.directory)
    current_entry = current_entry.children[entry]
    if not current_entry then return end
  end
  return current_entry
end

local function get_entry(fs, path)
  return util.debug_assert(try_get_entry(fs, path), "No such file or directory '"..path:str().."'.")
end

local function get_target_entry(entry)
  return get_entry(entry.fs, entry.target_path:to_fully_qualified(get_path(entry):sub(1, -2)):normalize())
end

function follow_links(entry)
  while entry.entry_type == entry_type_enum.symlink do
    entry = get_target_entry(entry)
  end
  return entry
end

---inset entry in the linked list of entries with its name in alphabetical order
local function insert_into_linked_list_based_on_name(parent_entry, entry)
  if parent_entry.first_child then
    local child_entry = parent_entry.first_child
    while child_entry do
      if entry.entry_name < child_entry.entry_name then
        if child_entry == parent_entry.first_child then
          parent_entry.first_child = entry
        else
          entry.prev = child_entry.prev
          entry.prev.next = entry
        end
        child_entry.prev = entry
        entry.next = child_entry
        goto inserted
      end
      child_entry = child_entry.next
    end
    -- did not insert, add to end
    parent_entry.last_child.next = entry
    entry.prev = parent_entry.last_child
    parent_entry.last_child = entry
    ::inserted::
  else
    parent_entry.first_child = entry
    parent_entry.last_child = entry
  end
end

local function add_entry(parent_entry, params)
  local entry = {
    parent = parent_entry,
    entry_type = params.entry_type,
    entry_name = params.entry_name,
    fs = parent_entry.fs,
  }
  ;(({
    [entry_type_enum.file] = function()
      entry.contents = params.contents
    end,
    [entry_type_enum.directory] = function()
      entry.children = {}
      entry.enumerating_count = 0
    end,
    [entry_type_enum.symlink] = function()
      entry.target_path = params.target_path
    end,
  })[params.entry_type] or util.debug_abort())()

  touch(entry)
  parent_entry.modification = entry.modification
  parent_entry.children[entry.entry_name] = entry
  insert_into_linked_list_based_on_name(parent_entry, entry)
end

local function remove_entry(entry)
  touch(entry.parent)
  entry.parent.children[entry.entry_name] = nil
  if entry.prev then
    entry.prev.next = entry.next
  else
    entry.parent.first_child = entry.next
  end
  if entry.next then
    entry.next.prev = entry.prev
  else
    entry.parent.last_child = entry.prev
  end
end

local function assert_can_modify(entry)
  if entry.entry_type == entry_type_enum.directory and entry.enumerating_count > 0 then
    util.debug_abort("Attempt to modify directory '"..get_path(entry):str()
      .."' while it is being enumerated by "..entry.enumerating_count.." enumerators."
    )
  end
end

local function validate_path_entry_names(path)
  for _, entry_name in ipairs(path.entries) do
    local match = entry_name:match("[/%?%*%\\]")
    if match then
      util.debug_abort("Invalid entry name '"..entry_name.."', contains '"..match.."'.")
    end
    if entry_name == "" then
      util.debug_abort("Impossible because the path library doesn't allow it.")
    end
  end
  return path
end

local function sanitize_input(fs, path)
  util.debug_assert(type(path) == "string", "Expected string path, got '"..tostring(path).."'.")
  path = Path.new(path):to_fully_qualified(get_path(fs.cwd)):normalize()
  return validate_path_entry_names(path)
end

local function get_parent_entry_and_child_name(fs, path)
  util.debug_assert(path:length() >= 1, "Attempt to add/create root.")
  local parent = get_entry(fs, path:sub(1, -2))
  parent = follow_links(parent)
  assert_entry_type(parent, entry_type_enum.directory)
  return parent, path:sub(-1).entries[1]
end

local function assert_parent_does_not_have_child(parent, child_entry_name)
  if parent.children[child_entry_name] then
    util.debug_abort("Attempt to create entry '"..child_entry_name
      .."' in '"..get_path(parent):str().."' which already exists."
    )
  end
end

-- get cwd
-- set cwd
-- add file
-- add dir
-- add symlink
-- get contents
-- set contents
-- enumerate dir
-- remove entry
-- check existence
-- get modification
-- get entry mode (entry_type)

function FS:get_cwd()
  return get_path(self.cwd):str()
end

function FS:set_cwd(path)
  path = sanitize_input(self, path)
  local entry = get_entry(self, path)
  assert_entry_type(follow_links(entry), entry_type_enum.directory)
  self.cwd = entry
end

function FS:add_file(path)
  path = sanitize_input(self, path)
  local parent, entry_name = get_parent_entry_and_child_name(self, path)
  assert_parent_does_not_have_child(parent, entry_name)
  assert_can_modify(parent)
  add_entry(parent, {
    entry_type = entry_type_enum.file,
    entry_name = entry_name,
    contents = "",
  })
end

function FS:add_dir(path)
  path = sanitize_input(self, path)
  local parent, entry_name = get_parent_entry_and_child_name(self, path)
  assert_parent_does_not_have_child(parent, entry_name)
  assert_can_modify(parent)
  add_entry(parent, {
    entry_type = entry_type_enum.directory,
    entry_name = entry_name,
  })
end

function FS:add_symlink(old, new)
  new = sanitize_input(self, new)
  old = Path.new(old)
  local parent, entry_name = get_parent_entry_and_child_name(self, new)
  assert_parent_does_not_have_child(parent, entry_name)
  assert_can_modify(parent)
  add_entry(parent, {
    entry_type = entry_type_enum.symlink,
    entry_name = entry_name,
    target_path = validate_path_entry_names(old),
  })
end

function FS:get_contents(path)
  path = sanitize_input(self, path)
  local entry = get_entry(self, path)
  entry = follow_links(entry)
  assert_entry_type(entry, entry_type_enum.file)
  return entry.contents
end

function FS:set_contents(path, contents)
  util.debug_assert(type(contents) == "string",
    "Expected string contents for a file, got '"..tostring(contents).."'."
  )
  path = sanitize_input(self, path)
  local entry = get_entry(self, path)
  entry = follow_links(entry)
  assert_entry_type(entry, entry_type_enum.file)
  touch(entry)
  entry.contents = contents
end

function FS:enumerate(path)
  path = sanitize_input(self, path)
  local entry = get_entry(self, path)
  entry = follow_links(entry)
  assert_entry_type(entry, entry_type_enum.directory)
  local current
  entry.enumerating_count = entry.enumerating_count + 1
  return function()
    if not current then
      current = entry.first_child
    else
      current = current.next
    end
    if not current then
      entry.enumerating_count = entry.enumerating_count - 1
    end
    return current and current.entry_name
  end
end

function FS:remove(path)
  path = sanitize_input(self, path)
  local entry = get_entry(self, path)
  assert_can_modify(entry)
  if entry.entry_type == entry_type_enum.directory then
    util.debug_assert(not entry.first_child, "Attempt to remove non empty directory '"
      ..get_path(entry):str().."'."
    )
    util.debug_assert(not entry.is_root, "Attempt to remove root.")
  end
  remove_entry(entry)
end

function FS:exists(path)
  path = sanitize_input(self, path)
  return not not try_get_entry(self, path)
end

function FS:get_modification(path, do_not_follow_symlinks)
  path = sanitize_input(self, path)
  local entry = get_entry(self, path)
  if not do_not_follow_symlinks then
    entry = follow_links(entry)
  end
  return entry.modification
end

function FS:get_entry_type(path, do_not_follow_symlinks)
  path = sanitize_input(self, path)
  local entry = get_entry(self, path)
  if not do_not_follow_symlinks then
    entry = follow_links(entry)
  end
  return entry_type_lut[entry.entry_type]
end

return {
  new_fs = new_fs,
  FS = FS,
}
