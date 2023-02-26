
local util = require("util")

---@param name string? @ the name used for next and prev keys.
---`nil` => "next" and "prev"\
---`"sibling"` => "next_sibling" and "prev_sibling"
---@param track_liveliness boolean? @ `true` enables usage of `is_alive`
---@return table
local function new_list(name, track_liveliness)
  return {
    first = nil,
    last = nil,
    next_key = name and ("next_"..name) or "next",
    prev_key = name and ("prev_"..name) or "prev",
    alive_nodes = track_liveliness and {} or nil,
  }
end

local function append(list, node)
  if list.last then
    list.last[list.next_key] = node
    node[list.prev_key] = list.last
    node[list.next_key] = nil
    list.last = node
  else
    list.first = node
    list.last = node
    node[list.prev_key] = nil
    node[list.next_key] = nil
  end
  if list.alive_nodes then
    list.alive_nodes[node] = true
  end
end

local function prepend(list, node)
  if list.first then
    node[list.prev_key] = nil
    node[list.next_key] = list.first
    list.first[list.prev_key] = node
    list.first = node
  else
    list.first = node
    list.last = node
    node[list.prev_key] = nil
    node[list.next_key] = nil
  end
  if list.alive_nodes then
    list.alive_nodes[node] = true
  end
end

---Inserting after `nil` is like inserting after `list.first.prev`, so it prepends.
local function insert_after(list, base_node, new_node)
  if base_node == new_node then
    util.debug_abort("Inserting a node after itself does not make sense.")
  end
  if base_node then
    local next_node = base_node[list.next_key]
    base_node[list.next_key] = new_node
    new_node[list.prev_key] = base_node
    if next_node then
      new_node[list.next_key] = next_node
      next_node[list.prev_key] = new_node
    else
      list.last = new_node
      new_node[list.next_key] = nil
    end
    if list.alive_nodes then
      list.alive_nodes[new_node] = true
    end
  else
    prepend(list, new_node)
  end
end

---Inserting before `nil` is like inserting before `list.last.next`, so it appends.
local function insert_before(list, base_node, new_node)
  if base_node == new_node then
    util.debug_abort("Inserting a node before itself does not make sense.")
  end
  if base_node then
    local prev_node = base_node[list.prev_key]
    new_node[list.next_key] = base_node
    base_node[list.prev_key] = new_node
    if prev_node then
      prev_node[list.next_key] = new_node
      new_node[list.prev_key] = prev_node
    else
      list.first = new_node
      new_node[list.prev_key] = nil
    end
    if list.alive_nodes then
      list.alive_nodes[new_node] = true
    end
  else
    append(list, new_node)
  end
end

local function remove_range_internal(list, from_node, to_node)
  local prev_node = from_node[list.prev_key]
  local next_node = to_node[list.next_key]
  if prev_node then
    prev_node[list.next_key] = next_node
  else
    list.first = next_node
  end
  if next_node then
    next_node[list.prev_key] = prev_node
  else
    list.last = prev_node
  end
end

local function remove(list, node)
  remove_range_internal(list, node, node)
  if list.alive_nodes then
    list.alive_nodes[node] = nil
  end
end

local function remove_range(list, from_node, to_node)
  remove_range_internal(list, from_node, to_node)
  if list.alive_nodes then
    local node = from_node
    while true do
      list.alive_nodes[node] = nil
      if node == to_node then
        break
      end
      node = node[list.next_key]
    end
  end
end

local function is_alive(list, node)
  if not list.alive_nodes then
    util.debug_abort("Attempt to check liveliness for a node in a linked list that does not track liveliness.")
  end
  return list.alive_nodes[node] or false
end

local function start_tracking_liveliness(list)
  if list.alive_nodes then return end
  local alive_nodes = {}
  list.alive_nodes = alive_nodes
  local node = list.first
  while node do
    alive_nodes[node] = true
    node = node[list.next_key]
  end
end

local function stop_tracking_liveliness(list)
  list.alive_nodes = nil
end

return {
  new_list = new_list,
  append = append,
  prepend = prepend,
  insert_after = insert_after,
  insert_before = insert_before,
  remove = remove,
  remove_range = remove_range,
  is_alive = is_alive,
  start_tracking_liveliness = start_tracking_liveliness,
  stop_tracking_liveliness = stop_tracking_liveliness,
}
