
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
---@field value string|number @ for `blank`, `comment`, `string`, `number` and `ident` tokens
---@field src_is_block_str boolean @ for `string` and `comment` tokens
---@field src_quote string @ for non block `string` and `comment` tokens
---@field src_value string @ for non block `string`, `comment` and `number` tokens
---@field src_has_leading_newline boolean @ for block `string` and `comment` tokens
---@field src_pad string @ the `=` chain for block `string` and `comment` tokens

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

local escape_sequence_lut = {
  a = "\a", b = "\b", f = "\f", n = "\n",
  r = "\r", t = "\t", v = "\v", ["\\"] = "\\",
  ['"'] = '"', ["'"] = "'", ["\r"] = "\r", ["\n"] = "\n",
}

local function read_string(str,index,quote,state)
  local i = index + 1
  local next_char = str:sub(i,i)
  if next_char == quote then
    -- empty string
    local token = new_token("string",index,state.line,index - state.line_offset)
    token.value = ""
    return i+1,token
  end

  local parts = {}

  ::matching::
  local start_i = i
  -- read through normal text...
  while str:match("^[^"..quote.."\\\n]",i) do
    i = i + 1
  end

  if i ~= start_i then
    parts[#parts+1] = str:sub(start_i, i - 1)
  end

  next_char = str:sub(i,i)

  if next_char == quote then
    -- finished string
    local token = new_token("string",index,state.line,index - state.line_offset)
    token.src_value = str:sub(index+1,i-1)
    token.value = table.concat(parts)

    token.src_is_block_str = false
    token.src_quote = quote

    return i+1,token
  elseif next_char == "" then
    error("Unterminated string at EOF")
  elseif next_char == "\n" then
    error("Unterminated string at end of line " .. state.line)
  elseif next_char == "\\" then
    -- advance past an escape sequence...
    i = i + 1
    next_char = str:sub(i,i)
    if next_char == "x" then
      local digits = str:match("^%x%x", i + 1)
      if not digits then
        error("Invalid escape sequence `\\x"..str:sub(i + 1, i + 2)
          .."`, `\\x` must be followed by 2 hexadecimal digits."
        )
      end
      parts[#parts+1] = string.char(tonumber(digits, 16))
      i = i + 3 -- skip x and two hex digits
      goto matching
    elseif next_char == "\n" then
      state.line = state.line + 1
      state.line_offset = i
      parts[#parts+1] = "\n"
      i = i + 1
      goto matching
    elseif next_char == "z" then
      --skip z and whitespace
      local _,skip = str:find("^z%s*",i)
      local j = i + 1
      i = skip + 1
      -- figure out the right line and line_offset
      while true do
        local _, newline_index = str:find("^%s-\n", j)
        if not newline_index then
          break
        end
        j = newline_index + 1
        state.line = state.line + 1
        state.line_offset = newline_index
      end
      goto matching
    elseif escape_sequence_lut[next_char] then
      parts[#parts+1] = escape_sequence_lut[next_char]
      i = i + 1
      goto matching
    else
      local digits_start, skip, digits = str:find("^(%d%d?%d?)",i)
      if digits_start then
        parts[#parts+1] = string.char(tonumber(digits, 10))
        i = skip + 1
        goto matching
      else
        error("Unrecognized escape '\\".. next_char .. "'")
      end
    end
  end
end

local function read_block_string(str,index,state)
  local _,open_end,pad = str:find("^%[(=*)%[",index)
  if not pad then
    error("Invalid string open bracket")
  end

  local has_leading_newline = false
  if str:sub(open_end+1,open_end+1) == "\n" then
    has_leading_newline = true
    state.line = state.line + 1
    open_end = open_end + 1
    state.line_offset = open_end
  end

  local token_line = state.line
  local token_col = (open_end+1) - state.line_offset

  local bracket,bracket_end = str:find("%]"..pad.."%]",index)
  if not bracket then
    error("Unterminated block string at EOF")
  end

  local token = new_token("string",index,token_line,token_col)
  token.value = str:sub(open_end+1,bracket-1)
  local has_newline
  for _ in token.value:gmatch("\n") do
    has_newline = true
    state.line = state.line + 1
  end
  if has_newline then
    local last_line_start, last_line_finish = token.value:find("\n[^\n]*$")
    state.line_offset = bracket - (last_line_finish - last_line_start) - 1
  end

  token.src_is_block_str = true
  token.src_has_leading_newline = has_leading_newline
  token.src_pad = pad

  return bracket_end+1,token
end

---@param state TokenizeState
---@param index number
---@return number
---@return Token
local function next_token(state,index)
  if not index then index = 1 end
  local str = state.str
  local next_char = str:sub(index,index)
  do
    local start_index, start_line, start_line_offset = index, state.line, state.line_offset
    while next_char:match("%s") do
      if next_char == "\n" then
        -- increment line number, stash position of line start
        state.line = state.line + 1
        state.line_offset = index
      end
      index = index + 1
      next_char = str:sub(index,index)
    end
    if index ~= start_index then
      local token = new_token("blank", start_index, start_line, start_index - start_line_offset)
      token.value = str:sub(start_index, index - 1)
      return index, token
    end
  end

  if next_char == "" then
    return -- EOF
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
      if str:sub(index+2,index+2) == "[" then
        --[[
          read block string, build a token from that
          ]]
        local next_index,token = read_block_string(str,index+2,state)
        token.token_type = "comment"
        token.index = index
        return next_index,token
      else
        local token_start,token_end,text = str:find("^([^\n]+)",index+2)
        local token = new_token("comment",token_start,state.line,index - state.line_offset)
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
      error("Invalid token '~' at " .. state.line .. ":" .. index - state.line_offset)
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
      return index+1,new_token(".",index,state.line,index - state.line_offset)
    end
  elseif next_char == '"' then
    return read_string(str,index,next_char,state)
  elseif next_char == "'" then
    return read_string(str,index,next_char,state)
  else
    -- hex numbers: "0x%x+" followed by "%.%x+" followed by "[pP][+-]?%x+"
    local hex_start,hex_end = str:find("^0x%x+",index) -- "integer part"
    if hex_start then
      local fractional_start,fractional_end = str:find("^%.%x+",hex_end+1)
      if fractional_start then
        hex_end = fractional_end
      end
      local exponent_start,exponent_end = str:find("^[pP]%x+",hex_end+1)
      if exponent_start then
        hex_end = exponent_end
      end
      local token = new_token("number",index,state.line,index - state.line_offset)
      token.src_value = str:sub(hex_start,hex_end)
      token.value = tonumber(token.src_value)
      return hex_end+1,token
    end

    -- decimal numbers: "%d+" followed by "%.%d+" followed by "[eE][+-]?%d+"
    local num_start,num_end = str:find("^%d+",index) -- "integer part"
    if num_start then
      local fractional_start,fractional_end = str:find("^%.%d+",num_end+1)
      if fractional_start then
        num_end = fractional_end
      end
      local exponent_start,exponent_end = str:find("^[eE]%d+",num_end+1)
      if exponent_start then
        num_end = exponent_end
      end
      local token = new_token("number",index,state.line,index - state.line_offset)
      token.src_value = str:sub(num_start,num_end)
      token.value = tonumber(token.src_value)
      return num_end+1,token
    end

    -- try to match keywords/identifiers
    local match_start,match_end,ident = str:find("^([_%a][_%w]*)",index)
    if match_start == index then
      local token = new_token(
        keywords[ident] and ident or "ident",
        index,state.line,index - state.line_offset)
      if not keywords[ident] then
        token.value = ident
      elseif ident == "true" then
        token.value = true
      elseif ident == "false" then
        token.value = false
      end
      return match_end+1,token
    else
      error("Invalid token at " .. state.line .. ":" .. index - state.line_offset)
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
---@return nil index
local function tokenize(str)
  local state = {
    str = str,
    line = 1,
    line_offset = 0, -- pretend the previous character was a newline. not too far fetched
  }
  return next_token,state
end

return tokenize