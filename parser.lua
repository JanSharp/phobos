local invert = require("invert")

---@type Token
local token
local nexttoken
local peektoken
----------------------------------------------------------------------


local statement, expr

--- Throw a Syntax Error at the current location
---@param mesg string Error message
local function syntaxerror(mesg)
  error(mesg .. " near '" .. token.token ..
        "' at line " .. (token.line or "(?)") .. ":" .. (token.column or "(?)"))
end

--- Check that the current token is an "ident" token, and if so consume and return it.
---@return Token
local function assertname()
  if token.token ~= "ident" then
    syntaxerror("<name> expected")
  end
  local name = token
  nexttoken()
  return name
end

--- Search for a reference to a variable.
---@param scope AstScope scope within which to resolve the reference
---@param tok Token|nil Token naming a variable to search for a reference for. Consumes the next token if not given one.
local function checkref(scope,tok)
  if not tok then tok = assertname() end
  local origparent = scope
  local isupval = 0 -- 0 = local, 1 = upval from immediate parent scope, 2+ = chained upval
  local upvalparent = {}
  while scope do
    local found
    for _,loc in ipairs(scope.locals) do
      if tok.value == loc.name.value then
        -- keep looking to find the most recently defined one,
        -- in case some nut redefines the same name repeatedly in the same scope
        found = loc
      end
    end
    if not found and scope.upvals then
      for _,up in ipairs(scope.upvals) do
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
    if scope.parent then
      if scope.parent.type == "upval" then
        isupval = isupval + 1
        upvalparent[isupval] = scope
      end
      scope = scope.parent.scope
    else
      scope = nil
    end
  end

  tok.token = "string"
  tok = {token="index",
  line = tok.line, column = tok.column,
  ex = checkref(origparent,{value = "_ENV"}), suffix = tok}
  return tok
end

--- Check if the next token is a `tok` token, and if so consume it. Returns the result of the test.
---@param tok string
---@return boolean
local function testnext(tok)
  if token.token == tok then
    nexttoken()
    return true
  end
  return false
end

--- Check if the next token is a `tok` token, and if so consume it. Throws a syntax error if token does not match.
---@param tok string
local function assertnext(tok)
  if token.token == tok then
    nexttoken()
    return
  end
  syntaxerror("'" .. tok .. "' expected")
end

--- Check for the matching `close` token to a given `open` token
---@param close string
---@param open string
---@param line number
local function assertmatch(close,open,line)
  if not testnext(close) then
    syntaxerror("'"..close.."' expected (to close '"..open.."' at line " .. line .. ")")
  end
end

local blockends = invert{"else", "elseif", "end", "eof"}

--- Test if the next token closes a block
---@param withuntil boolean if true, "until" token will count as closing a block
---@return boolean
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

