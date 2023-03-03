
local Path = require("lib.path")
local assert = require("assert")

local test_source = "=(test)"

local serpent_opts_for_ast = {
  keyignore = {
    first = true,
    last = true,
    next = true,
    prev = true,
    scope = true,
    list = true,
    parent_scope = true,
  },
  comment = true,
}

local function binary_pretty_printer(value)
  local out = {'"'}
  for i = 1, #value, 128 do
    for j, byte in ipairs{string.byte(value, i, i + 128 - 1)} do
      out[i + j] = string.format("\\x%02x", byte)
    end
  end
  out[#out+1] = '"'
  return table.concat(out)
end

-- ┃ Box Drawings Heavy Vertical https://unicode-table.com/en/2503/
-- ┣ Box Drawings Heavy Vertical and Right https://unicode-table.com/en/2523/
-- ┗ Box Drawings Heavy Up and Right https://unicode-table.com/en/2517/
-- ╸ Box Drawings Heavy Left https://unicode-table.com/en/2578/

local function get_fs_tree(root_path)
  local out = {}
  local stack = {}
  local function walk(path, depth)
    local entry_type = path:sym_attr("mode")
    if stack[depth - 1] == "┃" then
      stack[depth - 1] = "┣"
    end
    out[#out+1] = table.concat(stack, " ")..(stack[1] and "╸" or "")..(path.entries[#path] or "/")
      ..(entry_type == "link" and " => link to somewhere" or "")
    stack[depth - 1] = ({["┣"] = "┃", ["┗"] = " "})[stack[depth - 1]]
    if entry_type == "directory" then
      stack[depth] = "┃"
      local entries = {}
      for entry in path:enumerate() do
        entries[#entries+1] = entry
      end
      for i, entry in ipairs(entries) do
        if i == #entries then
          stack[depth] = "┗"
        end
        walk(path / entry, depth + 1)
      end
      stack[depth] = nil
    end
  end
  walk(Path.new(root_path), 1)
  return table.concat(out, "\n")
end

---@generic T
---@param expected_values T[]
---@param got_iterator fun():T?
local function assert_iteration(expected_values, got_iterator)
  local got_values = {}
  for value in got_iterator do
    got_values[#got_values+1] = value
  end
  local got_extra_one = got_iterator()
  local got_extra_two = got_iterator()
  assert.contents_equals(expected_values, got_values, "values return by the iterator")
  assert.equals(nil, got_extra_one, "result of calling the iterator 1 more time after it was done")
  assert.equals(nil, got_extra_two, "result of calling the iterator 2 more times it was done")
end

return {
  test_source = test_source,
  serpent_opts_for_ast = serpent_opts_for_ast,
  binary_pretty_printer = binary_pretty_printer,
  get_fs_tree = get_fs_tree,
  assert_iteration = assert_iteration,
}
