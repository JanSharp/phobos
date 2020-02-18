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

local function checkref(parent)
  local tok = checkname()
  local isupval = false
  while parent do
    for i,loc in pairs(parent.locals) do
      if tok.value == loc.name.value then
        tok.token = isupval and "upval" or "local"
        tok.ref = loc
        return tok
      end
    end
    if parent.parent then
      if parent.parent.type == "upval" then
        isupval = true
      end
      parent = parent.parent.parent
    else
      parent = nil
    end
  end

  tok.token = "global"
  return tok
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

local function statlist(parent)
  -- statlist -> { stat [`;'] }
  local sl = {}
  while not block_follow(true) do
    if token.token == "eof" then
      return sl
    elseif token.token == "return" then
      sl[#sl+1] = statement(parent)
      return sl
    end
    sl[#sl+1] = statement(parent)
  end
  return sl
end

local function yindex(parent)
  -- index -> '[' expr ']'
  nexttoken()
  local e = expr(parent)
  checknext("]")
  return e
end

local function recfield(parent)
  local k
  if token.token == "ident" then
    k = token.value
    nexttoken()
  else
    k = yindex(parent)
  end
  checknext("=")
  return {type="rec",key=k,value=expr(parent)}
end

local function listfield(parent)
  return {type="list",value=expr(parent)}
end

local function field(parent)
  -- field -> listfield | recfield
  return (({
    ["ident"] = function(parent)
      local peektok = peektoken()
      if peektok.token ~= "=" then
        return listfield(parent)
      else
        return recfield(parent)
      end
    end,
    ["["] = recfield,
  })[token.token] or listfield)(parent)
end

local function constructor(parent)
  --  constructor -> '{' [ field { sep field } [sep] ] '}'
  --    sep -> ',' | ';' */
  local line = token.line
  checknext("{")
  local fields = {}
  repeat
    if token.token == "}" then break end
    fields[#fields+1] = field(parent)
  until not (testnext(",") or testnext(";"))
  checkmatch("}","{",line)
  return {token="constructor",fields = fields}
end

local function parlist(parent)
  -- parlist -> [ param { `,' param } ]
  if token.token == ")" then
    return 0
  end
  repeat
    if token.token == "ident" then
      token.token = "local"
      parent.locals[#parent.locals+1] = {name = token, wholeblock = true}
      nexttoken()
    elseif token.token == "..." then
      parent.isvararg = true
      nexttoken()
      return #parent.locals
    else
      syntaxerror("<name> or '...' expected")
    end
  until not testnext(",")
  return #parent.locals
end

local function body(line,parent)
  -- body -> `(' parlist `)' block END
  local thistok = {
    token="functiondef",
    body = true, -- list body first
    locals = {}, labels = {},
    parent = {type = "upval", parent = parent},
  }
  checknext("(")
  thistok.nparams = parlist(thistok)
  checknext(")")
  thistok.body = statlist(thistok)
  checkmatch("end","function",line)
  return thistok
end

local function explist(parent)
  local el = {(expr(parent))}
  while testnext(",") do
    el[#el+1] = expr(parent)
  end
  return el
end

local function funcargs(line,parent)
  return (({
    ["("] = function(parent)
      nexttoken()
      if token.token == ")" then
        nexttoken()
        return {}
      end
      local el = explist(parent)
      checkmatch(")","(",line)
      return el
    end,
    ["string"] = function(parent)
      local el = {token}
      nexttoken()
      return el
    end,
    ["{"] = function(parent)
      return {(constructor(parent))}
    end,
  })[token.token] or function()
    syntaxerror("Function arguments expected")
  end)(parent)
end

local function primaryexp(parent)
  if token.token == "(" then
    local line = token.line
    nexttoken() -- skip '('
    --TODO: compact lambda here:
    -- next token is ')', empty args expect `'=>' expr` next
    -- next token is 'ident'
    --  followed by `,` is multiple args, finish list then `=> expr`
    --  followed by `) =>` is single arg, expect `expr`
    --  followed by `)` is expr of inner name token
    -- then in suffixedexp, lambda should only take funcargs suffix
    local ex = expr(parent)
    checkmatch(")","(",line)
    return ex
  elseif token.token == "ident" then
    return checkref(parent)
  else
    syntaxerror("Unexpected symbol '" .. token.token .. "'")
  end
end

local suffixedtab = {
  ["."] = function(ex)
    local op = token
    nexttoken() -- skip '.'
    local name = checkname()
    name.token = "string"
    return {token="index", line = op.line, column = op.column,
            ex = ex, suffix = name}
  end,
  ["["] = function(ex,parent)
    return {token="index",
            line = token.line, column = token.column,
            ex = ex, suffix = yindex(parent)}
  end,
  [":"] = function(ex,parent)
    local op = token
    nexttoken() -- skip ':'
    return {token="selfcall", ex = ex,
      line = op.line, column = op.column,
      suffix = checkname(),
      args = funcargs(op.line,parent),
    }
  end,
  ["("] = function(ex,parent)
    return {token="call", ex = ex,
      line = token.line, column = token.column,
      args = funcargs(token.line,parent),
    }
  end,
  ["string"] = function(ex,parent)
    return {token="call", ex = ex,
      line = token.line, column = token.column,
      args = funcargs(token.line,parent),
    }
  end,
  ["{"] = function(ex,parent)
    return {token="call", ex = ex,
      line = token.line, column = token.column,
      args = funcargs(token.line,parent),
    }
  end,
}
local function suffixedexp(parent)
  -- suffixedexp ->
  --   primaryexp { '.' NAME | '[' exp ']' | ':' NAME funcargs | funcargs }
  --TODO: safe chaining adds optional '?' in front of each suffix
  local ex = primaryexp(parent)
  local shouldbreak = false
  repeat
    ex = ((suffixedtab)[token.token] or function(ex)
      shouldbreak = true
      return ex
    end)(ex,parent)
  until shouldbreak
  return ex
end

local simpletoks = invert{"number","string","nil","true","false","..."}
local function simpleexp(parent)
  -- simpleexp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
  --              constructor | FUNCTION body | suffixedexp
  if simpletoks[token.token] then
    local t = token
    nexttoken() --consume it
    return t
  end

  if token.token == "{" then
    return constructor(parent)
  elseif token.token == "function" then
    nexttoken() -- skip FUNCTION
    return body(token.line,parent)
  else
    return suffixedexp(parent)
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
local function subexpr(limit,parent)
  local ex
  do
    local unop = token.token
    local uprio = unopprio[unop]
    if uprio then
      nexttoken() -- consume unop
      local sub = subexpr(uprio,parent)
      ex = {token="unop", op = unop, ex = sub}
    else
      ex = simpleexp(parent)
    end
  end
  local binop = token.token
  local bprio = binopprio[binop]
  while bprio and bprio.left > limit do
    nexttoken()
    local newright,nextop = subexpr(bprio.right,parent)
    if binop == ".." then
      if newright.token == "concat" then
        table.insert(newright.explist,1,ex)
        ex = newright
      else
        ex = {token="concat", explist = {ex,newright}}
      end
    else
      ex = {token="binop", op = binop, left = ex, right = newright}
    end
    binop = nextop
    bprio = binopprio[binop]
  end
  return ex,binop
end

function expr(parent)
  return subexpr(0,parent)
end

local function assignment(lhs,parent)
  if testnext(",") then
    lhs[#lhs+1] = suffixedexp(parent)
    return assignment(lhs,parent)
  else
    local thistok = {token = "assignment", lhs = lhs,}
    local assign = token
    checknext("=")
    thistok.line = assign.line
    thistok.column = assign.column
    thistok.rhs = explist(parent)
    return thistok
  end
end

local function labelstat(label,parent)
  checknext("::")
  label.token = "label"
  local prevlabel = parent.labels[label.value]
  if prevlabel then
    error("Duplicate label '" .. label.value .. "' at line "
      .. label.line .. ":" .. label.column ..
      " previously defined at line "
      .. prevlabel.line .. ":" .. prevlabel.column)
  else
    parent.labels[label.value] = label
  end
  return label
end

local function whilestat(line,parent)
  -- whilestat -> WHILE cond DO block END
  nexttoken() -- skip WHILE
  local thistok = {
    token = "whilestat",
    body = true, -- list body first
    locals = {}, labels = {},
    parent = {type = "local", parent = parent},
  }
  thistok.cond = expr(thistok)
  checknext("do")

  thistok.body = statlist(thistok)
  checkmatch("end","while",line)
  return thistok
end

local function repeatstat(line,parent)
  -- repeatstat -> REPEAT block UNTIL cond
  local thistok = {
    token = "repeatstat",
    body = true, -- list body first
    locals = {}, labels = {},
    parent = {type = "local", parent = parent},
  }
  nexttoken() -- skip REPEAT
  thistok.body = statlist(thistok)
  checkmatch("until","repeat",line)
  thistok.cond = expr(thistok)
  return thistok
end

local function fornum(firstname,parent)
  -- fornum -> NAME = exp1,exp1[,exp1] DO block
  checknext("=")
  local start = expr(parent)
  checknext(",")
  local stop = expr(parent)
  local step = {token="number", value=1}
  if testnext(",") then
    step = expr(parent)
  end
  checknext("do")
  local thistok = {
    token = "fornum",
    var = firstname,
    start = start, stop = stop, step = step,
    locals = {}, labels = {},
    parent = {type = "local", parent = parent},
  }
  thistok.body = statlist(thistok)
  return thistok
end

local function forlist(firstname,parent)
  -- forlist -> NAME {,NAME} IN explist DO block
  local thistok = {
    token = "forlist",
    body = true, -- list body first
    locals = {
      {name = firstname, wholeblock = true},
    }, labels = {},
    parent = {type = "local", parent = parent},
  }
  local nl = {firstname}
  while testnext(",") do
    local name = checkname()
    name.token = "local"
    thistok.locals[#thistok.locals+1] =
      {name = name, wholeblock = true}
    nl[#nl+1] = name
  end
  checknext("in")
  local el = explist(parent)
  checknext("do")
  thistok.namelist = nl
  thistok.explist = el
  thistok.body = statlist(thistok)
  return thistok
end

local function forstat(line,parent)
  -- forstat -> FOR (fornum | forlist) END
  nexttoken() -- skip FOR
  local firstname = checkname()
  firstname.token = "local"
  local t= token.token
  local fortok
  if t == "=" then
    fortok = fornum(firstname,parent)
  elseif t == "," or t == "in" then
    fortok = forlist(firstname,parent)
  else
    syntaxerror("'=', ',' or 'in' expected")
  end
  checkmatch("end","for",line)
  return fortok
end


local function test_then_block(parent)
  -- test_then_block -> [IF | ELSEIF] cond THEN block
  --TODO: [IF | ELSEIF] ( cond | namelist '=' explist  [';' cond] ) THEN block
  -- if first token is ident, and second is ',' or '=', use if-init, else original parse
  -- if no cond in if-init, first name/expr is used
  nexttoken() -- skip IF or ELSEIF
  local thistok = {token = "testblock",
    body = true, -- list body first
    locals = {}, labels = {},
    parent = {type = "local", parent = parent},
  }
  thistok.cond = expr(thistok)
  checknext("then")
  
  thistok.body = statlist(thistok)
  return thistok
end

local function ifstat(line,parent)
  -- ifstat -> IF cond THEN block {ELSEIF cond THEN block} [ELSE block] END
  local ifs = {}
  repeat
    ifs[#ifs+1] = test_then_block(parent)
  until token.token ~= "elseif"
  local elseblock
  if testnext("else") then
    elseblock = {token="elseblock",
      body = true, -- list body first
      locals = {}, labels = {},
      parent = {type = "local", parent = parent},
    }
    elseblock.body = statlist(elseblock)
  end
  checkmatch("end","if",line)
  return {token = "ifstat", ifs = ifs, elseblock = elseblock}
end

local function localfunc(parent)
  local name = checkname()
  name.token = "local"
  local thislocal = {name = name}
  parent.locals[#parent.locals+1] = thislocal
  local b = body(token.line,parent)
  b.token = "localfunc"
  b.name = name
  thislocal.startbefore = b
  return b
end

local function localstat(parent)
  -- stat -> LOCAL NAME {`,' NAME} [`=' explist]
  local lhs = {}
  local thistok = {token="localstat", lhs = lhs}
  repeat
    local name = checkname()
    name.token = "local"
    lhs[#lhs+1] = name
  until not testnext(",")
  local assign = token
  if testnext("=") then
    thistok.line = assign.line
    thistok.column = assign.column
    thistok.rhs = explist(parent)
    for _,name in pairs(thistok.lhs) do
      parent.locals[#parent.locals+1] = {name = name, startafter = thistok}
    end
    return thistok
  else
    for _,name in pairs(thistok.lhs) do
      parent.locals[#parent.locals+1] = {name = name, startafter = thistok}
    end
    return thistok
  end
end

local function funcname(parent)
  -- funcname -> NAME {fieldsel} [`:' NAME]

  local dotpath = { checkref(parent) }

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

local function funcstat(line,parent)
  -- funcstat -> FUNCTION funcname body
  nexttoken() -- skip FUNCTION
  local ismethod,names = funcname(parent)
  local b = body(line,parent)
  b.token = "funcstat"
  b.names = names
  b.ismethod = ismethod
  return b
end

local function exprstat(parent)
  -- stat -> func | assignment
  local firstexp = suffixedexp(parent)
  if token.token == "=" or token.token == "," then
    -- stat -> assignment
    return assignment({firstexp},parent)
  else
    -- stat -> func
    if firstexp.token == "call" or firstexp.token == "selfcall" then
      return firstexp
    else
      syntaxerror("Unexpected <exp>")
    end
  end
end

local function retstat(parent)
  -- stat -> RETURN [explist] [';']
  local el
  if block_follow(true) or token.token == ";" then
    -- return no values
  else
    el = explist(parent)
  end
  testnext(";")
  return {token="retstat", explist = el}
end

local statementtab = {
  [";"] = function(parent) -- stat -> ';' (empty statement)
    nexttoken() -- skip
    return {token = "comment", }
  end,
  ["if"] = function(parent) -- stat -> ifstat
    local line = token.line;
    return ifstat(line,parent)
  end,
  ["while"] = function(parent) -- stat -> whilestat
    local line = token.line;
    return whilestat(line,parent)
  end,
  ["do"] = function(parent) -- stat -> DO block END
    local line = token.line;
    nexttoken() -- skip "do"
    local dostat = {
      token = "dostat",
      locals = {}, labels = {},
      parent = {type = "local", parent = parent}
    }
    dostat.body = statlist(dostat)
    checkmatch("end","do",line)
    return dostat
  end,
  ["for"] = function(parent) -- stat -> forstat
    local line = token.line;
    return forstat(line,parent)
  end,
  ["repeat"] = function(parent) -- stat -> repeatstat
    local line = token.line;
    return repeatstat(line, parent)
  end,
  ["function"] = function(parent) -- stat -> funcstat
    local line = token.line;
    return funcstat(line, parent)
  end,
  ["local"] = function(parent) -- stat -> localstat
    nexttoken() -- skip "local"
    if testnext("function") then
      return localfunc(parent)
    else
      return localstat(parent)
    end
  end,
  ["::"] = function(parent) -- stat -> label
    nexttoken() -- skip "::"
    return labelstat(checkname(),parent)
  end,
  ["return"] = function(parent) -- stat -> retstat
    nexttoken() -- skip "return"
    return retstat(parent)
  end,
  
  ["break"] = function(parent) -- stat -> breakstat
    nexttoken() -- skip BREAK
    return {token = "breakstat"}
  end,
  ["goto"] = function(parent) -- stat -> 'goto' NAME
    nexttoken() -- skip GOTO
    return {token = "gotostat", target = checkname()}
  end,
}
function statement(parent)
  return (statementtab[token.token] or exprstat)(parent) --stat -> func | assignment
end


local function mainfunc(chunkname)
  local main = {
    chunkname = chunkname,
    body = true, -- list body first
    locals = {},
    labels = {},
  }
  main.body = statlist(main)
  return main
end
----------------------------------------------------------------------

local function walk_block(ast,open,close,each_before,each_after)
  if open then open(ast) end
  if ast.token == "ifstat" then
    for _,ifblock in ipairs(ast.ifs) do
      walk_block(ifblock,open,close,each_after)
    end
    if ast.elseblock then
      walk_block(ast.elseblock,open,close,each_after)
    end
  else
    if not ast.body then return end
    for _,stat in ipairs(ast.body) do
      if each_before then each_before(ast,stat) end
      walk_block(stat,open,close,each_after)
      if each_after then each_after(ast,stat) end
    end
  end
  if close then close(ast) end
end

local function resolve_ident(main)

  walk_block(main,
  function(token)
    -- open
  end,
  function(token)
    -- close
  end,
  function(token,stat)
    -- each_before
    if stat.token == "ifstat" then

    elseif stat.body then
      
    end
  end,
  function(token)
    -- each_after
  end)
end




----------------------------------------------------------------------
local filename = ... or "phobos.lua"
local file = io.open(filename,"r")

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

local main = mainfunc("@" .. filename)
resolve_ident(main)

print(serpent.dump(main,{indent = '  ', sparse = true, sortkeys = false, comment=true}))

--foo
