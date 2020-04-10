local invert = require("invert")

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

local function checkref(parent,tok)
  if not tok then tok = checkname() end
  local origparent = parent
  local isupval = 0 -- 0 = local, 1 = upval from immediate parent, 2+ = chained upval
  local upvalparent = {}
  while parent do
    local found
    for _,loc in ipairs(parent.locals) do
      if tok.value == loc.name.value then
        -- keep looking to find the most recently defined one,
        -- in case some nut redefines the same name repeatedly in the same scope
        found = loc
      end
    end
    if not found and parent.upvals then
      for _,up in ipairs(parent.upvals) do
        if tok.value == up.name then
          found = up
        end
      end
    end
    if found then
      if isupval>0 then
        for i = 1,isupval do
          local uppar = upvalparent[i].upvals
          local newup = {name=tok.value,updepth=i + (found.updepth or 0),ref=found}
          if tok.value == "_ENV" then
            -- always put _ENV first, if present,
            -- so that `load`'s mangling will be correct
            table.insert(uppar,1,newup)
          else
            uppar[#uppar+1] = newup
          end
          found = newup
        end
        tok.upvalparent = upvalparent
        tok.token = "upval"
      elseif found.updepth then
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
    k = token
    k.token = "string"
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
    source = parent.source,
    body = false, -- list body before locals
    ismethod = ismethod,
    funcprotos = {},
    locals = {}, upvals = {}, constants = {}, labels = {},
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
    -- token is ')', empty args expect `'=>' expr` next
    -- token is 'ident'
    --  followed by `,` is multiple args, finish list then `=> expr`
    --  followed by `)` `=>` is single arg, expect `exprlist`
    --  followed by `)` or anything else is expr of inner, current behavior
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
    locals = {
      {name = firstname, wholeblock = true},
    }, labels = {},
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
    for _,name in ipairs(thistok.lhs) do
      parent.locals[#parent.locals+1] = {name = name, startafter = thistok}
    end
    return thistok
  else
    for _,name in ipairs(thistok.lhs) do
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
    return {token = "empty", }
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
    token = "main",
    source = chunkname,
    -- fake parent of main to provide _ENV upval
    parent = {
      type = "upval", parent = {
        token = "env",
        locals = {
          -- Lua emits _ENV as if it's a local in the parent scope
          -- of the file. I'll probably change this one day to be
          -- the first upval of the parent scope, since load()
          -- clobbers the first upval anyway to be the new _ENV value
          {name = {token="_ENV",value="_ENV"}, wholeblock = true}
        }
      }
    },
    funcprotos = {},
    body = false, -- list body before locals
    isvararg = true, -- main is always vararg
    locals = {}, upvals = {}, constants = {}, labels = {},
  }
  main.body = statlist(main)
  return main
end

local Tokenize = require("tokenize")
local function parse(text,sourcename)
  local tokeniter,str,index = Tokenize(text)


  function nexttoken()
    repeat
      index,token = tokeniter(str,index)
    until not token or token.token ~= "comment"
    if not token then
      token = {token="eof"}
    end
    return token
  end

  function peektoken(startat)
    startat = startat or index
    local peektok
    repeat
      startat,peektok = tokeniter(str,startat)
    until peektok.token ~= "comment"
    return peektok, startat
  end

  nexttoken()

  return mainfunc(sourcename)
end

return parse