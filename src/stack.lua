
local function new_stack()
  return {size = 0}
end

---@generic T
---@param stack T[]
---@param value T
local function push(stack, value)
  local size = stack.size + 1
  stack.size = size
  stack[size] = value
end

---@generic T
---@param stack T[]
---@return T
local function pop(stack)
  local size = stack.size
  local value = stack[size]
  stack[size] = nil
  stack.size = size - 1
  return value
end

---@generic T
---@param stack T[]
---@return T
local function get_top(stack)
  ---@diagnostic disable-next-line: undefined-field
  return stack[stack.size]
end

local function is_empty(stack)
  return stack.size == 0
end

return {
  new_stack = new_stack,
  push = push,
  pop = pop,
  get_top = get_top,
  is_empty = is_empty,
}
