
local deep_compare = require("deep_compare")
local pretty_print = require("pretty_print")

local function add_msg(err, msg)
  return err..(msg and ": "..msg or ".")
end

local function assert(value, msg)
  if not value then
    error(add_msg("assertion failed", msg))
  end
end

local function equals(expected, got, msg)
  if got ~= expected then
    error(add_msg("expected "..pretty_print(expected)..", got "..pretty_print(got), msg))
  end
end

local function not_equals(expected, got, msg)
  if got == expected then
    error(add_msg("expected not "..pretty_print(got), msg))
  end
end

local function nan(got, msg)
  if got == got then
    error(add_msg("expected "..pretty_print(0/0), msg))
  end
end

local function not_nan(got, msg)
  if got ~= got then
    error(add_msg("expected not "..pretty_print(got), msg))
  end
end

local function contents_equals(expected, got, msg)
  local equal, difference = deep_compare.deep_compare(expected, got)
  if not equal then
    local err
    if difference.type == deep_compare.difference_type.value_type then
      err = "expected type '"..type(difference.left).."', got '"
        ..type(difference.right).."' at "..difference.location
    elseif difference.type == deep_compare.difference_type.c_function then
      err = "functions are either non equal C functions, or only one is a C function at "..difference.location
    elseif difference.type == deep_compare.difference_type.function_bytecode then
      err = "function bytecode differs at "..difference.location
    elseif difference.type == deep_compare.difference_type.primitive_value then
      err = "expected "..pretty_print(difference.left)..", got "
        ..pretty_print(difference.right).." at "..difference.location
    elseif difference.type == deep_compare.difference_type.size then
      err = "table size differs at "..difference.location
    end
    error(add_msg(err, msg))
  end
end

local function errors(expected_pattern, got_func, msg)
  local success, err = pcall(got_func)
  if success then
    error(add_msg("expected error pattern "..pretty_print(expected_pattern), msg))
  end
  if not err:find(expected_pattern) then
    error(add_msg("expected error pattern "..pretty_print(expected_pattern)..", got error "..pretty_print(err), msg))
  end
end

return {
  assert = assert,
  equals = equals,
  not_equals = not_equals,
  nan = nan,
  not_nan = not_nan,
  contents_equals = contents_equals,
  errors = errors,
}
