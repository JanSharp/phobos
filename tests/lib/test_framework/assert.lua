
local deep_compare = require("deep_compare")
local pretty_print = require("pretty_print").pretty_print

local print_full_data_on_error_default = false
local function set_print_full_data_on_error_default(value)
  print_full_data_on_error_default = value
end
local function get_print_full_data_on_error_default()
  return print_full_data_on_error_default
end

local function add_msg(err, msg)
  return err..(msg and ": "..msg or ".")
end

local function assert(value, msg)
  if not value then
    error(add_msg("assertion failed", msg))
  end
  return value
end

local function equals(expected, got, msg)
  -- also test for nan
  if got ~= expected and (got == got or expected == expected) then
    error(add_msg("expected "..pretty_print(expected)..", got "..pretty_print(got), msg))
  end
end

local function not_equals(expected, got, msg)
  -- also tests for nan
  if got == expected or (got ~= got and expected ~= expected) then
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
  options = options or {}
  local equal, difference = deep_compare.deep_compare(
    expected,
    got,
    options.compare_pairs_iteration_order,
    options.root_name
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
    elseif difference.type == deep_compare.difference_type.identity_mismatch then
      err = "got a reference value occurring multiple times even though it should be a different instance, \z
        or expected a previously referenced reference value but did not get said value at "..difference.location
    elseif difference.type == deep_compare.difference_type.custom_comparator_table then
      err = "custom compare failed at "..difference.location
    elseif difference.type == deep_compare.difference_type.custom_comparator_func then
      err = "custom compare failed "..(difference.message and ("("..difference.message..") ") or "")
        .."at "..difference.location
    end
    local print_full_data_on_error = print_full_data_on_error_default
    if options.print_full_data_on_error ~= nil then
      print_full_data_on_error = options.print_full_data_on_error
    end
    msg = add_msg(err, msg)
      ..(
        print_full_data_on_error
          and ("\nexpected: "..pretty_print(expected, options.serpent_opts)
            .."\n-----\ngot: "..pretty_print(got, options.serpent_opts))
          or ""
      )
    local c = 0
    local add_err_again_at_the_end = false
    for _ in msg:gmatch("\n") do
      c = c + 1
      if c >= 15 then
        -- with 15 newlines it is 16 lines total.
        -- with the error duplicated at the end it will then be 17+ lines
        add_err_again_at_the_end = true
        break
      end
    end
    error(msg..(add_err_again_at_the_end and ("\n^^^ "..err.." ^^^") or ""))
  end
end

local function errors(expected_pattern, got_func, msg, plain)
  local success, err = pcall(got_func)
  if success then
    error(add_msg("expected error "..(plain and "" or "pattern ")..pretty_print(expected_pattern)
      ..", got success", msg)
    )
  end
  if not err:find(expected_pattern, 1, plain) then
    error(add_msg("expected error "..(plain and "" or "pattern ")..pretty_print(expected_pattern)
      ..", got error "..pretty_print(err), msg)
    )
  end
end

return setmetatable({
  set_print_full_data_on_error_default = set_print_full_data_on_error_default,
  get_print_full_data_on_error_default = get_print_full_data_on_error_default,
  assert = assert,
  equals = equals,
  not_equals = not_equals,
  contents_equals = contents_equals,
  do_not_compare_flag = deep_compare.do_not_compare_flag,
  custom_comparator = deep_compare.register_custom_comparator,
  errors = errors,
}, {
  __call = function(_, ...)
    return assert(...)
  end,
})
