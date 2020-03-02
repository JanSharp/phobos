local invert = require("invert")
local keywords = invert{
  "and", "break", "do", "else", "elseif", "end", "false",
  "for", "function", "if", "in", "local", "nil", "not",
  "or", "repeat", "return", "then", "true", "until",
  "while", "goto"
}

---@class Token
---@field token string
---@field index number
---@field line number
---@field column number
---@field value string|number
local function Token(token,index,line,column)
  return {
    token = token,
    index = index,
    line = line,
    column = column
  }
end

---@param str string
---@param index number
---@param nextchar string
---@return number
---@return Token
local function PeekEquals(str,index,nextchar,line,column)
  if str:sub(index+1,index+1) == "=" then
    return index+2,Token(nextchar.."=",index,line,column)
  else
    return index+1,Token(nextchar,index,line,column)
  end
end

local function ReadString(str,index,quote,linestate)
  local i = index + 1
  local nextchar = str:sub(i,i)
  if nextchar == quote then
    -- empty string
    local token = Token("string",index,linestate.line,index - linestate.lineoffset)
    token.value = ""
    return i+1,token
  end

  ::matching::
  -- read through normal text...
  while str:match("^[^"..quote.."\\\n]",i) do
    i = i + 1
  end

  nextchar = str:sub(i,i)

  if nextchar == quote then
    -- finished string
    local token = Token("string",index,linestate.line,index - linestate.lineoffset)
    token.value = str:sub(index+1,i-1)
      :gsub("\\([abfnrtv\\\"'\r\n])",
      {
        a = "\a", b = "\b", f = "\f", n = "\n",
        r = "\r", t = "\t", v = "\v", ["\\"] = "\\",
        ['"'] = '"', ["'"] = "'", ["\r"] = "\r", ["\n"] = "\n"
      })
      :gsub("\\z%s*","")
      :gsub("\\(%d%d?%d?)",function(digits)
        return string.char(tonumber(digits,10))
      end)
      :gsub("\\x(%x%x)",function(digits)
        return string.char(tonumber(digits,16))
      end)

    return i+1,token
  elseif nextchar == "" then
    error("Unterminated string at EOF")
  elseif nextchar == "\n" then
    error("Unterminated string at end of line " .. linestate.line)
  elseif nextchar == "\\" then
    -- advance past an escape sequence...
    i = i + 1
    nextchar = str:sub(i,i)
    if nextchar == "x" then
      i = i + 3 -- skip x and two hex digits
      goto matching
    elseif nextchar == "\n" then
      linestate.line = linestate.line + 1
      linestate.lineoffset = i
      i = i + 1
      goto matching
    elseif nextchar == "z" then
      --skip z and whitespace
      local _,skip = str:find("^z%s",i)
      i = skip + 1
      goto matching
    elseif nextchar:match("[abfnrtv\\\"']") then
      i = i + 1
      goto matching
    else
      local digits,skip = str:find("^%d%d?%d?",i)
      if digits then
        i = skip + 1
        goto matching
      else
        error("Unrecognized escape '\\".. nextchar .. "'")
      end
    end
  end
end

local function ReadBlockString(str,index,linestate)
  local openstart,openend,pad = str:find("^%[(=*)%[",index)
  if not pad then
    error("Invalid string open bracket")
  end

  if str:sub(openend+1,openend+1) == "\n" then
    linestate.line = linestate.line + 1
    openend = openend + 1
    linestate.lineoffset = openend
  end

  local tokenline = linestate.line
  local tokencol = (openend+1) - linestate.lineoffset

  local bracket,bracketend = str:find("%]"..pad.."%]",index)
  if not bracket then
    error("Unterminated block string at EOF")
  end

  local token = Token("string",index,tokenline,tokencol)
  token.value = str:sub(openend+1,bracket-1)
  for _ in token.value:gmatch("\n") do
    linestate.line = linestate.line + 1
  end
  --TODO: lineoffset is broken now. next newline will fix it, but should recalculate now if possible
  return bracketend+1,token
end

