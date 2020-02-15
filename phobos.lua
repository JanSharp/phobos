local serpent = require("serpent")

local function invert(t)
  local tt = {}
  for _,s in pairs(t) do
    tt[s] = true
  end
  return tt
end

local keywords = invert{
  "and", "break", "do", "else", "elseif", "end", "false",
  "for", "function", "if", "in", "local", "nil", "not",
  "or", "repeat", "return", "then", "true", "until",
  "while",
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
function Tokenize(str)
  local linestate = {
    line = 1,
    lineoffset = 1
  }
  ---@param str string
  ---@param index number
  ---@return number
  ---@return Token
  function ReadToken(str,index)
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
    elseif nextchar:match("[+*/%^#;,(){}%]]") then
      return index+1,Token(nextchar,index,linestate.line,index - linestate.lineoffset)
    elseif nextchar:match("[=<>]") then
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

      -- try to match keywords/identifiers
      local matchstart,matchend,ident = str:find("^([_%a][_%w]*)",index)
      if matchstart == index then
        local token = Token(
          keywords[ident] and ident or "ident",
          index,linestate.line,index - linestate.lineoffset)
        if not keywords[ident] then
          token.value = ident
        end
        return matchend+1,token
      else
        error("Invalid token at " .. linestate.line .. ":" .. index - linestate.lineoffset)
      end
    end
  end
  return ReadToken,str
end
----------------------------------------------------------------------
local token,nexttoken,peektoken
----------------------------------------------------------------------
local statement, expr

local function syntaxerror(mesg)
  error(mesg .. " near '" .. token.token ..
        "' at line " .. (token.line or "(?)") .. ":" .. (token.column or "(?)"))
end

local function checkname()
  if token.token ~= "ident" then
    syntaxerror("<name> expected")
  end
  local name = token
  name.token = "name"
  nexttoken()
  return name
end

local function testnext(tok)
  if token.token == tok then
    nexttoken()
    return true
  end
  return false
end

local function checknext(tok)
  if token.token == tok then
    nexttoken()
    return
  end
  syntaxerror("'" .. tok .. "' expected")
end

local function checkmatch(close,open,line)
  if not testnext(close) then
    syntaxerror("'"..close.."' expected (to close '"..open.."' at line " .. line .. ")")
  end
end

local blockends = invert{"else", "elseif", "end", ""}
local function block_follow(withuntil)
  local tok = token.token
  if blockends[tok] then
    return true
  elseif tok == "until" then
    return withuntil
  else
    return false
  end
end

local function statlist()
  -- statlist -> { stat [`;'] }
  local sl = {}
  while not block_follow(true) do
    if token.token == "eof" then
      return sl
    elseif token.token == "return" then
      sl[#sl+1] = statement()
      return sl
    end
    sl[#sl+1] = statement()
  end
  return sl
end

local function yindex()
  -- index -> '[' expr ']'
  nexttoken()
  local e = expr()
  checknext("]")
  return e
end

local function recfield()
  local k
  if token.token == "ident" then
    k = token.value
    nexttoken()
  else
    k = yindex()
  end
  checknext("=")
  return {type="rec",key=k,value=expr()}
end

local function listfield()
  return {type="list",value=expr()}
end

local function field()
  -- field -> listfield | recfield
  return (({
    ["ident"] = function()
      local peektok = peektoken()
      if peektok.token ~= "=" then
        return listfield()
      else
        return recfield()
      end
    end,
    ["["] = recfield,
  })[token.token] or listfield)()
end

local function constructor()
  --  constructor -> '{' [ field { sep field } [sep] ] '}'
  --    sep -> ',' | ';' */
  local line = token.line
  checknext("{")
  local fields = {}
  repeat
    if token.token == "}" then break end
    fields[#fields+1] = field()
  until not (testnext(",") or testnext(";"))
  checkmatch("}","{",line)
  return {token="constructor",fields = fields}
end

local function parlist()
  -- parlist -> [ param { `,' param } ]
  local pl = {}
  if token.token == ")" then
    return pl
  end
  repeat
    if token.token == "ident" then
      pl[#pl+1] = token
      nexttoken()
    elseif token.token == "..." then
      pl.isvararg = true
      return pl
    else
      syntaxerror("<name> or '...' expected")
    end
  until not testnext(",")
end

local function body(line)
  -- body ->  `(' parlist `)' block END
  checknext("(")
  local pl = parlist()
  checknext(")")
  local b = statlist()
  checkmatch("end","function",line)
  return {token="functiondef", parlist = pl, body = b}
end

local function explist()
  local el = {(expr())}
  while testnext(",") do
    el[#el+1] = expr()
  end
  return el
end

local function funcargs(line)
  return (({
    ["("] = function()
      nexttoken()
      if token.token == ")" then
        nexttoken()
        return {}
      end
      local el = explist()
      checkmatch(")","(",line)
      return el
    end,
    ["string"] = function()
      local el = {token}
      nexttoken()
      return el
    end,
    ["{"] = function()
      return {(constructor())}
    end,
  })[token.token] or function()
    syntaxerror("Function arguments expected")
  end)()
end

local function primaryexp()
  if token.token == "(" then
    local line = token.line
    nexttoken() -- skip '('
    local ex = expr()
    checkmatch(")","(",line)
    return ex
  elseif token.token == "ident" then
    local t = token
    nexttoken()
    return t
  else
    syntaxerror("Unexpected symbol '" .. token.token .. "'")
  end
end

local suffixedtab = {
  ["."] = function(ex)
    nexttoken() -- skip '.'
    return {token="suffixed", type=".", ex = ex, suffix = checkname()}
  end,
  ["["] = function(ex)
    return {token="suffixed", type="[", ex = ex, suffix = yindex()}
  end,
  [":"] = function(ex)
    local line = token.line
    nexttoken() -- skip ':'
    return {token="suffixed", type=":", ex = ex,
      suffix = checkname(),
      args = funcargs(line),
    }
  end,
  ["("] = function(ex)
    local line = token.line
    return {token="suffixed", type="call", ex = ex,
      args = funcargs(line),
    }
  end,
  ["string"] = function(ex)
    local line = token.line
    return {token="suffixed", type="call", ex = ex,
      args = funcargs(line),
    }
  end,
  ["{"] = function(ex)
    local line = token.line
    return {token="suffixed", type="call", ex = ex,
      args = funcargs(line),
    }
  end,
}
local function suffixedexp()
  -- suffixedexp ->
  --   primaryexp { '.' NAME | '[' exp ']' | ':' NAME funcargs | funcargs }
  local ex = primaryexp()
  local shouldbreak = false
  repeat
    ex = ((suffixedtab)[token.token] or function(ex)
      shouldbreak = true
      return ex
    end)(ex)
  until shouldbreak
  return ex
end

local simpletoks = invert{"number","string","nil","true","false","..."}
local function simpleexp()
  -- simpleexp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
  --              constructor | FUNCTION body | suffixedexp
  if simpletoks[token.token] then
    local t = token
    nexttoken() --consume it
    return t
  end

  if token.token == "{" then
    return constructor()
  elseif token.token == "function" then
    nexttoken() -- skip FUNCTION
    return body(token.line)
  else
    return suffixedexp()
  end
end

local unopprio = {
  ["not"] = 8,
  ["-"] = 8,
  ["#"] = 8,
}
local binopprio = {
  ["+"]   = {left=6,right=6}, ["-"]  = {left=6,right=6},
  ["*"]   = {left=7,right=7}, ["/"]  = {left=7,right=7},
  ["%"]   = {left=7,right=7},
  ["^"]   = {left=10,right=9}, [".."] = {left=5,right=4}, -- right associative
  ["=="]  = {left=3,right=3},
  ["<"]   = {left=3,right=3}, ["<="] = {left=3,right=3},
  ["~="]  = {left=3,right=3},
  [">"]   = {left=3,right=3}, [">="] = {left=3,right=3},
  ["and"] = {left=2,right=2}, ["or"] = {left=1,right=1},
}

-- subexpr -> (simpleexp | unop subexpr) { binop subexpr }
-- where `binop' is any binary operator with a priority higher than `limit'
local function subexpr(limit)
  local ex
  do
    local unop = token.token
    local uprio = unopprio[unop]
    if uprio then
      nexttoken() -- consume unop
      local sub = subexpr(uprio)
      ex = {token="unop", op = unop, ex = sub}
    else
      ex = simpleexp()
    end
  end
  local binop = token.token
  local bprio = binopprio[binop]
  while bprio and bprio.left > limit do
    nexttoken()
    local newright
    newright,nextop = subexpr(bprio.right)
    ex = {token="binop", op = binop, left = ex, right = newright}
    binop = nextop
    bprio = binopprio[binop]
  end
  return ex,binop
end

function expr()
  return subexpr(0)
end

local function assignment(lhs)
  if testnext(",") then
    lhs[#lhs+1] = suffixedexp()
    return assignment(lhs)
  else
    checknext("=")
    local rhs = explist()
    return {token = "assignment", lhs = lhs, rhs = rhs}
  end
end

local function labelstat(label)
  checknext("::")
  return {token="labelstat", label=label}
end

local function whilestat(line)
  -- whilestat -> WHILE cond DO block END
  nexttoken() -- skip WHILE
  local cond = expr()
  checknext("do")
  local b = statlist()
  checkmatch("end","while",line)
  return {token = "whilestat", body = b, cond = cond}
end

local function repeatstat(line)
  -- repeatstat -> REPEAT block UNTIL cond
  nexttoken() -- skip REPEAT
  local b = statlist()
  checkmatch("until","repeat",line)
  local cond = expr()
  return {token = "repeatstat", body = b, cond = cond}
end


local function forbody()
  -- forbody -> DO block
  checknext("do")
  return statlist()
end

local function fornum(firstname)
  -- fornum -> NAME = exp1,exp1[,exp1] forbody
  checknext("=")
  local start = expr()
  checknext(",")
  local stop = expr()
  local step = 1 --TODO: build a const expr out of this
  if testnext(",") then
    step = expr()
  end
  return {
    token = "fornum",
    var = firstname,
    start = start, stop = stop, step = step,
    body = forbody()
  }
end

local function forlist(firstname)
  -- forlist -> NAME {,NAME} IN explist forbody
  local nl = {firstname}
  while testnext(",") do
    nl[#nl+1] = checkname()
  end
  checknext("in")
  local line = token.line
  local el = explist()
  return {
    token = "forlist",
    namelist = nl, explist = el,
    body = forbody()
  }
end

local function forstat(line)
  -- forstat -> FOR (fornum | forlist) END
  nexttoken() -- skip FOR
  local firstname = checkname()
  local t= token.token
  local fortok
  if t == "=" then
    fortok = fornum(firstname)
  elseif t == "," or t == "in" then
    fortok = forlist(firstname)
  else
    syntaxerror("'=', ',' or 'in' expected")
  end
  checkmatch("end","for",line)
  return fortok
end


local function test_then_block()
  -- test_then_block -> [IF | ELSEIF] cond THEN block
  nexttoken() -- skip IF or ELSEIF
  local cond = expr()
  checknext("then")
  return {cond = cond, body = statlist()}
end

local function ifstat(line)
  -- ifstat -> IF cond THEN block {ELSEIF cond THEN block} [ELSE block] END
  local ifs = {}
  repeat
    ifs[#ifs+1] = test_then_block()
  until token.token ~= "elseif"
  local elseblock
  if testnext("else") then
    elseblock = statlist()
  end
  checkmatch("end","if",line)
  return {token = "ifstat", ifs = ifs, elseblock = elseblock}
end

local function localfunc()
  local name = checkname()
  local b = body(token.line)
  b.token = "localfunc"
  b.name = name
  return b
end

local function localstat()
  -- stat -> LOCAL NAME {`,' NAME} [`=' explist]
  local nl = {}
  repeat
    nl[#nl+1] = checkname()
  until not testnext(",")
  if testnext("=") then
    return {token="localstat", namelist = nl, explist = explist()}
  else
    return {token="localstat", namelist = nl}
  end
end

local function funcname()
  -- funcname -> NAME {fieldsel} [`:' NAME]

  local dotpath = { checkname() }

  while token.token == "." do
    nexttoken() -- skip '.'
    dotpath[#dotpath+1] = checkname()
  end

  if token.token == ":" then
    nexttoken() -- skip ':'
    dotpath[#dotpath+1] = checkname()
    return true,dotpath
  end

  return false,dotpath
end

local function funcstat(line)
  -- funcstat -> FUNCTION funcname body
  nexttoken() -- skip FUNCTION
  local ismethod,names = funcname()
  local b = body(line)
  b.token = "funcstat"
  b.names = names
  b.ismethod = ismethod
  return b
end

local function exprstat()
  -- stat -> func | assignment
  local firstexp = suffixedexp()
  if token.token == "=" or token.token == "," then
    -- stat -> assignment
    return assignment({firstexp})
  else
    -- stat -> func
    --TODO: check that firstexp is a function call, else error
    return firstexp
  end
end

local function retstat()
  -- stat -> RETURN [explist] [';']
  local el
  if block_follow(true) or token.token == ";" then
    -- return no values
  else
    el = explist()
  end
  testnext(";")
  return {token="retstat", explist = el}
end

local statementtab = {
  [";"] = function() -- stat -> ';' (empty statement)
    nexttoken() -- skip
    return {token = "comment", }
  end,
  ["if"] = function() -- stat -> ifstat
    local line = token.line;
    return ifstat(line)
  end,
  ["while"] = function() -- stat -> whilestat
    local line = token.line;
    return whilestat(line)
  end,
  ["do"] = function() -- stat -> DO block END
    local line = token.line;
    nexttoken() -- skip "do"
    local b = statlist()
    checkmatch("end","do",line)
    return {token = "dostat", body = b}
  end,
  ["for"] = function() -- stat -> forstat
    local line = token.line;
    return forstat(line)
  end,
  ["repeat"] = function() -- stat -> repeatstat
    local line = token.line;
    return repeatstat(line)
  end,
  ["function"] = function() -- stat -> funcstat
    local line = token.line;
    return funcstat(line)
  end,
  ["local"] = function() -- stat -> localstat
    nexttoken() -- skip "local"
    if testnext("function") then
      return localfunc()
    else
      return localstat()
    end
  end,
  ["::"] = function() -- stat -> label
    nexttoken() -- skip "::"
    return labelstat(checkname())
  end,
  ["return"] = function() -- stat -> retstat
    nexttoken() -- skip "return"
    return retstat()
  end,
  
  ["break"] = function() -- stat -> breakstat
    nexttoken() -- skip BREAK
    return {token = "breakstat"}
  end,
  ["goto"] = function() -- stat -> 'goto' NAME
    nexttoken() -- skip GOTO
    return {token = "gotostat", target = checkname()}
  end,
}
function statement()
  return ((statementtab)[token.token] or exprstat)() --stat -> func | assignment
end


local function mainfunc(chunkname)
  return {
    chunkname = chunkname,
    body = statlist(),
  }
end





----------------------------------------------------------------------
local file = io.open("phobos.lua","r")

local tokeniter,str,index = Tokenize(file:read("*a"))

file:close()
function nexttoken()
  repeat
    index,token = tokeniter(str,index)
  until not token or token.token ~= "comment"
  if not token then
    token = {token="eof"}
  end
  return token
end

function peektoken()
  local _,peektok
  repeat
    _,peektok = tokeniter(str,index)
  until peektok.token ~= "comment"
  return peektok
end

nexttoken()

local main = mainfunc("@phobos.lua")

print(serpent.block(main,{sparse = true, sortkeys = false}))

--foo
