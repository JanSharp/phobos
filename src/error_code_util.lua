
local types = {
  tokenizer = 1,
  parser = 2,
  jump_linker = 3,
  compiler = 4,
  emmy_lua_parser = 5,
  emmy_lua_linker = 6,
}
local error_codes = {}
local error_codes_by_id = {}

local function str_count(str, pattern)
  local c = 0
  for _ in str:gmatch(pattern) do
    c = c + 1
  end
  return c
end

-- I'd say that whenever changing minor versions the ids can change however they want
-- just better not with patch versions
-- but I'm not sure, it might also just be worth it to keep ids consistent forever
local next_id = 1
local function add_error_code(type, name, message, location_str_is_inside_message)
  local error_code = {
    id = next_id,
    type = type,
    name = name,
    message = message,
    message_param_count = str_count(message, "%%s"),
    location_str_is_inside_message = location_str_is_inside_message or false,
  }
  assert(not error_codes[name], "Error code '"..name.."' already exists.")
  error_codes[name] = error_code
  error_codes_by_id[next_id] = error_code
  next_id = next_id + 1
end

add_error_code(
  types.tokenizer,
  "unterminated_string",
  "Unterminated string"
)
add_error_code(
  types.tokenizer,
  "unterminated_string_at_eol",
  "Unterminated string (at end of line %s)"
)
add_error_code(
  types.tokenizer,
  "invalid_hexadecimal_escape",
  "Invalid escape sequence '\\x%s', '\\x' must be followed by 2 hexadecimal digits"
)
add_error_code(
  types.tokenizer,
  "too_large_decimal_escape",
  "Too large value in decimal escape sequence '\\%s'"
)
add_error_code(
  types.tokenizer,
  "unrecognized_escape",
  "Unrecognized escape sequence '\\%s'"
)
add_error_code(
  types.tokenizer,
  "invalid_block_string_open_bracket",
  "Invalid block string open bracket"
)
add_error_code(
  types.tokenizer,
  "unterminated_block_string",
  "Unterminated block string"
)
add_error_code(
  types.tokenizer,
  "malformed_number",
  "Malformed number '%s'"
)
add_error_code(
  types.tokenizer,
  "invalid_token",
  "Invalid token '%s'"
)

add_error_code(
  types.parser,
  "incomplete_node",
  "<incomplete due to prior syntax error in this node>"
)
add_error_code(
  types.parser,
  "expected_ident",
  "<name> expected"
)
add_error_code(
  types.parser,
  "expected_token",
  "'%s' expected"
)
add_error_code(
  types.parser,
  "expected_closing_match",
  "'%s' expected (to close '%s' at %s)"
)
add_error_code(
  types.parser,
  "expected_ident_or_vararg",
  "<name> or '...' expected"
)
add_error_code(
  types.parser,
  "expected_func_args",
  "Function arguments expected"
)
add_error_code(
  types.parser,
  "unexpected_token",
  "Unexpected token"
)
add_error_code(
  types.parser,
  "vararg_outside_vararg_func",
  "Cannot use '...' outside a vararg function"
)
add_error_code(
  types.parser,
  "duplicate_label",
  "Duplicate label '%s' (previously defined at %s)"
)
add_error_code(
  types.parser,
  "expected_eq_comma_or_in",
  "'=', ',' or 'in' expected"
)
add_error_code(
  types.parser,
  "unexpected_expression",
  "Unexpected expression"
)

add_error_code(
  types.jump_linker,
  "break_outside_loop",
  "'break'${location_str} is not inside a loop",
  true
)
add_error_code(
  types.jump_linker,
  "no_visible_label",
  "No visible label '%s' for 'goto'"
)
add_error_code(
  types.jump_linker,
  "jump_to_label_in_scope_of_new_local",
  "Unable to jump from 'goto' '%s'${location_str} to label at %s \z
    because it is in the scope of the local '%s' at %s",
  true
)

-- el is short for EmmyLua

