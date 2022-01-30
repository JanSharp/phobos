
local invert = require("invert")
local keywords = invert{
  "and", "break", "do", "else", "elseif", "end", "false",
  "for", "function", "if", "in", "local", "nil", "not",
  "or", "repeat", "return", "then", "true", "until",
  "while", "goto",
}

---@alias TokenType
---| '"blank"'
---| '"comment"'
---| '"string"'
---| '"number"'
---| '"ident"' @ identifier
---| '"eof"' @ not created in the tokenizer, but created and used by the parser
---| '"invalid"'
---
---| '"+"'
---| '"*"'
---| '"/"'
---| '"%"'
---| '"^"'
---| '"#"'
---| '";"'
---| '","'
---| '"("'
---| '")"'
---| '"{"'
---| '"}"'
---| '"]"'
---| '"["'
---| '"<"'
---| '"<="'
---| '"="'
---| '"=="'
---| '">"'
---| '">="'
---| '"-"'
---| '"~="'
---| '"::"'
---| '":"'
---| '"..."'
---| '".."'
---| '"."'
---keywords:
---| '"and"'
---| '"break"'
---| '"do"'
---| '"else"'
---| '"elseif"'
---| '"end"'
---| '"false"'
---| '"for"'
---| '"function"'
---| '"if"'
---| '"in"'
---| '"local"'
---| '"nil"'
---| '"not"'
---| '"or"'
---| '"repeat"'
---| '"return"'
---| '"then"'
---| '"true"'
---| '"until"'
---| '"while"'
---| '"goto"'

---@class Token
---@field token_type TokenType
---@field index number
---@field line number
---@field column number
---for `blank`, `comment`, `string`, `number`, `ident` and `invalid` tokens\
---"blank" tokens shall never contain `\n` in the middle of their value\
---"comment" tokens with `not src_is_block_str` do not contain trailing `\n`
---@field value string|number
---@field src_is_block_str boolean @ for `string` and `comment` tokens
---@field src_quote string @ for non block `string` and `comment` tokens
---@field src_value string @ for non block `string`, `comment` and `number` tokens
---@field src_has_leading_newline boolean @ for block `string` and `comment` tokens
---@field src_pad string @ the `=` chain for block `string` and `comment` tokens
---@field leading Token[] @ `blank` and `comment` tokens before this token. Set and used by the parser
---for `invalid` tokens
---@field error_messages string[]

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

---@param str string
---@param index number
---@param next_char string
---@return number
---@return Token
local function peek_equals(str,index,next_char,line,column)
  if str:sub(index+1,index+1) == "=" then
    return index+2,new_token(next_char.."=",index,line,column)
  else
    return index+1,new_token(next_char,index,line,column)
  end
end