--- Read a list of Statements
--- `statlist -> { stat [';'] }`
---@param scope AstScope
---@return AstStatement[]
local function statlist(scope)
  local sl = {}
  while not block_follow(true) do
    if token.token == "eof" then
      return sl
    elseif token.token == "return" then
      sl[#sl+1] = statement(scope)
      return sl
    end
    sl[#sl+1] = statement(scope)
  end
  return sl
end

--- `index -> '[' expr ']'`
---@param scope AstScope
---@return Token
local function yindex(scope)
  nexttoken()
  local e = expr(scope)
  assertnext("]")
  return e
end

--- Table Constructor record field
---@param scope AstScope
---@return TableField
local function recfield(scope)
  local k
  if token.token == "ident" then
    k = token
    k.token = "string"
    nexttoken()
  else
    k = yindex(scope)
  end
  assertnext("=")
  return {type="rec",key=k,value=expr(scope)}
end

--- Table Constructor list field
---@param scope AstScope
---@return TableField
local function listfield(scope)
  return {type="list",value=expr(scope)}
end

--- Table Constructor field
--- `field -> listfield | recfield`
---@param scope AstScope
---@return TableField
local function field(scope)
  ---@class TableField
  ---@field type string "rec"|"list"
  ---@field key Token|nil
  ---@field value Token
  return (({
    ["ident"] = function(scope)
      local peektok = peektoken()
      if peektok.token ~= "=" then
        return listfield(scope)
      else
        return recfield(scope)
      end
    end,
    ["["] = recfield,
  })[token.token] or listfield)(scope)
end

--- Table Constructor
--- `constructor -> '{' [ field { sep field } [sep] ] '}'`
--- `sep -> ',' | ';'`
---@param scope AstScope
---@return Token
local function constructor(scope)
  local line = token.line
  assertnext("{")
  local fields = {}
  repeat
    if token.token == "}" then break end
    fields[#fields+1] = field(scope)
  until not (testnext(",") or testnext(";"))
  assertmatch("}","{",line)
  return {token="constructor",fields = fields}
end

--- Function Definition Parameter List
---@param scope AstScope
---@return number number of parameters matched
local function parlist(scope)
  -- parlist -> [ param { `,' param } ]
  if token.token == ")" then
    return 0
  end
  repeat
    if token.token == "ident" then
      token.token = "local"
      scope.locals[#scope.locals+1] = {name = token, wholeblock = true}
      nexttoken()
    elseif token.token == "..." then
      scope.isvararg = true
      nexttoken()
      return #scope.locals
    else
      syntaxerror("<name> or '...' expected")
    end
  until not testnext(",")
  return #scope.locals
end

--- Function Definition
---@param line number
---@param scope AstScope
---@param ismethod boolean Insert the extra first parameter `self`
---@return Token
local function body(line,scope,ismethod)
  -- body -> `(` parlist `)`  block END
  local thistok = {
    token="functiondef",
    source = scope.source,
    body = false, -- list body before locals
    ismethod = ismethod,
    funcprotos = {},
    locals = {}, upvals = {}, constants = {}, labels = {},
    line = token.line, column = token.column,
    parent = {type = "upval", scope = scope},
  }
  if ismethod then
    thistok.locals[1] = {name = {token="self",value="self"}, wholeblock = true}
  end
  assertnext("(")
  thistok.nparams = parlist(thistok)
  assertnext(")")
  thistok.body = statlist(thistok)
  thistok.endline = token.line
  thistok.endcolumn = token.column + 3
  assertmatch("end","function",line)
  while not scope.funcprotos do
    scope = scope.parent.scope
  end
  scope.funcprotos[#scope.funcprotos+1] = thistok
  return {token="funcproto",ref=thistok}
end

--- Expression List
---@param scope AstScope
---@return Token[]
local function explist(scope)
  local el = {(expr(scope))}
  while testnext(",") do
    el[#el+1] = expr(scope)
  end
  return el
end

--- Function Arguments
---@param line number
---@param scope AstScope
---@return Token[]
local function funcargs(line,scope)
  return (({
    ["("] = function(scope)
      nexttoken()
      if token.token == ")" then
        nexttoken()
        return {}
      end
      local el = explist(scope)
      assertmatch(")","(",line)
      return el
    end,
    ["string"] = function(scope)
      local el = {token}
      nexttoken()
      return el
    end,
    ["{"] = function(scope)
      return {(constructor(scope))}
    end,
  })[token.token] or function()
    syntaxerror("Function arguments expected")
  end)(scope)
end

--- Primary Expression
---@param scope AstScope
---@return Token
local function primaryexp(scope)
  if token.token == "(" then
    local line = token.line
    nexttoken() -- skip '('
    --TODO: compact lambda here:
    -- token is ')', empty args expect `'=>' expr` next
    -- token is 'ident'
    --  followed by `,` is multiple args, finish list then `=> expr`
    --  followed by `)` `=>` is single arg, expect `exprlist`
    --  followed by `)` or anything else is expr of inner, current behavior
    local ex = expr(scope)
    assertmatch(")","(",line)
    return ex
  elseif token.token == "ident" then
    return checkref(scope)
  else
    syntaxerror("Unexpected symbol '" .. token.token .. "'")
  end
end

local suffixedtab = {
  ["."] = function(ex)
    local op = token
    nexttoken() -- skip '.'
    local name = assertname()
    name.token = "string"
    return {token="index", line = op.line, column = op.column,
            ex = ex, suffix = name}
  end,
  ["["] = function(ex,scope)
    return {token="index",
            line = token.line, column = token.column,
            ex = ex, suffix = yindex(scope)}
  end,
  [":"] = function(ex,scope)
    local op = token
    nexttoken() -- skip ':'
    local name = assertname()
    name.token = "string"
    return {token="selfcall", ex = ex,
      line = op.line, column = op.column,
      suffix = name,
      args = funcargs(op.line,scope),
    }
  end,
  ["("] = function(ex,scope)
    return {token="call", ex = ex,
      line = token.line, column = token.column,
      args = funcargs(token.line,scope),
    }
  end,
  ["string"] = function(ex,scope)
    return {token="call", ex = ex,
      line = token.line, column = token.column,
      args = funcargs(token.line,scope),
    }
  end,
  ["{"] = function(ex,scope)
    return {token="call", ex = ex,
      line = token.line, column = token.column,
      args = funcargs(token.line,scope),
    }
  end,
}

--- Suffixed Expression
---@param scope AstScope
---@return Token
local function suffixedexp(scope)
  -- suffixedexp ->
  --   primaryexp { '.' NAME | '[' exp ']' | ':' NAME funcargs | funcargs }
  --TODO: safe chaining adds optional '?' in front of each suffix
  local ex = primaryexp(scope)
  local shouldbreak = false
  repeat
    ex = ((suffixedtab)[token.token] or function(ex)
      shouldbreak = true
      return ex
    end)(ex,scope)
  until shouldbreak
  return ex
end

local simpletoks = invert{"number","string","nil","true","false","..."}

--- Simple Expression
---@param scope AstScope
---@return Token
local function simpleexp(scope)
  -- simpleexp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
  --              constructor | FUNCTION body | suffixedexp
  if simpletoks[token.token] then
    local t = token
    nexttoken() --consume it
    return t
  end

  if token.token == "{" then
    return constructor(scope)
  elseif token.token == "function" then
    nexttoken() -- skip FUNCTION
    return body(token.line,scope)
  else
    return suffixedexp(scope)
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

--- Subexpression
--- `subexpr -> (simpleexp | unop subexpr) { binop subexpr }`
--- where `binop' is any binary operator with a priority higher than `limit'
---@param limit number
---@param scope AstScope
---@return Token completed
---@return string nextop
local function subexpr(limit,scope)
  local ex
  do
    local unop = token.token
    local uprio = unopprio[unop]
    if uprio then
      nexttoken() -- consume unop
      local sub = subexpr(uprio,scope)
      ex = {token="unop", op = unop, ex = sub}
    else
      ex = simpleexp(scope)
    end
  end
  local binop = token.token
  local bprio = binopprio[binop]
  while bprio and bprio.left > limit do
    nexttoken()
    local newright,nextop = subexpr(bprio.right,scope)
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

--- Expression
---@param scope AstScope
---@return Token completed
---@return string nextop
function expr(scope)
  return subexpr(0,scope)
end

--- Assignment Statement
---@param lhs Token[]
---@param scope AstScope
---@return Token
local function assignment(lhs,scope)
  if testnext(",") then
    lhs[#lhs+1] = suffixedexp(scope)
    return assignment(lhs,scope)
  else
    local thistok = {token = "assignment", lhs = lhs,}
    local assign = token
    assertnext("=")
    thistok.line = assign.line
    thistok.column = assign.column
    thistok.rhs = explist(scope)
    return thistok
  end
end

--- Label Statement
---@param label Token
---@param scope AstScope
---@return Token
local function labelstat(label,scope)
  assertnext("::")
  label.token = "label"
  local prevlabel = scope.labels[label.value]
  if prevlabel then
    error("Duplicate label '" .. label.value .. "' at line "
      .. label.line .. ":" .. label.column ..
      " previously defined at line "
      .. prevlabel.line .. ":" .. prevlabel.column)
  else
    scope.labels[label.value] = label
  end
  return label
end

--- While Statement
--- `whilestat -> WHILE cond DO block END`
---@param line number
---@param scope AstScope
---@return Token
local function whilestat(line,scope)
  nexttoken() -- skip WHILE
  local thistok = {
    token = "whilestat",
    body = false, -- list body before locals
    locals = {}, labels = {},
    parent = {type = "local", scope = scope},
  }
  thistok.cond = expr(thistok)
  assertnext("do")

  thistok.body = statlist(thistok)
  assertmatch("end","while",line)
  return thistok
end

--- Repeat Statement
--- `repeatstat -> REPEAT block UNTIL cond`
---@param line number
---@param scope AstScope
---@return Token
local function repeatstat(line,scope)
  local thistok = {
    token = "repeatstat",
    cond = false, -- list cond first
    body = false, -- list body before locals
    locals = {}, labels = {},
    parent = {type = "local", scope = scope},
  }
  nexttoken() -- skip REPEAT
  thistok.body = statlist(thistok)
  assertmatch("until","repeat",line)
  thistok.cond = expr(thistok)
  return thistok
end

--- Numeric For Statement
--- `fornum -> NAME = exp1,exp1[,exp1] DO block`
---@param firstname Token
---@param scope AstScope
---@return Token
local function fornum(firstname,scope)
  assertnext("=")
  local start = expr(scope)
  assertnext(",")
  local stop = expr(scope)
  local step = {token="number", value=1}
  if testnext(",") then
    step = expr(scope)
  end
  assertnext("do")
  local thistok = {
    token = "fornum",
    var = firstname,
    start = start, stop = stop, step = step,
    body = false, -- list body before local
    locals = {
      {name = firstname, wholeblock = true},
    }, labels = {},
    parent = {type = "local", scope = scope},
  }
  thistok.body = statlist(thistok)
  return thistok
end

--- Generic For Statement
--- `forlist -> NAME {,NAME} IN explist DO block`
---@param firstname Token
---@param scope AstScope
---@return Token
local function forlist(firstname,scope)
  local nl = {firstname}
  local thistok = {
    token = "forlist",
    namelist = nl,
    explist = false, -- list explist in order
    body = false, -- list body before locals
    locals = {
      {name = firstname, wholeblock = true},
    }, labels = {},
    parent = {type = "local", scope = scope},
  }
  while testnext(",") do
    local name = assertname()
    name.token = "local"
    thistok.locals[#thistok.locals+1] =
      {name = name, wholeblock = true}
    nl[#nl+1] = name
  end
  assertnext("in")
  thistok.explist = explist(scope)
  assertnext("do")
  thistok.body = statlist(thistok)
  return thistok
end

--- For Statement
--- `forstat -> FOR (fornum | forlist) END`
---@param line number
---@param parent AstScope
---@return Token
local function forstat(line,parent)
  nexttoken() -- skip FOR
  local firstname = assertname()
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
  assertmatch("end","for",line)
  return fortok
end


local function test_then_block(scope)
  -- test_then_block -> [IF | ELSEIF] cond THEN block
  --TODO: [IF | ELSEIF] ( cond | namelist '=' explist  [';' cond] ) THEN block
  -- if first token is ident, and second is ',' or '=', use if-init, else original parse
  -- if no cond in if-init, first name/expr is used
  nexttoken() -- skip IF or ELSEIF
  local thistok = {token = "testblock",
    cond = false, -- list cond first
    body = false, -- list body before locals
    locals = {}, labels = {},
    parent = {type = "local", scope = scope},
  }
  thistok.cond = expr(thistok)
  assertnext("then")

  thistok.body = statlist(thistok)
  return thistok
end

local function ifstat(line,scope)
  -- ifstat -> IF cond THEN block {ELSEIF cond THEN block} [ELSE block] END
  local ifs = {}
  repeat
    ifs[#ifs+1] = test_then_block(scope)
  until token.token ~= "elseif"
  local elseblock
  if testnext("else") then
    elseblock = {token="elseblock",
      body = false, -- list body before locals
      locals = {}, labels = {},
      parent = {type = "local", scope = scope},
    }
    elseblock.body = statlist(elseblock)
  end
  assertmatch("end","if",line)
  return {token = "ifstat", ifs = ifs, elseblock = elseblock}
end

local function localfunc(scope)
  local name = assertname()
  name.token = "local"
  local thislocal = {name = name}
  scope.locals[#scope.locals+1] = thislocal
  local b = body(token.line,scope)
  b.token = "localfunc"
  b.name = name
  thislocal.startbefore = b
  return b
end

local function localstat(scope)
  -- stat -> LOCAL NAME {`,' NAME} [`=' explist]
  local lhs = {}
  local thistok = {token="localstat", lhs = lhs}
  repeat
    local name = assertname()
    name.token = "local"
    lhs[#lhs+1] = name
  until not testnext(",")
  local assign = token
  if testnext("=") then
    thistok.line = assign.line
    thistok.column = assign.column
    thistok.rhs = explist(scope)
  end
  for _,name in ipairs(thistok.lhs) do
    scope.locals[#scope.locals+1] = {name = name, startafter = thistok}
  end
  return thistok
end

local function funcname(scope)
  -- funcname -> NAME {fieldsel} [`:' NAME]

  local dotpath = { checkref(scope) }

  while token.token == "." do
    nexttoken() -- skip '.'
    dotpath[#dotpath+1] = assertname()
  end

  if token.token == ":" then
    nexttoken() -- skip ':'
    dotpath[#dotpath+1] = assertname()
    return true,dotpath
  end

  return false,dotpath
end

local function funcstat(line,scope)
  -- funcstat -> FUNCTION funcname body
  nexttoken() -- skip FUNCTION
  local ismethod,names = funcname(scope)
  local b = body(line,scope,ismethod)
  b.token = "funcstat"
  b.names = names
  return b
end

local function exprstat(scope)
  -- stat -> func | assignment
  local firstexp = suffixedexp(scope)
  if token.token == "=" or token.token == "," then
    -- stat -> assignment
    return assignment({firstexp},scope)
  else
    -- stat -> func
    if firstexp.token == "call" or firstexp.token == "selfcall" then
      return firstexp
    else
      syntaxerror("Unexpected <exp>")
    end
  end
end

local function retstat(scope)
  -- stat -> RETURN [explist] [';']
  local el
  if block_follow(true) or token.token == ";" then
    -- return no values
  else
    el = explist(scope)
  end
  testnext(";")
  return {token="retstat", explist = el}
end

local statement_lut = {
  [";"] = function(scope) -- stat -> ';' (empty statement)
    nexttoken() -- skip
    return {token = "empty", }
  end,
  ["if"] = function(scope) -- stat -> ifstat
    local line = token.line;
    return ifstat(line,scope)
  end,
  ["while"] = function(scope) -- stat -> whilestat
    local line = token.line;
    return whilestat(line,scope)
  end,
  ["do"] = function(scope) -- stat -> DO block END
    local line = token.line;
    nexttoken() -- skip "do"
    local dostat = {
      token = "dostat",
      body = false, -- list body before local
      locals = {}, labels = {},
      parent = {type = "local", scope = scope}
    }
    dostat.body = statlist(dostat)
    assertmatch("end","do",line)
    return dostat
  end,
  ["for"] = function(scope) -- stat -> forstat
    local line = token.line;
    return forstat(line,scope)
  end,
  ["repeat"] = function(scope) -- stat -> repeatstat
    local line = token.line;
    return repeatstat(line, scope)
  end,
  ["function"] = function(scope) -- stat -> funcstat
    local line = token.line;
    return funcstat(line, scope)
  end,
  ["local"] = function(scope) -- stat -> localstat
    nexttoken() -- skip "local"
    if testnext("function") then
      return localfunc(scope)
    else
      return localstat(scope)
    end
  end,
  ["::"] = function(scope) -- stat -> label
    nexttoken() -- skip "::"
    return labelstat(assertname(),scope)
  end,
  ["return"] = function(scope) -- stat -> retstat
    nexttoken() -- skip "return"
    return retstat(scope)
  end,

  ["break"] = function(scope) -- stat -> breakstat
    nexttoken() -- skip BREAK
    return {token = "breakstat"}
  end,
  ["goto"] = function(scope) -- stat -> 'goto' NAME
    nexttoken() -- skip GOTO
    return {token = "gotostat", target = assertname()}
  end,
}
function statement(scope)
  return (statement_lut[token.token] or exprstat)(scope)
end


local function mainfunc(chunkname)
  local main = {
    token = "main",
    source = chunkname,
    -- fake parent scope of main to provide _ENV upval
    parent = {
      type = "upval", scope = {
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

    ismethod = false,
    line = 0,
    endline = 0,
    column = 0,
    endcolumn = 0,
    nparams = 0,
  }
  main.body = statlist(main)
  return main
end

local Tokenize = require("tokenize")
local function parse(text,sourcename)
  local tokeniter,str,index = Tokenize(text)


  function nexttoken()
    while true do
      index,token = tokeniter(str,index)
      if not token then
        token = {token="eof"}
        break
      end
      if token.token == "comment" then
        -- parse doc comments, accumulate them for the next token that wants them
        --[[ these patterns match all of the following:
          --- Description text, three dashes, a space, and any text
          ---@tag three dashes, at-tag, and any text
          -- @tag two dashes, a space, at-tag, and any text
        ]]
        if token.value:match("^%- ") or token.value:match("^[- ]@") then
          print("found doc comment " .. token.value)
        end
      else
        break
      end
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