
local util = require("util")

---every `index_spacing`-th index will be used when prepending, appending or re-indexing\
---leaving a gap of `index_spacing - 1`\
---should always be a **power of 2** to create nicely split-able gaps\
---(to be exact, appended nodes just get the index of `self.last.index + index_spacing`;
---mirrored for prepending or course)
local index_spacing = 2 ^ 4

-- some example values:
-- first row is the exponent used
-- second row is the amount of values able to insert before/after the same node
-- before having to re-index on an initially clean list and where the left and right nodes
-- are not the first or last node, as that would allow for infinite insertions without re-indexing
-- 0 1 2 3  4  5  6  7  8
-- 0 2 5 9 14 20 27 35 44
-- note that this is one of the best case scenarios when inserting into the same area in the list

local ill = {}

local function new_node(list, value, index, prev, next)
  value = value or {}
  if value.list then
    util.debug_abort("Attempt to add the same table to some intrusive list multiple times.")
  end
  value.list = list
  value.index = index
  value.prev = prev
  value.next = next
  return value
end

local function re_index(self)
  -- re-indexing creates a fresh lookup table
  -- it would be awesome if we could initialize this
  -- table with the correct hash table size, but we can't
  local lookup = {}
  local node = self.first
  local index = 0
  while node do
    node.index = index
    lookup[index] = node
    index = index + index_spacing
    node = node.next
  end
  self.lookup = lookup
end

local function push_to_center(self, left, node, right, closer_to_left)
  local index_diff = right.index - left.index
  -- assert(index_diff > 1, "Can only center node if left and right have some gap between")
  if closer_to_left then
    index_diff = index_diff - (index_diff % 2)
  else
    index_diff = index_diff + (index_diff % 2)
  end
  self.lookup[node.index] = nil
  node.index = left.index + index_diff / 2
  self.lookup[node.index] = node
end

local function relocate_node(self, node, target_index)
  self.lookup[node.index] = nil
  node.index = target_index
  self.lookup[node.index] = node
end

local insert_between

local function try_move_left_node(self, left, right, value, inserting_after)
  if not self.lookup[left.index - 1] then
    if left.prev then
      push_to_center(self, left.prev, left, right, true) -- closer to `left.prev`
      return insert_between(self, left, right, value, inserting_after)
    else
      -- push `left` really far left to have max size gaps after the insert is done
      relocate_node(self, left, right.index - (index_spacing * 2))
      return insert_between(self, left, right, value, inserting_after)
    end
  end
end

local function try_move_right_node(self, left, right, value, inserting_after)
  if not self.lookup[right.index + 1] then
    if right.next then
      push_to_center(self, left, right, right.next, false) -- closer to `right.next`
      return insert_between(self, left, right, value, inserting_after)
    else
      -- push `right` really far right to have max size gaps after the insert is done
      relocate_node(self, right, left.index + (index_spacing * 2))
      return insert_between(self, left, right, value, inserting_after)
    end
  end
end

function insert_between(self, left, right, value, inserting_after)
  local index_diff = right.index - left.index
  if index_diff == 1 then
    local node
    if inserting_after then
      node = try_move_left_node(self, left, right, value, inserting_after)
        or try_move_right_node(self, left, right, value, inserting_after)
    else
      node = try_move_right_node(self, left, right, value, inserting_after)
        or try_move_left_node(self, left, right, value, inserting_after)
    end
    if not node then
      -- couldn't move nodes, add node without an index and re-index
      node = new_node(self, value, nil, left, right)
      left.next = node
      right.prev = node
      self.count = self.count + 1
      re_index(self)
    end
    return node
  else -- there is a gap to place the node in
    -- move it more in the direction we are inserting in
    -- (if we consider "before" and "after" defining a direction)
    -- makes inserting before and after behave the same,
    -- plus optimizes for inserting multiple modes before or after the same node
    if inserting_after then
      index_diff = index_diff + (index_diff % 2)
    else
      index_diff = index_diff - (index_diff % 2)
    end
    local index = left.index + (index_diff / 2)
    local node = new_node(self, value, index, left, right)
    self.lookup[node.index] = node
    left.next = node
    right.prev = node
    self.count = self.count + 1
    return node
  end
