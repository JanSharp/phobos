
local util = require("util")

---@param func ILFunction
local function create_borders(func)
  util.debug_assert(not func.has_borders, "The create_borders function is meant to be run for the initial \z
    creation of borders, however the given function already has borders."
  )
  func.has_borders = true

  local prev_border = {prev_inst = nil}
  local inst = func.instructions.first
  while inst do
    prev_border.next_inst = inst
    inst.prev_border = prev_border
    prev_border = {prev_inst = inst}
    inst.next_border = prev_border
    inst = inst.next
  end
end

---@param func ILFunction
local function create_borders_recursive(func)
  create_borders(func)
  for _, inner_func in ipairs(func.inner_functions) do
    create_borders_recursive(inner_func)
  end
end

---@param func ILFunction
local function ensure_has_borders(func)
  if func.has_borders then return end
  create_borders(func)
end

---@param func ILFunction
local function ensure_has_borders_recursive(func)
  ensure_has_borders(func)
  for _, inner_func in ipairs(func.inner_functions) do
    ensure_has_borders_recursive(inner_func)
  end
end

---@param func ILFunction
---@param func_name string
local function assert_has_borders(func, func_name)
  util.debug_assert(func.has_borders, "Attempt to use 'il_borders."..func_name.."' with a func without borders.")
end

---@param func ILFunction
---@param start_border ILBorder? @ Inclusive. Default: `prev_border` of the first instruction.
---@param stop_border ILBorder? @ Inclusive. Default: `next_border` of the last instruction.
---@return fun(): ILBorder?
local function iterate_borders(func, start_border, stop_border)
  assert_has_borders(func, "iterate_borders")
  if start_border and stop_border and start_border.next_inst and stop_border.next_inst
    and start_border.next_inst.index > stop_border.next_inst.index
  then
    util.debug_abort("Attempt to iterate borders where the start_border comes after the stop_border.")
    -- Could also simply return an iterator that always returns 'nil'.
  end
  ---@type ILBorder?
  local next_border = start_border or func.instructions.first.prev_border
  return function()
    local result = next_border
    next_border = next_border ~= stop_border and next_border and next_border.next_inst.next_border or nil
    return result
  end
end

return {
  create_borders = create_borders,
  create_borders_recursive = create_borders_recursive,
  ensure_has_borders = ensure_has_borders,
  ensure_has_borders_recursive = ensure_has_borders_recursive,
  iterate_borders = iterate_borders,
}
