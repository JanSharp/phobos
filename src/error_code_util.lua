
local types = {
  tokenizer = 1,
  parser = 2,
  jump_linker = 3,
  compiler = 4,
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
local function add_error_code(type, name, message)
  local error_code = {
    id = next_id,
    type = type,
    name = name,
    message = message,
    message_param_count = str_count(message, "%%s"),
  }
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
  "<identifier> expected"
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
  "<identifier> or '...' expected"
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
  "expected_eq_comma_or_in",
  "'=', ',' or 'in' expected"
)
add_error_code(
  types.parser,
  "unexpected_expression",
  "Unexpected expression"
)

---@alias ErrorCodeType integer

---@class ErrorCode
---@field id integer
---@field type ErrorCodeType
---@field name string
---@field message string
---@field message_param_count integer

---@class SourcePosition
---@field line integer
---@field column integer
---@field index nil @ -- TODO: maybe do add the index to all AstTokenNodes

---@class ErrorCodeInstanceParams
---@field error_code ErrorCode
---@field message_args? string[]
---a string describing where the error occurred.\
---Will be concatenated as is to the end of the message if provided
---@field location_str? string
---@field source string @ function source
---@field start_position SourcePosition @ inclusive
---@field stop_position SourcePosition @ inclusive
---@field position SourcePosition @ when provided sets both start and stop position

---@class ErrorCodeInstance
---@field error_code ErrorCode
---@field message_args string[]
---a string describing where the error occurred.\
---Will be concatenated as is to the end of the message if provided
---@field location_str? string
---@field source string @ function source
---@field start_position SourcePosition @ inclusive
---@field stop_position SourcePosition @ inclusive

local function get_position(position)
  return {
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

return {
  types = types,
  codes = error_codes,
  codes_by_id = error_codes_by_id,
  new_error_code = new_error_code_inst,
}