local newline_chars = invert{"\n", "\r"}

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
    token.error_messages = token.error_messages or {}
    token.error_messages[#token.error_messages+1] = "Unterminated string"
    return i,token
  elseif newline_chars[next_char] then
    token.token_type = "invalid"
    token.value = str:sub(index,i-1)
    token.error_messages = token.error_messages or {}
    token.error_messages[#token.error_messages+1] =
      "Unterminated string (at end of line " .. state.line..")"
    return i,token
  elseif next_char == "\\" then
    -- advance past an escape sequence...
    i = i + 1
    next_char = str:sub(i,i)
    if next_char == "x" then
      local digits = str:match("^%x%x", i + 1)
      if not digits then
        token.token_type = "invalid"
        token.error_messages = token.error_messages or {}
        token.error_messages[#token.error_messages+1] = "Invalid escape sequence '\\x"
          ..str:sub(i + 1, i + 2).."', '\\x' must be followed by 2 hexadecimal digits."
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
          token.error_messages = token.error_messages or {}
          token.error_messages[#token.error_messages+1] =
            "Too large value in decimal escape sequence '\\"..digits.."'"
        else
          parts[#parts+1] = string.char(number)
        end
        i = skip + 1
        goto matching
      else
        token.token_type = "invalid"
        token.error_messages = token.error_messages or {}
        token.error_messages[#token.error_messages+1] = "Unrecognized escape '\\".. next_char .. "'"
        -- nothing to skip
        goto matching
      end
    end
  end
end

local block_string_open_bracket_pattern = "^%[(=*)%["

local function read_block_string(str,index,state)
  local _,open_end,pad = str:find(block_string_open_bracket_pattern,index)
  if not pad then
    local token = new_token("invalid",index,state.line,index - state.line_offset)
    token.value = "["
    token.error_messages = {"Invalid string open bracket"}
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
      token.error_messages = {"Unterminated block string"}
      parts[1] = "["..pad.."["
      token.value = table.concat(parts)
      return stopped_at, token
    else
      parts[#parts+1] = "\n"
      next_index = consume_newline(str, stopped_at, state, stop_char)
    end
  end
end

-- TODO: remove code duplication and double check if this can really read all formats of numbers
local function try_read_number(str, index, state)
  -- hex numbers: "0x%x*" followed by "%.%x+" followed by "[pP][+-]?%x+"
  local hex_start,hex_end = str:find("^0[xX]%x*",index) -- "integer part"
  if hex_start then
    -- this basically means %x* didn't match anything
    local omitted_integer_part = hex_start + 1 == hex_end
    local _,fractional_end = str:find("^%.%x+",hex_end+1)
    if fractional_end then
      hex_end = fractional_end
    elseif omitted_integer_part then
      -- this actually only ever happens if the number is just 0x or 0X
      local token = new_token("invalid",index,state.line,index - state.line_offset)
      token.value = str:sub(hex_start,hex_end)
      token.error_messages = {"Malformed number '"..token.value.."'"}
      return hex_end+1,token
    else
      -- consume trailing dot
      _, fractional_end = str:find("^%.", hex_end + 1)
      hex_end = fractional_end or hex_end
    end
    local exponent_start,exponent_end = str:find("^[pP][%-%+]?%x+",hex_end+1)
    if exponent_start then
      hex_end = exponent_end
    end
    local token = new_token("number",index,state.line,index - state.line_offset)
    token.src_value = str:sub(hex_start,hex_end)
    token.value = tonumber(token.src_value)
    return hex_end+1,token
  end

  -- decimal numbers: "%d*" followed by "%.%d+" followed by "[eE][+-]?%d+"
  local num_start,num_end = str:find("^%d*",index) -- "integer part"
  if num_start then
    -- this basically means %d* didn't match anything
    local omitted_integer_part = num_start > num_end
    local _,fractional_end = str:find("^%.%d+",num_end+1)
    if fractional_end then
      num_end = fractional_end
    elseif omitted_integer_part then
      return
    else
      -- consume trailing dot
      _, fractional_end = str:find("^%.", num_end + 1)
      num_end = fractional_end or num_end
    end
    local exponent_start,exponent_end = str:find("^[eE][%-%+]?%d+",num_end+1)
    if exponent_start then
      num_end = exponent_end
    end
    local token = new_token("number",index,state.line,index - state.line_offset)
    token.src_value = str:sub(num_start,num_end)
    token.value = tonumber(token.src_value)
    return num_end+1,token
  end
end

local function simple_invalid_token(invalid_char, index, state)
  local token = new_token("invalid",index,state.line,index - state.line_offset)
  token.value = invalid_char
  token.error_messages = {"Invalid token '"..invalid_char.."'"}
  return index+1,token
end

---@param state TokenizeState
---@param index number
---@return number
---@return Token
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
        token.token_type = "comment"
        token.index = index
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
    else
      local number_end, token = try_read_number(str, index, state)
      if number_end then
        return number_end, token
      end
      return index+1,new_token(".",index,state.line,index - state.line_offset)
    end
  elseif next_char == '"' then
    return read_string(str,index,next_char,state)
  elseif next_char == "'" then
    return read_string(str,index,next_char,state)
  else
    local number_end, token = try_read_number(str, index, state)
    if number_end then
      return number_end, token
    end

    -- try to match keywords/identifiers
    local match_start,match_end,ident = str:find("^([_%a][_%w]*)",index)
    if match_start == index then
      token = new_token(
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
---@field line integer
---@field line_offset integer @ the exact index of the last newline
---@field prev_line integer|nil
---@field prev_line_offset integer|nil

---@param str string
---@return fun(state: TokenizeState, index: integer|nil): integer|nil, Token next_token
---@return TokenizeState state
---@return number|nil index
local function tokenize(str)
  local index
  local state = {
    str = str,
    line = 1,
    line_offset = 0, -- pretend the previous character was a newline. not too far fetched
  }
  if str:find("^\xef\xbb\xbf") then -- ignore utf8 byte-order mark (BOM)
    state.line_offset = 3
    index = 4
  end
  ---cSpell:ignore skipcomment, lauxlib
  -- TODO: what is this about skipcomment in lauxlib.c
  return next_token,state,index
end

return tokenize