add_error_code(
  types.emmy_lua_parser,
  "el_expected_pattern",
  "Expected pattern '%s'"
)
add_error_code(
  types.emmy_lua_parser,
  "el_expected_eol",
  "Expected line to end"
)
add_error_code(
  types.emmy_lua_parser,
  "el_expected_special_tag",
  "Expected tag @%s, got @%s"
)
add_error_code(
  types.emmy_lua_parser,
  "el_expected_blank",
  "Expected blank"
)
add_error_code(
  types.emmy_lua_parser,
  "el_expected_ident",
  "Expected identifier"
)
add_error_code(
  types.emmy_lua_parser,
  "el_expected_type",
  "Expected type"
)
add_error_code(
  types.emmy_lua_parser,
  "el_unexpected_special_tag",
  "Unexpected tag @%s"
)

add_error_code(
  types.emmy_lua_linker,
  "el_duplicate_type_name",
  "Duplicate type (class/alias) name %s"
)
add_error_code(
  types.emmy_lua_linker,
  "el_expected_reference_to_class",
  -- second arg is for optional extra info like the current reference name
  "Expected reference specifically to a class, got type_type %s%s"
)
add_error_code(
  types.emmy_lua_linker,
  "el_unresolved_reference",
  "Unable to resolve reference to the type %s"
)
add_error_code(
  types.emmy_lua_linker,
  "el_builtin_base_class",
  "Base class %s for the class --TODO%%s is a builtin class which is not allowed"
)

---@alias ErrorCodeType integer

---@class ErrorCode
---@field id integer
---@field type ErrorCodeType
---@field name string
---@field message string
---@field message_param_count integer
---@field location_str_is_inside_message boolean

---@class ErrorCodeInstanceParams
---@field error_code ErrorCode
---@field message_args? string[]
---a string describing where the error occurred.\
---Will be concatenated as is to the end of the message if provided
---@field location_str? string
---@field source string @ function source
---@field start_position Position? @ inclusive
---@field stop_position Position? @ inclusive
---@field position Position? @ when provided sets both start and stop position

---@class ErrorCodeInstance
---@field error_code ErrorCode
---@field message_args string[]
---a string describing where the error occurred.\
---Will be concatenated as is to the end of the message if provided
---@field location_str? string
---@field source string @ function source
---@field start_position Position? @ inclusive
---@field stop_position Position? @ inclusive

local function get_position(position)
  return position and {
    line = position.line,
    column = position.column,
  }
end

---@param params ErrorCodeInstanceParams
---@return ErrorCodeInstance
local function new_error_code_inst(params)
  return {
    error_code = params.error_code,
    message_args = params.message_args or {},
    location_str = params.location_str,
    source = params.source,
    start_position = get_position(params.start_position or params.position),
    stop_position = get_position(params.stop_position or params.position),
  }
end

---@param error_code_inst ErrorCodeInstance
---@return string
local function get_message(error_code_inst)
  if (error_code_inst.message_args and (#error_code_inst.message_args) or 0)
    ~= error_code_inst.error_code.message_param_count
  then
    assert(false, "Expected "..error_code_inst.error_code.message_param_count.." message args for '"
      ..error_code_inst.error_code.name.."', got "..(#error_code_inst.message_args).."."
    )
  end
  local message = error_code_inst.error_code.message
  if error_code_inst.error_code.location_str_is_inside_message then
    message = message:gsub("${location_str}", error_code_inst.location_str or "")
  end
  return string.format(
    message,
    table.unpack(error_code_inst.message_args)
  )..((not error_code_inst.error_code.location_str_is_inside_message) and error_code_inst.location_str or "")
end

---@param errors_label string|"syntax errors"|"EmmyLua syntax errors" @
---type annotations are suggested strings
local function get_message_for_list(error_code_insts, errors_label, max_errors_shown)
  if error_code_insts[1] then
    local error_count = #error_code_insts
    max_errors_shown = max_errors_shown or error_count
    local msgs = {}
    for i = 1, math.min(error_count, max_errors_shown) do
      msgs[i] = get_message(error_code_insts[i])
    end
    return (error_count).." "..errors_label
      ..(error_count > max_errors_shown and (", showing first "..max_errors_shown) or "")
      ..":\n"..table.concat(msgs, "\n")
  end
end

return {
  types = types,
  codes = error_codes,
  codes_by_id = error_codes_by_id,
  new_error_code = new_error_code_inst,
  get_message = get_message,
  get_message_for_list = get_message_for_list,
}