end

local function add_first(self, value)
  local node = new_node(self, value, 0, nil, nil)
  self.lookup[node.index] = node
  self.first = node
  self.last = node
  self.count = 1
  return node
end

---@class ILLNode
---@field index integer @ non sequential but ordered index
---@field list IntrusiveIndexedLinkedList @ back reference
---@field prev ILLNode? @ `nil` if this is the first node
---@field next ILLNode? @ `nil` if this is the last node

---@class IntrusiveIndexedLinkedList
---@field count integer @ if 0, `first` and `last` are `nil`
---@field first ILLNode?
---@field last ILLNode?
---@field lookup table<integer, ILLNode> @ indexed by `ILLNode.index`

function ill.new()
  return {
    count = 0,
    first = nil,
    last = nil,
    lookup = {},
  }
end

---@param node ILLNode
---@param stop_at_node ILLNode?
---@param next_or_prev_key "next"|"prev"
local function make_iter(node, stop_at_node, next_or_prev_key)
  return function()
    local result = node
    if result == stop_at_node then
      node = (nil)--[[@as ILLNode]]
      stop_at_node = nil -- also set this to nil to prevent the else block from running in extra calls
    else
      node = node[next_or_prev_key]
    end
    return result
  end
end

---@generic T
---@return fun(_: any? ,_: T?):(T?) iterator @
---NOTE: doesn't actually take any parameters, just works around an issue with type inference (in 3.6.13)
function ill:iterate(start_at_node, stop_at_node)
  ---@diagnostic disable-next-line: undefined-field
  return make_iter(start_at_node or self.first, stop_at_node, "next")
end

---@generic T
---@return fun(_: any? ,_: T?):(T?) iterator @
---NOTE: doesn't actually take any parameters, just works around an issue with type inference (in 3.6.13)
function ill:iterate_reverse(start_at_node, stop_at_node)
  ---@diagnostic disable-next-line: undefined-field
  return make_iter(start_at_node or self.last, stop_at_node, "prev")
end

function ill:prepend(value)
  if self.count == 0 then
    return add_first(self, value)
  else
    -- who says we can't use negative indexes? it's just a hash table
    -- well it can be problematic for external code, but
    -- for now it'll use negative numbers (until the next re-index)
    local prev_first = self.first
    local node = new_node(self, value, prev_first.index - index_spacing, nil, prev_first)
    self.lookup[node.index] = node
    self.first = node
    self.count = self.count + 1
    prev_first.prev = node
    return node
  end
end

function ill:append(value)
  if self.count == 0 then
    return add_first(self, value)
  else
    local prev_last = self.last
    local node = new_node(self, value, prev_last.index + index_spacing, prev_last, nil)
    self.lookup[node.index] = node
    self.last = node
    self.count = self.count + 1
    prev_last.next = node
    return node
  end
end

function ill:clear()
  self.count = 0
  self.first = nil
  self.last = nil
  self.lookup = {}
end

---If `node` is `nil` it will append
function ill:insert_before(node, value)
  if not node then
    return ill.append(self, value)
  elseif node.prev then
    return insert_between(self, node.prev, node, value, false)
  else
    return ill.prepend(self, value)
  end
end

---If `node` is `nil` it will prepend
function ill:insert_after(node, value)
  if not node then
    return ill.prepend(self, value)
  elseif node.next then
    return insert_between(self, node, node.next, value, true)
  else
    return ill.append(self, value)
  end
end

function ill:remove(node)
  self.lookup[node.index] = nil
  if node.next then
    node.next.prev = node.prev
  else
    self.last = node.prev
  end
  if node.prev then
    node.prev.next = node.next
  else
    self.first = node.next
  end
  self.count = self.count - 1
  return node
end

function ill:is_alive(node)
  return self.lookup[node.index] == node
end

return ill
