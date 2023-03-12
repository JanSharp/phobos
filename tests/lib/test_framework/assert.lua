
local deep_compare = require("deep_compare")
local pretty_print = require("pretty_print").pretty_print

local print_full_data_on_error_default = false
---@param value boolean
local function set_print_full_data_on_error_default(value)
  print_full_data_on_error_default = value
end
local function get_print_full_data_on_error_default()
  return print_full_data_on_error_default
end

---@alias DiffCallback fun(expected: string, got: string)

---@type DiffCallback?
local diff_callback
---@param new_diff_callback DiffCallback?
local function set_diff_callback(new_diff_callback)
  diff_callback = new_diff_callback
end

---@type (fun(msg:string?):string?)[]
local err_msg_handlers = {}

---@param handler fun(msg: string?):string?
local function push_err_msg_handler(handler)
  err_msg_handlers[#err_msg_handlers+1] = handler
end

local function pop_err_msg_handler()
  err_msg_handlers[#err_msg_handlers] = nil
end

---@param err string
---@param msg string?
local function add_msg(err, msg)
  -- start at the inner most handler first which was the last one added,
  -- which also means it is the inner most scope
  for i = #err_msg_handlers, 1, -1 do
    msg = err_msg_handlers[i](msg)
  end
  return err..(msg and (": "..msg) or ".")
end

---@param value any
---@param msg string?
local function assert(value, msg)
  if not value then
    error(add_msg("assertion failed", msg))
  end
  return value
end

---@param expected any
---@param got any
---@param msg string?
local function equals(expected, got, msg)
  -- also test for nan
  if got ~= expected and (got == got or expected == expected) then
    error(add_msg("expected "..pretty_print(expected)..", got "..pretty_print(got), msg))
  end
end

---@param expected any
---@param got any
---@param msg string?
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

local function get_ref_locations(locations, side)
  return locations
    and ("\n"..side.." previous references:\n  "..table.concat(locations, "\n  "))
    or ("\n"..side.." no references")
end

---@param expected any
---@param got any
---@param msg string?
---@param options ContentsEqualsOptions?
local function contents_equals(expected, got, msg, options)
  options = options or {}
  local equal, difference = deep_compare.deep_compare(
    expected,
    got,
    options.compare_pairs_iteration_order,
    options.root_name
  )
  local function pretty_print_diff(diff)
    local diff_type = deep_compare.difference_type
    local function equality_diff()
      return "expected "..pretty_print(diff.left, options.serpent_opts)..", got "
        ..pretty_print(diff.right, options.serpent_opts).." at "..diff.location
    end
    return (({
      [diff_type.value_type] = function()
        return "expected type '"..type(diff.left).."', got '"
          ..type(diff.right).."' at "..diff.location
      end,
      [diff_type.c_function] = function()
        return "functions are either non equal C functions, or only one is a C function at "..diff.location
      end,
      [diff_type.function_bytecode] = function()
        return "function bytecode differs at "..diff.location
      end,
      [diff_type.primitive_value] = equality_diff,
      [diff_type.thread] = equality_diff,
      [diff_type.userdata] = equality_diff,
      [diff_type.size] = function()
        return "expected table size "..diff.left_size..", got "..diff.right_size.." at "..diff.location
      end,
      [diff_type.identity_mismatch] = function()
        -- return "got a reference value occurring multiple times even though it should be a different instance, \z
        --   or expected a previously referenced reference value but did not get said value at "..diff.location
        return "reference value identity mismatch at "..diff.location
          ..get_ref_locations(diff.left_ref_locations, "expected")
          ..get_ref_locations(diff.right_ref_locations, "got")
      end,
      [diff_type.custom_comparator_func] = function()
        return "custom compare failed "..(diff.message and ("("..diff.message..") ") or "")
          .."at "..diff.location
      end,
      [diff_type.custom_comparator_table] = function()
          local inner_diffs = diff.inner_differences
          if inner_diffs then
            local parts = {}
            for i, inner_diff in ipairs(inner_diffs) do
              parts[#parts+1] = "\ninner diff "..i..":\n  "
              parts[#parts+1] = pretty_print_diff(inner_diff):gsub("\n", "  \n")
            end
            return "custom compare failed at "..diff.location..", inner diffs: "..table.concat(parts)
          else
            return "custom compare failed at "..diff.location..", unexpected 'nil'"
          end
      end,
    })[diff.type] or error("impossible diff type"))()
  end
  if not equal then
    local err = pretty_print_diff(difference)
    local print_full_data_on_error = print_full_data_on_error_default
    if options.print_full_data_on_error ~= nil then
      print_full_data_on_error = options.print_full_data_on_error
    end
    local do_pretty_print = print_full_data_on_error or diff_callback
    local expected_pretty_printed = do_pretty_print and pretty_print(expected, options.serpent_opts)
    local got_pretty_printed = do_pretty_print and pretty_print(got, options.serpent_opts)
    msg = add_msg(err, msg)
      ..(
        print_full_data_on_error
          and ("\nexpected: "..expected_pretty_printed
            .."\n-----\ngot: "..got_pretty_printed)
          or ""
      )
    if diff_callback then
      ---@cast expected_pretty_printed -nil
      ---@cast got_pretty_printed -nil
      diff_callback(expected_pretty_printed, got_pretty_printed)
    end
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

---@param expected_pattern string
---@param got_func function @ function that's expected to error
---@param msg string?
---@param plain boolean?
local function errors(expected_pattern, got_func, msg, plain)
  local stacktrace
  local success, err = xpcall(got_func, function(err)
    stacktrace = debug.traceback(nil, 2):gsub("\t", "  ")
    return err
  end)
  if success then
    error(add_msg("expected error "..(plain and "" or "pattern ")..pretty_print(expected_pattern)
      ..", got success", msg)
    )
  end
  if ((err == nil) and expected_pattern ~= nil) or not err:find(expected_pattern, 1, plain) then
    error(add_msg("expected error "..(plain and "" or "pattern ")..pretty_print(expected_pattern)
      ..", got error "..pretty_print(err).."\n"..stacktrace, msg)
    )
  end
end

return setmetatable({
  set_print_full_data_on_error_default = set_print_full_data_on_error_default,
  get_print_full_data_on_error_default = get_print_full_data_on_error_default,
  set_diff_callback = set_diff_callback,
  push_err_msg_handler = push_err_msg_handler,
  pop_err_msg_handler = pop_err_msg_handler,
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