---@param str string
local function Tokenize(str)
  local linestate = {
    line = 1,
    lineoffset = 1
  }
  ---@param str string
  ---@param index number
  ---@return number
  ---@return Token
  local function ReadToken(str,index)
    if not index then index = 1 end
    local nextchar = str:sub(index,index)
    while nextchar:match("%s") do
      if nextchar == "\n" then
        -- increment line number, stash position of line start
        linestate.line = linestate.line + 1
        linestate.lineoffset = index
      end
      index = index + 1
      nextchar = str:sub(index,index)
    end

    if nextchar == "" then
      return -- EOF
    elseif nextchar:match("[+*/%%^#;,(){}%]]") then
      return index+1,Token(nextchar,index,linestate.line,index - linestate.lineoffset)
    elseif nextchar:match("[>=<]") then
      return PeekEquals(str,index,nextchar,linestate.line,index - linestate.lineoffset)
    elseif nextchar == "[" then
      local peek = str:sub(index+1,index+1)
      if peek == "=" or peek == "[" then
        return ReadBlockString(str,index,linestate)
      else
        return index+1,Token("[",index,linestate.line,index - linestate.lineoffset)
      end
    elseif nextchar == "-" then
      if str:sub(index+1,index+1) == "-" then
        if str:sub(index+2,index+2) == "[" then
          --[[
            read block string, build a token from that
            ]]
          local nextindex,token = ReadBlockString(str,index+2,linestate)
          token.token = "comment"
          token.index = index
          return nextindex,token
        else
          local tokenstart,tokenend,text = str:find("^([^\n]+)",index+2)
          local token = Token("comment",tokenstart,linestate.line,index - linestate.lineoffset)
          token.value = text
          return tokenend+1,token
        end
      else
        return index+1,Token("-",index,linestate.line,index - linestate.lineoffset)
      end
    elseif nextchar == "~" then
      if str:sub(index+1,index+1) == "=" then
        return index+2,Token("~=",index,linestate.line,index - linestate.lineoffset)
      else
        error("Invalid token '~' at " .. linestate.line .. ":" .. index - linestate.lineoffset)
      end
    elseif nextchar == ":" then
      if str:sub(index+1,index+1) == ":" then
        return index+2,Token("::",index,linestate.line,index - linestate.lineoffset)
      else
        return index+1,Token(":",index,linestate.line,index - linestate.lineoffset)
      end
    elseif nextchar == "." then
      if str:sub(index+1,index+1) == "." then
        if str:sub(index+2,index+2) == "." then
          return index+3,Token("...",index,linestate.line,index - linestate.lineoffset)
        else
          return index+2,Token("..",index,linestate.line,index - linestate.lineoffset)
        end
      else
        return index+1,Token(".",index,linestate.line,index - linestate.lineoffset)
      end
    elseif nextchar == '"' then
      return ReadString(str,index,nextchar,linestate)
    elseif nextchar == "'" then
      return ReadString(str,index,nextchar,linestate)
    else
      -- hex numbers: "0x%x+" followed by "%.%x+" followed by "[pP][+-]?%x+"
      local hexstart,hexend = str:find("^0x%x+",index)
      if hexstart then
        local fstart,fend = str:find("^%.%x+",hexend+1)
        if fstart then
          hexend = fend
        end
        local estart,eend = str:find("^[pP]%x+",hexend+1)
        if estart then
          hexend = eend
        end
        local token = Token("number",index,linestate.line,index - linestate.lineoffset)
        token.value = tonumber(str:sub(hexstart,hexend))
        return hexend+1,token
      end

      -- decimal numbers: "%d+" followed by "%.%d+" followed by "[eE][+-]?%d+"
      local numstart,numend = str:find("^%d+",index)
      if numstart then
        local fstart,fend = str:find("^%.%d+",numend+1)
        if fstart then
          numend = fend
        end
        local estart,eend = str:find("^[eE]%d+",numend+1)
        if estart then
          numend = eend
        end
        local token = Token("number",index,linestate.line,index - linestate.lineoffset)
        token.value = tonumber(str:sub(numstart,numend))
        return numend+1,token
      end

      -- try to match keywords/identifiers
      local matchstart,matchend,ident = str:find("^([_%a][_%w]*)",index)
      if matchstart == index then
        local token = Token(
          keywords[ident] and ident or "ident",
          index,linestate.line,index - linestate.lineoffset)
        if not keywords[ident] then
          token.value = ident
        elseif ident == "true" then
          token.value = true
        elseif ident == "false" then
          token.value = false
        end
        return matchend+1,token
      else
        error("Invalid token at " .. linestate.line .. ":" .. index - linestate.lineoffset)
      end
    end
  end
  return ReadToken,str
end

return Tokenize