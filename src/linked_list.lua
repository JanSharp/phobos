
local util = require("util")

---@param name string? @ (default: `nil`) the name used for next and prev keys.
---`nil` => `node.next` and `node.prev`\
---`"sibling"` => `node.next_sibling` and `node.prev_sibling`
---@param track_liveliness boolean? @ (default: `false`) `true` enables usage of `is_alive`
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

---@generic T
---@param array T[]
---@param name string? @ (default: `nil`) the name used for next and prev keys.
---`nil` => `node.next` and `node.prev`\
---`"sibling"` => `node.next_sibling` and `node.prev_sibling`
---@param track_liveliness boolean? @ (default: `false`) `true` enables usage of `is_alive`
---@return {first: T?, last: T?}
local function from_array(array, name, track_liveliness)
  local next_key = name and ("next_"..name) or "next"
  local prev_key = name and ("prev_"..name) or "prev"
  local alive_nodes = track_liveliness and {} or nil

  local count = #array
  local result = {
    first = array[1],
    last = array[count],
    next_key = next_key,
    prev_key = prev_key,
    alive_nodes = alive_nodes,
  }

  local prev
  for i = 1, count do
    local elem = array[i]
    if prev then
      prev[next_key] = elem
      elem[prev_key] = prev
    end
    if track_liveliness then
      alive_nodes[elem] = true
    end
    prev = elem
  end

  return result
end

---@generic T
---@param iterator fun(): (T?) @
---Keep in mind that using the return values of `pairs` or `ipairs` basically never makes sense here.
---The second and third return values do not match the parameters for this function, and it would ultimately
---create a linked list from the keys in the table. So `ipairs` never makes sense, `pairs` only if it has
---deterministic iteration order and if the keys are tables.
---@param name string? @ (default: `nil`) the name used for next and prev keys.
---`nil` => `node.next` and `node.prev`\
---`"sibling"` => `node.next_sibling` and `node.prev_sibling`
---@param track_liveliness boolean? @ (default: `false`) `true` enables usage of `is_alive`
---@return {first: T?, last: T?}
local function from_iterator(iterator, name, track_liveliness)
  local next_key = name and ("next_"..name) or "next"
  local prev_key = name and ("prev_"..name) or "prev"
  local alive_nodes = track_liveliness and {} or nil

  local first = iterator()
  if first == nil then
    -- must early return because `alive_nodes[nil] = true` is an error
    return {
      first = nil,
      last = nil,
      next_key = next_key,
      prev_key = prev_key,
      alive_nodes = alive_nodes,
    }
  end

  if track_liveliness then
    alive_nodes[first] = true
  end
  local prev = first
  for elem in iterator do
    if prev then
      prev[next_key] = elem
      elem[prev_key] = prev
    end
    if track_liveliness then
      alive_nodes[elem] = true
    end
    prev = elem
  end

  return {
    first = first,
    last = prev,
    next_key = next_key,
    prev_key = prev_key,
    alive_nodes = alive_nodes,
  }
end

local function make_iter(node, stop_at_node, next_or_prev_key)
  return function()
    local result = node
    if result == stop_at_node then
      node = nil
      stop_at_node = nil -- also set this to nil to prevent the else block from running in extra calls
    else
      node = node[next_or_prev_key]
    end
    return result
  end
end

---@generic T
---@param list {first: T?, last: T?}
---@return fun(_: any? ,_: T?):(T?) iterator @
---NOTE: doesn't actually take any parameters, just works around an issue with type inference (in 3.6.13)
local function iterate(list, start_at_node, stop_at_node)
  ---@diagnostic disable-next-line: undefined-field
  return make_iter(start_at_node or list.first, stop_at_node, list.next_key)
end

---@generic T
---@param list {first: T?, last: T?}
---@param start_at_node T? @ default: `list.last` (including)
---@param stop_at_node T? @ default: `nil` (so basically until `list.first`) (including)
---@return fun(_: any? ,_: T?):(T?) iterator @
---NOTE: doesn't actually take any parameters, just works around an issue with type inference (in 3.6.13)
local function iterate_reverse(list, start_at_node, stop_at_node)
  ---@diagnostic disable-next-line: undefined-field
  return make_iter(start_at_node or list.last, stop_at_node, list.prev_key)
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
  from_array = from_array,
  from_iterator = from_iterator,
  iterate = iterate,
  iterate_reverse = iterate_reverse,
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
