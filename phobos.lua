local serpent = require("serpent")

local function invert(t)
  local tt = {}
  for _,s in pairs(t) do
    tt[s] = true
  end
  return tt
end
local Tokenize
do
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
  function Tokenize(str)
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
end
----------------------------------------------------------------------
local token,nexttoken,peektoken
----------------------------------------------------------------------
local mainfunc
do
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

  local function checkref(parent,tok)
    if not tok then tok = checkname() end
    local origparent = parent
    local isupval = 0 -- 0 = local, 1 = upval from immediate parent, 2+ = chained upval
    local upvalparent = {}
    while parent do
      local found
      for _,loc in pairs(parent.locals) do
        if tok.value == loc.name.value then
          -- keep looking to find the most recently defined one,
          -- in case some nut redefines the same name repeatedly in the same scope
          found = loc
        end
      end
      if found then
        if isupval>0 then 
          tok.upvalparent = upvalparent
          tok.token = "upval"
        else
          tok.token = "local"
        end
        tok.ref = found
        return tok
      end
      if parent.parent then
        if parent.parent.type == "upval" then
          isupval = isupval + 1
          upvalparent[isupval] = parent
        end
        parent = parent.parent.parent
      else
        parent = nil
      end
    end

    tok.token = "string"
    tok = {token="index",
    line = tok.line, column = tok.column,
    ex = checkref(origparent,{value = "_ENV"}), suffix = tok}
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

  local function body(line,parent,ismethod)
    -- body -> `(` parlist `)`  block END
    local thistok = {
      token="functiondef",
      body = false, -- list body before locals
      ismethod = ismethod,
      funcprotos = {},
      locals = {}, labels = {},
      line = token.line, column = token.column,
      parent = {type = "upval", parent = parent},
    }
    if ismethod then
      thistok.locals[1] = {name = {token="self",value="self"}, wholeblock = true}
    end
    checknext("(")
    thistok.nparams = parlist(thistok)
    checknext(")")
    thistok.body = statlist(thistok)
    thistok.endline = token.line
    thistok.endcolumn = token.column + 3
    checkmatch("end","function",line)
    while not parent.funcprotos do
      parent = parent.parent.parent
    end
    parent.funcprotos[#parent.funcprotos+1] = thistok
    return {token="funcproto",ref=thistok}
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
      --  followed by `)` `=>` is single arg, expect `expr`
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
    ["^"]   = {left=10,right=9}, -- right associative
    ["*"]   = {left=7 ,right=7}, ["/"]  = {left=7,right=7},
    ["%"]   = {left=7 ,right=7},
    ["+"]   = {left=6 ,right=6}, ["-"]  = {left=6,right=6},
    [".."]  = {left=5 ,right=4}, -- right associative
    ["=="]  = {left=3 ,right=3},
    ["<"]   = {left=3 ,right=3}, ["<="] = {left=3,right=3},
    ["~="]  = {left=3 ,right=3},
    [">"]   = {left=3 ,right=3}, [">="] = {left=3,right=3},
    ["and"] = {left=2 ,right=2},
    ["or"]  = {left=1 ,right=1},
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
      body = false, -- list body before locals
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
      body = false, -- list body before locals
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
      body = false, -- list body before locals
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
      body = false, -- list body before locals
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
        body = false, -- list body before locals
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
    local b = body(line,parent,ismethod)
    b.token = "funcstat"
    b.names = names
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


  function mainfunc(chunkname)
    local main = {
      token = "main",
      chunkname = chunkname,
      -- fake parent of main to provide _ENV upval
      parent = {
        type = "upval", parent = {
          token = "env",
          locals = {
            {name = {token="_ENV",value="_ENV"}, wholeblock = true}
          }
        }
      },
      funcprotos = {},
      body = false, -- list body before locals
      isvararg = true, -- main is always vararg
      locals = {},
      labels = {},
    }
    main.body = statlist(main)
    return main
  end
end
----------------------------------------------------------------------
local fold_const
do
  local function walk_block(ast,open,close)
    if open then open(ast) end
    if ast.token == "ifstat" then
      for _,ifblock in ipairs(ast.ifs) do
        walk_block(ifblock,open,close)
      end
      if ast.elseblock then
        walk_block(ast.elseblock,open,close)
      end
    else
      if ast.funcprotos then
        for _,func in ipairs(ast.funcprotos) do
          walk_block(func,open,close)
        end
      end
      if ast.body then
        for _,stat in ipairs(ast.body) do
          walk_block(stat,open,close)
        end
      end
    end
    if close then close(ast) end
  end

  local function walk_exp(exp,open,close)
    if open then open(exp) end
    if exp.token == "unop" then
      walk_exp(exp.ex,open,close)
    elseif exp.token == "binop" then
      walk_exp(exp.left,open,close)
      walk_exp(exp.right,open,close)
    elseif exp.token == "concat" then
      for _,sub in ipairs(exp.explist) do
        walk_exp(sub,open,close)
      end
    elseif exp.token == "index" then
      walk_exp(exp.ex,open,close)
      walk_exp(exp.suffix,open,close)
    elseif exp.token == "call" then
      walk_exp(exp.ex,open,close)
      for _,sub in ipairs(exp.args) do
        walk_exp(sub,open,close)
      end
    elseif exp.token == "selfcall" then
      walk_exp(exp.ex,open,close)
      walk_exp(exp.suffix,open,close)
      for _,sub in ipairs(exp.args) do
        walk_exp(sub,open,close)
      end
    elseif exp.token == "funcproto" then
      -- no children, only ref
    else
      -- local, upval: no children, only ref
      -- number, boolean, string: no children, only value
    end
    if close then close(exp) end
  end

  local function foldexp(parentexp,tok,value,childtok)
    parentexp.token = tok
    parentexp.value = value
    parentexp.ex = nil        -- call, selfcall
    parentexp.op = nil        -- binop,unop
    parentexp.left = nil      -- binop
    parentexp.right = nil     -- binop
    parentexp.explist = nil   -- concat
    if childtok then
      parentexp.line = childtok.line
      parentexp.column = childtok.column
    elseif childtok == false then
      parentexp.line = nil
      parentexp.column = nil
    end
    parentexp.folded = true
  end

  local isconsttoken = invert{"string","number","true","false","nil"}
  local foldunop = {
    ["-"] = function(exp)
      -- number
      if exp.ex.token == "number" then
        foldexp(exp,"number", -exp.ex.value)
      end
    end,
    ["not"] = function(exp)
      -- boolean
      if exp.ex.token == "boolean" then
        foldexp(exp, "boolean", not exp.ex.value)
      end
    end,
    ["#"] = function(exp)
      -- table or string
      if exp.ex.token == "string" then
        foldexp(exp, "string", #exp.ex.value)
      end
    end,
  }
  local foldbinop = {
    ["+"] = function(exp)
      if exp.left.token == "number" and exp.right.token == "number" then
        foldexp(exp, "number", exp.left.value + exp.right.value)
      end
    end,
    ["-"] = function(exp)
      if exp.left.token == "number" and exp.right.token == "number" then
        foldexp(exp, "number", exp.left.value - exp.right.value)
      end
    end,
    ["*"] = function(exp)
      if exp.left.token == "number" and exp.right.token == "number" then
        foldexp(exp, "number", exp.left.value * exp.right.value)
      end
    end,
    ["/"] = function(exp)
      if exp.left.token == "number" and exp.right.token == "number" then
        foldexp(exp, "number", exp.left.value / exp.right.value)
      end
    end,
    ["%"] = function(exp)
      if exp.left.token == "number" and exp.right.token == "number" then
        foldexp(exp, "number", exp.left.value % exp.right.value)
      end
    end,
    ["^"] = function(exp)
      if exp.left.token == "number" and exp.right.token == "number" then
        foldexp(exp, "number", exp.left.value ^ exp.right.value)
      end
    end,
    ["<"] = function(exp)
      -- matching types, number or string
      if exp.left.token == exp.right.token and
        (exp.left.token == "number" or exp.left.token == "string") then
        local res =  exp.left.value < exp.right.value
        foldexp(exp, tostring(res), res)
      end
    end,
    ["<="] = function(exp)
      -- matching types, number or string
      if exp.left.token == exp.right.token and
        (exp.left.token == "number" or exp.left.token == "string") then
          local res =  exp.left.value <= exp.right.value
          foldexp(exp, tostring(res), res)
      end
    end,
    [">"] = function(exp)
      -- matching types, number or string
      if exp.left.token == exp.right.token and
        (exp.left.token == "number" or exp.left.token == "string") then
          local res =  exp.left.value > exp.right.value
          foldexp(exp, tostring(res), res)
      end
    end,
    [">="] = function(exp)
      -- matching types, number or string
      if exp.left.token == exp.right.token and
        (exp.left.token == "number" or exp.left.token == "string") then
          local res =  exp.left.value >= exp.right.value
          foldexp(exp, tostring(res), res)
      end
    end,
    ["=="] = function(exp)
      -- any type
      if exp.left.token == exp.right.token and isconsttoken[exp.left.token] then
        local res =  exp.left.value == exp.right.value
        foldexp(exp, tostring(res), res)
      elseif isconsttoken[exp.left.token] and isconsttoken[exp.right.token] then
        -- different types of constants
        foldexp(exp, "false", false)
      end
    end,
    ["~="] = function(exp)
      -- any type
      if exp.left.token == exp.right.token and isconsttoken[exp.left.token] then
        local res =  exp.left.value ~= exp.right.value
        foldexp(exp, tostring(res), res)
      elseif isconsttoken[exp.left.token] and isconsttoken[exp.right.token] then
        -- different types of constants
        foldexp(exp, "true", true)
      end
    end,
    ["and"] = function(exp)
      -- any type
      if exp.left.token == "nil" or exp.left.token == "false" then
        local sub = exp.left
        foldexp(exp, sub.token, sub.value, sub)
      elseif isconsttoken[exp.left.token] then
        -- the constants that failed the first test are all truthy
        local sub = exp.right
        foldexp(exp, sub.token, sub.value, sub)
      end
    end,
    ["or"] = function(exp)
      -- any type
      if exp.left.token == "nil" or exp.left.token == "false" then
        local sub = exp.right
        foldexp(exp, sub.token, sub.value, sub)
      elseif isconsttoken[exp.left.token] then
        -- the constants that failed the first test are all truthy
        local sub = exp.left
        foldexp(exp, sub.token, sub.value, sub)
      end
    end,
  }
  local function fold_const_exp(exp)
    walk_exp(exp,nil,function(exp)
      if exp.token == "unop" then
        foldunop[exp.op](exp)
      elseif exp.token == "binop" then
        foldbinop[exp.op](exp)
      elseif exp.token == "concat" then
        -- combine adjacent number or string
        local newexplist = {}
        local combining = {}
        local combiningpos
        for _,sub in ipairs(exp.explist) do
          if sub.token == "string" or sub.token == "number" then
            if not combining[1] then
              combiningpos = {line = sub.line, column = sub.column}
            end
            combining[#combining+1] = sub.value
          else
            if #combining == 1 then
              newexplist[#newexplist+1] = combining[1]
              combining = {}
              combiningpos = nil
            elseif #combining > 1 then
              newexplist[#newexplist+1] = {
                token = "string",
                line = combiningpos.line, column = combiningpos.column,
                value = table.concat(combining),
                folded = true
              }
              combining = {}
              combiningpos = nil
              exp.folded = true
            end
            newexplist[#newexplist+1] = sub
          end
        end
        if #combining == 1 then
          newexplist[#newexplist+1] = combining[1]
        elseif #combining > 1 then
          newexplist[#newexplist+1] = {
            token = "string",
            line = combiningpos.line, column = combiningpos.column,
            value = table.concat(combining),
            folded = true
          }
          exp.folded = true
        end

        exp.explist = newexplist

        if #exp.explist == 1 then
          -- fold a single string away entirely, if possible
          local sub = exp.explist[1]
          foldexp(exp,sub.token,sub.value,sub)
        end
      else
        -- anything else?
        -- indexing of known-const tables?
        -- calling of specific known-identity, known-const functions?
      end
    end)
  end

  function fold_const(main)
    walk_block(main, nil,
    function(token)
      if token.cond then -- if,while,repeat
        fold_const_exp(token.cond)
      end
      if token.ex then -- call, selfcall
        fold_const_exp(token.ex)
      end
      if token.suffix then -- selfcall
        fold_const_exp(token.suffix)
      end
      if token.args then -- call, selfcall
        for _,exp in ipairs(token.args) do
          fold_const_exp(exp)
        end
      end
      if token.explist then -- localstat, return
        for _,exp in ipairs(token.explist) do
          fold_const_exp(exp)
        end
      end
      if token.lhs then -- assignment
        for _,exp in ipairs(token.lhs) do
          fold_const_exp(exp)
        end
      end
      if token.rhs then -- assignment
        for _,exp in ipairs(token.rhs) do
          fold_const_exp(exp)
        end
      end

      -- now collapse if/while/repeat? or as part of lowering those to do/goto?
    end)
  end
end
----------------------------------------------------------------------
local DumpFunction

function DumpFunction(func)
  -- typedef string:
  -- size_t length (including trailing null, 0 for empty string)
  -- char[] value (not present for empty string)
  

  -- int linedefined (0 for main chunk)
  -- int lastlinedefined (0 for main chunk)
  -- byte nparams
  -- byte isvararg
  -- byte maxstacksize
  -- [Code]
  -- int ninstructions
  -- Instruction[] instructions
  -- [Constants]
  -- int nconsts
  -- TValue[] consts
  --   char type={nil=0,boolean=1,number=3,string=4}
  --   <boolean> char value
  --   <number> double value
  --   <string> string value
  -- [Funcprotos]
  -- int nfuncs
  -- DumpFunction[] funcs
  -- [Upvals]
  -- int nupvals
  -- upvals[] upvals
  --   byte instack (is a local in parent scope, else upvalue in parent)
  --   byte idx
  -- [Debug]
  -- string source
  -- int nlines
  -- int[] lines
  -- int nlocs
  -- localdesc[] locs
  --   string name
  --   int startpc
  --   int endpc
  -- int nups
  -- string[] ups


end

local function DumpHeader()
  -- Lua Signature: "\x1bLua"
  -- byte version = "\x52"
  -- byte format = 0 (official)
  -- byte endianness = 1
  -- byte sizeof(int) = 4
  -- byte sizeof(size_t) = 8?
  -- byte sizeof(Instruction) = 4
  -- byte sizeof(luaNumber) = 8
  -- byte lua_number is int? = 0
  -- magic "\x19\x93\r\n\x1a\n"
  return "\x1bLua\x52\0\1\4\8\4\8\0\x19\x93\r\n\x1a\n"
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
fold_const(main)

print(serpent.dump(main,{indent = '  ', sparse = true, sortkeys = false, comment=true}))

--foo
