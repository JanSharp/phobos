
local error_code_util = require("error_code_util")
local util = require("util")
local keywords = util.invert{
  "and", "break", "do", "else", "elseif", "end", "false",
  "for", "function", "if", "in", "local", "nil", "not",
  "or", "repeat", "return", "then", "true", "until",
  "while", "goto",
}

---@param token_type TokenType
---@param index number
---@param line number
---@param column number
---@return Token
local function new_token(token_type,index,line,column)
  return {
    token_type = token_type,
    index = index,
    line = line,
    column = column
  }
end

local function add_error_code_inst(token, inst)
  token.error_code_insts = token.error_code_insts or {}
  token.error_code_insts[#token.error_code_insts+1] = inst
end

---@param str string
---@param index integer
---@param next_char string
---@return integer
---@return Token
local function peek_equals(str,index,next_char,line,column)
  if str:sub(index+1,index+1) == "=" then
    return index+2,new_token(next_char.."=",index,line,column)
  else
    return index+1,new_token(next_char,index,line,column)
  end
end

local newline_chars = util.invert{"\n", "\r"}

local function consume_newline(str, index, state, current_char)
  current_char = current_char or str:sub(index, index)
  assert(newline_chars[current_char], "Trying to consume a newline when there isn't a newline")
  local next_char = str:sub(index + 1, index + 1)
  state.line = state.line + 1
  if newline_chars[next_char] and next_char ~= current_char then
    state.line_offset = index + 1
  else
    state.line_offset = index
  end
    return state.line_offset + 1
end

local escape_sequence_lut = {
  a = "\a", b = "\b", f = "\f", n = "\n",
  r = "\r", t = "\t", v = "\v", ["\\"] = "\\",
  ['"'] = '"', ["'"] = "'",
  -- ["\r"] = "\r", ["\n"] = "\n", -- \r and \n are handled separately
}

---@param str string
---@param index integer
---@param quote "\""|"'"
---@param state TokenizeState
---@return integer
---@return Token
local function read_string(str,index,quote,state)
  local token = new_token("string",index,state.line,index - state.line_offset)

  local i = index + 1
  local next_char = str:sub(i,i)
  if next_char == quote then
    -- empty string
    token.value = ""
    token.src_quote = quote
    token.src_value = ""
    return i+1,token
  end

  local parts = {}

  ::matching::
  local start_i = i
  -- read through normal text...
  while str:match("^[^"..quote.."\\\r\n]",i) do
    i = i + 1
  end

  if i ~= start_i then
    parts[#parts+1] = str:sub(start_i, i - 1)
  end

  next_char = str:sub(i,i)

  if next_char == quote then
    -- finished string
    if token.token_type == "invalid" then
      token.value = str:sub(index,i)
    else
      token.src_value = str:sub(index+1,i-1)
      token.value = table.concat(parts)
      -- token.src_is_block_str = false -- why bother setting quite literally anything to false :P
      token.src_quote = quote
    end
    return i+1,token
  elseif next_char == "" then
    token.token_type = "invalid"
    token.value = str:sub(index,i-1)
    add_error_code_inst(token, error_code_util.new_error_code{
      error_code = error_code_util.codes.unterminated_string,
      source = state.source,
      -- position at eof, so technically 1 char past the entire string
      position = {line = state.line, column = i - state.line_offset},
    })
    return i,token
  elseif newline_chars[next_char] then
    token.token_type = "invalid"
    token.value = str:sub(index,i-1)
    add_error_code_inst(token, error_code_util.new_error_code{
      error_code = error_code_util.codes.unterminated_string_at_eol,
      message_args = {tostring(state.line)},
      source = state.source,
      -- position at the newline
      position = {line = state.line, column = i - state.line_offset},
    })
    return i,token
  elseif next_char == "\\" then
    -- advance past an escape sequence...
    i = i + 1
    next_char = str:sub(i,i)
    if next_char == "x" then
      local digits = str:match("^%x%x", i + 1)
      if not digits then
        token.token_type = "invalid"
        add_error_code_inst(token, error_code_util.new_error_code{
          error_code = error_code_util.codes.invalid_hexadecimal_escape,
          message_args = {str:sub(i + 1, i + 2)},
          source = state.source,
          -- start at \
          start_position = {line = state.line, column = (i - 1) - state.line_offset},
          -- stop at x
          stop_position = {line = state.line, column = i - state.line_offset},
        })
        i = i + 1 -- skip x
      else
        parts[#parts+1] = string.char(tonumber(digits, 16))
        i = i + 3 -- skip x and two hex digits
      end
      goto matching
    elseif newline_chars[next_char] then
      parts[#parts+1] = "\n"
      i = consume_newline(str, i, state, next_char)
      goto matching
    elseif next_char == "z" then
      --skip z and whitespace
      local _,skip = str:find("^z%s*",i)
      local j = i + 1
      i = skip + 1
      -- figure out the right line and line_offset
      while true do
        local newline_index, newline_char = str:match("^[^%S\r\n]*()([\r\n])", j)
        if not newline_index then
          break
        end
        j = consume_newline(str, newline_index, state, newline_char)
      end
      goto matching
    elseif escape_sequence_lut[next_char] then
      parts[#parts+1] = escape_sequence_lut[next_char]
      i = i + 1
      goto matching
    else
      local digits_start, skip, digits = str:find("^(%d%d?%d?)",i)
      if digits_start then
        local number = tonumber(digits, 10)
        if number > 255 then
          token.token_type = "invalid"
          add_error_code_inst(token, error_code_util.new_error_code{
            error_code = error_code_util.codes.too_large_decimal_escape,
            message_args = {digits},
            source = state.source,
            -- start at at \
            start_position = {line = state.line, column = (i - 1) - state.line_offset},
            -- stop at the last digit
            stop_position = {line = state.line, column = skip - state.line_offset},
          })
        else
          parts[#parts+1] = string.char(number)
        end
        i = skip + 1
        goto matching
      else
        token.token_type = "invalid"
        add_error_code_inst(token, error_code_util.new_error_code{
          error_code = error_code_util.codes.unrecognized_escape,
          message_args = {next_char},
          source = state.source,
          -- start at \
          start_position = {line = state.line, column = (i - 1) - state.line_offset},
          -- stop at `next_char`
          stop_position = {line = state.line, column = i - state.line_offset},
        })
        -- nothing to skip
        goto matching
      end
    end
  end
end

local block_string_open_bracket_pattern = "^%[(=*)%["

---@param str string
---@param index integer
---@param state TokenizeState
---@return integer
---@return Token
local function read_block_string(str,index,state)
  local _,open_end,pad = str:find(block_string_open_bracket_pattern,index)
  if not pad then
    local token = new_token("invalid",index,state.line,index - state.line_offset)
    token.value = "["
    add_error_code_inst(token, error_code_util.new_error_code{
      error_code = error_code_util.codes.invalid_block_string_open_bracket,
      source = state.source,
      -- position at [
      position = {line = state.line, column = index - state.line_offset},
    })
    return index+1,token
  end

  local token_line = state.line
  local token_col = index - state.line_offset

  local has_leading_newline = false
  local next_index = open_end + 1
  do
    local first_char = str:sub(next_index,next_index)
    if newline_chars[first_char] then
      has_leading_newline = true
      next_index = consume_newline(str, next_index, state, first_char)
    end
  end

  local parts = {""}
  local close_pattern = "^%]"..pad.."%]()"
  while true do
    local part, stopped_at, stop_char = str:match("^([^\r\n%]]*)()(.?)", next_index)
    parts[#parts+1] = part
    if stop_char == "]" then
      local bracket_end = str:match(close_pattern, stopped_at)
      if bracket_end then
        local token = new_token("string", index, token_line, token_col)
        token.value = table.concat(parts)
        token.src_is_block_str = true
        token.src_has_leading_newline = has_leading_newline
        token.src_pad = pad
        return bracket_end, token
      else
        parts[#parts+1] = "]"
        next_index = stopped_at + 1
      end
    elseif stop_char == "" then
      local token = new_token("invalid", index, token_line, token_col)
      parts[1] = "["..pad.."["..(has_leading_newline and "\n" or "")
      token.value = table.concat(parts)
      add_error_code_inst(token, error_code_util.new_error_code{
        error_code = error_code_util.codes.unterminated_block_string,
        source = state.source,
        -- position at eof, so technically 1 char past the entire string
        position = {line = state.line, column = stopped_at - state.line_offset},
      })
      return stopped_at, token
    else
      parts[#parts+1] = "\n"
      next_index = consume_newline(str, stopped_at, state, stop_char)
    end
  end
end

---@param str string
---@param index integer
---@param state TokenizeState
---@return integer?
---@return Token?
local function read_number(str, index, state)
  local start_index = index
  ---cSpell:ignore llex
  -- this parsing matches how Lua parses numbers. While the logic is different, the result is identical
  -- see llex.c:229 (function "read_numeral")
  local exponent = "[Ee]"
  if str:find("^0[Xx]", index) then
    exponent = "[Pp]"
    index = index + 2
  end
  local pattern = "^[%x.]*"..exponent.."[+-]?()"
  while true do
    local next_index = str:match(pattern, index)
    if not next_index then break end
    index = next_index
  end
  index = str:match("^[%x.]*()", index) -- always matches, because of `*` instead of `+`

  local src_value = str:sub(start_index, index - 1)
  local value = tonumber(src_value)
  local token
  if value then
    token = new_token("number", start_index, state.line, start_index - state.line_offset)
    token.src_value = src_value
    token.value = value
  else
    token = new_token("invalid", start_index, state.line, start_index - state.line_offset)
    token.value = src_value
    add_error_code_inst(token, error_code_util.new_error_code{
      error_code = error_code_util.codes.malformed_number,
      message_args = {src_value},
      source = state.source,
      -- start at the first char of the number
      start_position = {line = state.line, column = start_index - state.line_offset},
      -- stop at the last char of the number
      stop_position = {line = state.line, column = index - 1 - state.line_offset},
    })
  end
  return index, token
end

---@param invalid_char string
---@param index integer
---@param state TokenizeState
---@return integer
---@return Token
local function simple_invalid_token(invalid_char, index, state)
  local token = new_token("invalid",index,state.line,index - state.line_offset)
  token.value = invalid_char
  add_error_code_inst(token, error_code_util.new_error_code{
    error_code = error_code_util.codes.invalid_token,
    message_args = {invalid_char},
    source = state.source,
    -- position at index
    position = {line = state.line, column = index - state.line_offset},
  })
  return index+1,token
end

local zero_byte = string.byte("0")
local nine_byte = string.byte("9")
---@param str string
---@param index integer
---@return boolean
local function is_digit(str, index)
  local byte = str:byte(index)
  return byte and zero_byte <= byte and byte <= nine_byte
end

---@param state TokenizeState
---@param index integer
---@return integer?
---@return Token?
local function next_token(state,index)
  if not index then index = 1 end
  local str = state.str
  local next_char = str:sub(index,index)
  if next_char == "" then
    return -- EOF
  end

  if next_char:match("%s") then
    local value, line_end, newline = str:match("([^%S\r\n]*)()([\r\n]?)", index)
    local token = new_token("blank", index, state.line, index - state.line_offset)
    if newline ~= "" then -- ends with newline?
      token.value = value.."\n"
      return consume_newline(str, line_end, state), token
    end
    token.value = value
    return line_end, token
  elseif next_char:match("[+*/%%^#;,(){}%]]") then
    return index+1,new_token(next_char,index,state.line,index - state.line_offset)
  elseif next_char:match("[>=<]") then
    return peek_equals(str,index,next_char,state.line,index - state.line_offset)
  elseif next_char == "[" then
    local peek = str:sub(index+1,index+1)
    if peek == "=" or peek == "[" then
      return read_block_string(str,index,state)
    else
      return index+1,new_token("[",index,state.line,index - state.line_offset)
    end
  elseif next_char == "-" then
    if str:sub(index+1,index+1) == "-" then
      if str:find(block_string_open_bracket_pattern, index + 2) then
        --[[
          read block string, build a token from that
        ]]
        local next_index,token = read_block_string(str,index+2,state)
        -- correct index and column
        token.index = index
        token.column = token.column - 2
        if token.token_type == "invalid" then
          token.value = "--"..token.value
        else
          token.token_type = "comment"
        end
        return next_index,token
      else
        local _,token_end,text = str:find("^([^\r\n]*)",index+2)
        local token = new_token("comment",index,state.line,index - state.line_offset)
        token.value = text
        return token_end+1,token
      end
    else
      return index+1,new_token("-",index,state.line,index - state.line_offset)
    end
  elseif next_char == "~" then
    if str:sub(index+1,index+1) == "=" then
      return index+2,new_token("~=",index,state.line,index - state.line_offset)
    else
      return simple_invalid_token(next_char,index,state)
    end
  elseif next_char == ":" then
    if str:sub(index+1,index+1) == ":" then
      return index+2,new_token("::",index,state.line,index - state.line_offset)
    else
      return index+1,new_token(":",index,state.line,index - state.line_offset)
    end
  elseif next_char == "." then
    if str:sub(index+1,index+1) == "." then
      if str:sub(index+2,index+2) == "." then
        return index+3,new_token("...",index,state.line,index - state.line_offset)
      else
        return index+2,new_token("..",index,state.line,index - state.line_offset)
      end
    elseif is_digit(str, index + 1) then
      return read_number(str, index, state)
    else
      return index+1,new_token(".",index,state.line,index - state.line_offset)
    end
  elseif next_char == '"' then
    return read_string(str,index,next_char,state)
  elseif next_char == "'" then
    return read_string(str,index,next_char,state)
  elseif is_digit(next_char, 1) then
    return read_number(str, index, state)
  else
    -- try to match keywords/identifiers
    local match_start,match_end,ident = str:find("^([_%a][_%w]*)",index)
    if match_start == index then
      local token = new_token(
        keywords[ident] and ident or "ident",
        index,state.line,index - state.line_offset
      )
      if not keywords[ident] then
        token.value = ident
      end
      return match_end+1,token
    else
      return simple_invalid_token(next_char,index,state)
    end
  end
end

---@class TokenizeState
---@field str string
---@field source string
---@field line integer
---@field line_offset integer @ the exact index of the last newline
---@field prev_line integer|nil
---@field prev_line_offset integer|nil
---see AstMain description for more info
---@field shebang_line string|nil

---@param str string
---@param source? string @ if provided it is used for the `source` field of error code instances
---@return fun(state: TokenizeState, index: integer|nil): integer|nil, Token next_token
---@return TokenizeState state
---@return integer? index
local function tokenize(str, source)
  local index
  local state = {
    str = str,
    source = source,
    line = 1,
    line_offset = 0, -- pretend the previous character was a newline. not too far fetched
  }
  if str:find("^\xef\xbb\xbf") then -- ignore utf8 byte-order mark (BOM)
    state.line_offset = 3
    index = 4
  end
  ---cSpell:ignore skipcomment, lauxlib
  -- does the same thing as skipcomment in lauxlib.c
  if str:find("^#", index) then -- first line is a comment (Unix exec. file)?
    -- read first line and skip parsing it
    local comment, stop = str:match("([^\n]+)()", index)
    state.shebang_line = comment
    state.line_offset = stop - 1
    index = stop
  end
  return next_token,state,index
end

return tokenize
