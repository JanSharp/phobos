
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

---@class ContentsEqualsOptions
---@field compare_pairs_iteration_order boolean
---@field print_full_data_on_error boolean
---@field root_name string
---@field serpent_opts table

---@param options ContentsEqualsOptions
local function contents_equals(expected, got, msg, options)
  local equal, difference = deep_compare.deep_compare(
    expected,
    got,
    options and options.compare_pairs_iteration_order,
    options and options.root_name
  )
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
      err = "expected "..pretty_print(difference.left, options.serpent_opts)..", got "
        ..pretty_print(difference.right, options.serpent_opts).." at "..difference.location
    elseif difference.type == deep_compare.difference_type.size then
      err = "table size differs at "..difference.location
    end
    error(add_msg(err, msg)
      ..(
        options and options.print_full_data_on_error
          and ("\nexpected: "..pretty_print(expected, options.serpent_opts)
            .."\n-----\ngot: "..pretty_print(got, options.serpent_opts))
          or ""
      )
    )
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
  do_not_compare_flag = deep_compare.do_not_compare_flag,
  errors = errors,
}
