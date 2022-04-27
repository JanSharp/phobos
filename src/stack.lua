
local function new_stack()
  return {size = 0}
end

local function push(stack, value)
  local size = stack.size + 1
  stack.size = size
  stack[size] = value
end

local function pop(stack)
  local size = stack.size
  local value = stack[size]
  stack[size] = nil
  stack.size = size - 1
  return value
end

local function get_top(stack)
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
