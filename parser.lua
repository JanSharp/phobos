local invert = require("invert")

---leading `blank` and `comment` tokens for the current `token`
local leading ---@type Token[]
local token ---@type Token
local next_token
local peek_token
----------------------------------------------------------------------


local statement, expr

--- Throw a Syntax Error at the current location
---@param mesg string Error message
local function syntax_error(mesg)
  error(mesg .. " near '" .. token.token ..
        "' at line " .. (token.line or "(?)") .. ":" .. (token.column or "(?)"))
end

--- Check that the current token is an "ident" token, and if so consume and return it.
---@return Token
local function assert_name()
  if token.token ~= "ident" then
    syntax_error("<name> expected")
  end
  local name = token
  next_token()
  return name
end

--- Search for a reference to a variable.
---@param scope AstScope scope within which to resolve the reference
---@param tok Token|nil Token naming a variable to search for a reference for. Consumes the next token if not given one.
local function check_ref(scope,tok)
  if not tok then tok = assert_name() end
  local original_scope = scope
  local isupval = 0 -- 0 = local, 1 = upval from immediate parent scope, 2+ = chained upval
  local upval_parent = {}
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
          local uppar = upval_parent[i].upvals
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
        tok.upvalparent = upval_parent
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
        upval_parent[isupval] = scope
      end
      scope = scope.parent.scope
    else
      scope = nil
    end
  end

  tok.token = "string"
  tok = {token="index",
  line = tok.line, column = tok.column,
  ex = check_ref(original_scope,{value = "_ENV"}), suffix = tok}
  return tok
end

--- Check if the next token is a `tok` token, and if so consume it. Returns the result of the test.
---@param tok string
---@return boolean
local function test_next(tok)
  if token.token == tok then
    next_token()
    return true
  end
  return false
end

--- Check if the next token is a `tok` token, and if so consume it. Throws a syntax error if token does not match.
---@param tok string
local function assert_next(tok)
  if token.token == tok then
    next_token()
    return
  end
  syntax_error("'" .. tok .. "' expected")
end

--- Check for the matching `close` token to a given `open` token
---@param close string
---@param open string
---@param line number
local function assert_match(close,open,line)
  if not test_next(close) then
    syntax_error("'"..close.."' expected (to close '"..open.."' at line " .. line .. ")")
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
local function stat_list(scope)
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
  next_token()
  local e = expr(scope)
  assert_next("]")
  return e
end

--- Table Constructor record field
---@param scope AstScope
---@return TableField
local function rec_field(scope)
  local k
  if token.token == "ident" then
    k = token
    k.token = "string"
    next_token()
  else
    k = yindex(scope)
  end
  assert_next("=")
  return {type="rec",key=k,value=expr(scope)}
end

--- Table Constructor list field
---@param scope AstScope
---@return TableField
local function list_field(scope)
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
      local peek_tok = peek_token()
      if peek_tok.token ~= "=" then
        return list_field(scope)
      else
        return rec_field(scope)
      end
    end,
    ["["] = rec_field,
  })[token.token] or list_field)(scope)
end

--- Table Constructor
--- `constructor -> '{' [ field { sep field } [sep] ] '}'`
--- `sep -> ',' | ';'`
---@param scope AstScope
---@return Token
local function constructor(scope)
  local line = token.line
  assert_next("{")
  local fields = {}
  repeat
    if token.token == "}" then break end
    fields[#fields+1] = field(scope)
  until not (test_next(",") or test_next(";"))
  assert_match("}","{",line)
  return {token="constructor",fields = fields}
end

--- Function Definition Parameter List
---@param scope AstScope
---@return number number of parameters matched
local function par_list(scope)
  -- parlist -> [ param { `,' param } ]
  if token.token == ")" then
    return 0
  end
  repeat
    if token.token == "ident" then
      token.token = "local"
      scope.locals[#scope.locals+1] = {name = token, wholeblock = true}
      next_token()
    elseif token.token == "..." then
      scope.isvararg = true
      next_token()
      return #scope.locals
    else
      syntax_error("<name> or '...' expected")
    end
  until not test_next(",")
  return #scope.locals
end

--- Function Definition
---@param line number
---@param scope AstScope
---@param ismethod boolean Insert the extra first parameter `self`
---@return Token
local function body(line,scope,ismethod)
  -- body -> `(` parlist `)`  block END
  local parent = {type = "upval", scope = scope}
  ---@narrow scope AstScope|AstFunctionDef
  while not scope.funcprotos do
    scope = scope.parent.scope
  end
  ---@narrow scope AstFunctionDef
  local this_tok = {
    token="functiondef",
    source = scope.source,
    body = false, -- list body before locals
    ismethod = ismethod,
    funcprotos = {},
    locals = {}, upvals = {}, constants = {}, labels = {},
    line = token.line, column = token.column,
    parent = parent,
  }
  if ismethod then
    this_tok.locals[1] = {name = {token="self",value="self"}, wholeblock = true}
  end
  assert_next("(")
  this_tok.nparams = par_list(this_tok)
  assert_next(")")
  this_tok.body = stat_list(this_tok)
  this_tok.endline = token.line
  this_tok.endcolumn = token.column + 3
  assert_match("end","function",line)
  scope.funcprotos[#scope.funcprotos+1] = this_tok
  return {token="funcproto",ref=this_tok}
end

--- Expression List
---@param scope AstScope
---@return Token[]
local function exp_list(scope)
  local el = {(expr(scope))}
  while test_next(",") do
    el[#el+1] = expr(scope)
  end
  return el
end

--- Function Arguments
---@param line number
---@param scope AstScope
---@return Token[]
local function func_args(line,scope)
  return (({
    ["("] = function(scope)
      next_token()
      if token.token == ")" then
        next_token()
        return {}
      end
      local el = exp_list(scope)
      assert_match(")","(",line)
      return el
    end,
    ["string"] = function(scope)
      local el = {token}
      next_token()
      return el
    end,
    ["{"] = function(scope)
      return {(constructor(scope))}
    end,
  })[token.token] or function()
    syntax_error("Function arguments expected")
  end)(scope)
end

--- Primary Expression
---@param scope AstScope
---@return Token
local function primary_exp(scope)
  if token.token == "(" then
    local line = token.line
    next_token() -- skip '('
    --TODO: compact lambda here:
    -- token is ')', empty args expect `'=>' expr` next
    -- token is 'ident'
    --  followed by `,` is multiple args, finish list then `=> expr`
    --  followed by `)` `=>` is single arg, expect `exprlist`
    --  followed by `)` or anything else is expr of inner, current behavior
    local ex = expr(scope)
    assert_match(")","(",line)
    return ex
  elseif token.token == "ident" then
    return check_ref(scope)
  else
    syntax_error("Unexpected symbol '" .. token.token .. "'")
  end
end

local suffixed_tab = {
  ["."] = function(ex)
    local op = token
    next_token() -- skip '.'
    local name = assert_name()
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
    next_token() -- skip ':'
    local name = assert_name()
    name.token = "string"
    return {token="selfcall", ex = ex,
      line = op.line, column = op.column,
      suffix = name,
      args = func_args(op.line,scope),
    }
  end,
  ["("] = function(ex,scope)
    return {token="call", ex = ex,
      line = token.line, column = token.column,
      args = func_args(token.line,scope),
    }
  end,
  ["string"] = function(ex,scope)
    return {token="call", ex = ex,
      line = token.line, column = token.column,
      args = func_args(token.line,scope),
    }
  end,
  ["{"] = function(ex,scope)
    return {token="call", ex = ex,
      line = token.line, column = token.column,
      args = func_args(token.line,scope),
    }
  end,
}

--- Suffixed Expression
---@param scope AstScope
---@return Token
local function suffixed_exp(scope)
  -- suffixedexp ->
  --   primaryexp { '.' NAME | '[' exp ']' | ':' NAME funcargs | funcargs }
  --TODO: safe chaining adds optional '?' in front of each suffix
  local ex = primary_exp(scope)
  local should_break = false
  repeat
    ex = ((suffixed_tab)[token.token] or function(ex)
      should_break = true
      return ex
    end)(ex,scope)
  until should_break
  return ex
end

local simple_toks = invert{"number","string","nil","true","false","..."}

--- Simple Expression
---@param scope AstScope
---@return Token
local function simpleexp(scope)
  -- simpleexp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
  --              constructor | FUNCTION body | suffixedexp
  if simple_toks[token.token] then
    local t = token
    next_token() --consume it
    return t
  end

  if token.token == "{" then
    return constructor(scope)
  elseif token.token == "function" then
    next_token() -- skip FUNCTION
    return body(token.line,scope)
  else
    return suffixed_exp(scope)
  end
end

local unop_prio = {
  ["not"] = 8,
  ["-"] = 8,
  ["#"] = 8,
}
local binop_prio = {
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
---@return AstExpression completed
---@return string nextop
local function sub_expr(limit,scope)
  local ex
  do
    local unop = token.token
    local uprio = unop_prio[unop]
    if uprio then
      next_token() -- consume unop
      local sub = sub_expr(uprio,scope)
      ex = {token="unop", op = unop, ex = sub}
    else
      ex = simpleexp(scope)
    end
  end
  local binop = token.token
  local bprio = binop_prio[binop]
  while bprio and bprio.left > limit do
    next_token()
    local new_right,nextop = sub_expr(bprio.right,scope)
    if binop == ".." then
      if new_right.token == "concat" then
        ---@narrow new_right AstConcat
        table.insert(new_right.explist,1,ex)
        ex = new_right
      else
        ex = {token="concat", explist = {ex,new_right}}
      end
    else
      ex = {token="binop", op = binop, left = ex, right = new_right}
    end
    binop = nextop
    bprio = binop_prio[binop]
  end
  return ex,binop
end

--- Expression
---@param scope AstScope
---@return Token completed
---@return string nextop
function expr(scope)
  return sub_expr(0,scope)
end

--- Assignment Statement
---@param lhs Token[]
---@param scope AstScope
---@return Token
local function assignment(lhs,scope)
  if test_next(",") then
    lhs[#lhs+1] = suffixed_exp(scope)
    return assignment(lhs,scope)
  else
    local this_tok = {token = "assignment", lhs = lhs,}
    local assign = token
    assert_next("=")
    this_tok.line = assign.line
    this_tok.column = assign.column
    this_tok.rhs = exp_list(scope)
    return this_tok
  end
end

--- Label Statement
---@param label Token
---@param scope AstScope
---@return Token
local function label_stat(label,scope)
  assert_next("::")
  label.token = "label"
  local prev_label = scope.labels[label.value]
  if prev_label then
    error("Duplicate label '" .. label.value .. "' at line "
      .. label.line .. ":" .. label.column ..
      " previously defined at line "
      .. prev_label.line .. ":" .. prev_label.column)
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
local function while_stat(line,scope)
  next_token() -- skip WHILE
  local this_tok = {
    token = "whilestat",
    body = false, -- list body before locals
    locals = {}, labels = {},
    parent = {type = "local", scope = scope},
  }
  this_tok.cond = expr(this_tok)
  assert_next("do")

  this_tok.body = stat_list(this_tok)
  assert_match("end","while",line)
  return this_tok
end

--- Repeat Statement
--- `repeatstat -> REPEAT block UNTIL cond`
---@param line number
---@param scope AstScope
---@return Token
local function repeat_stat(line,scope)
  local this_tok = {
    token = "repeatstat",
    cond = false, -- list cond first
    body = false, -- list body before locals
    locals = {}, labels = {},
    parent = {type = "local", scope = scope},
  }
  next_token() -- skip REPEAT
  this_tok.body = stat_list(this_tok)
  assert_match("until","repeat",line)
  this_tok.cond = expr(this_tok)
  return this_tok
end

--- Numeric For Statement
--- `fornum -> NAME = exp1,exp1[,exp1] DO block`
---@param first_name Token
---@param scope AstScope
---@return Token
local function fornum(first_name,scope)
  assert_next("=")
  local start = expr(scope)
  assert_next(",")
  local stop = expr(scope)
  local step = {token="number", value=1}
  if test_next(",") then
    step = expr(scope)
  end
  assert_next("do")
  local this_tok = {
    token = "fornum",
    var = first_name,
    start = start, stop = stop, step = step,
    body = false, -- list body before local
    locals = {
      {name = first_name, wholeblock = true},
    }, labels = {},
    parent = {type = "local", scope = scope},
  }
  this_tok.body = stat_list(this_tok)
  return this_tok
end

--- Generic For Statement
--- `forlist -> NAME {,NAME} IN explist DO block`
---@param first_name Token
---@param scope AstScope
---@return Token
local function forlist(first_name,scope)
  local nl = {first_name}
  local this_tok = {
    token = "forlist",
    namelist = nl,
    explist = false, -- list explist in order
    body = false, -- list body before locals
    locals = {
      {name = first_name, wholeblock = true},
    }, labels = {},
    parent = {type = "local", scope = scope},
  }
  while test_next(",") do
    local name = assert_name()
    name.token = "local"
    this_tok.locals[#this_tok.locals+1] =
      {name = name, wholeblock = true}
    nl[#nl+1] = name
  end
  assert_next("in")
  this_tok.explist = exp_list(scope)
  assert_next("do")
  this_tok.body = stat_list(this_tok)
  return this_tok
end

--- For Statement
--- `forstat -> FOR (fornum | forlist) END`
---@param line number
---@param parent AstScope
---@return Token
local function for_stat(line,parent)
  next_token() -- skip FOR
  local firstname = assert_name()
  firstname.token = "local"
  local t= token.token
  local for_tok
  if t == "=" then
    for_tok = fornum(firstname,parent)
  elseif t == "," or t == "in" then
    for_tok = forlist(firstname,parent)
  else
    syntax_error("'=', ',' or 'in' expected")
  end
  assert_match("end","for",line)
  return for_tok
end


local function test_then_block(scope)
  -- test_then_block -> [IF | ELSEIF] cond THEN block
  --TODO: [IF | ELSEIF] ( cond | namelist '=' explist  [';' cond] ) THEN block
  -- if first token is ident, and second is ',' or '=', use if-init, else original parse
  -- if no cond in if-init, first name/expr is used
  next_token() -- skip IF or ELSEIF
  local this_tok = {token = "testblock",
    cond = false, -- list cond first
    body = false, -- list body before locals
    locals = {}, labels = {},
    parent = {type = "local", scope = scope},
  }
  this_tok.cond = expr(this_tok)
  assert_next("then")

  this_tok.body = stat_list(this_tok)
  return this_tok
end

local function if_stat(line,scope)
  -- ifstat -> IF cond THEN block {ELSEIF cond THEN block} [ELSE block] END
  local ifs = {}
  repeat
    ifs[#ifs+1] = test_then_block(scope)
  until token.token ~= "elseif"
  local else_block
  if test_next("else") then
    else_block = {token="elseblock",
      body = false, -- list body before locals
      locals = {}, labels = {},
      parent = {type = "local", scope = scope},
    }
    else_block.body = stat_list(else_block)
  end
  assert_match("end","if",line)
  return {token = "ifstat", ifs = ifs, elseblock = else_block}
end

local function local_func(scope)
  local name = assert_name()
  name.token = "local"
  local this_local = {name = name}
  scope.locals[#scope.locals+1] = this_local
  local b = body(token.line,scope)
  b.token = "localfunc"
  b.name = name
  this_local.startbefore = b
  return b
end

local function local_stat(scope)
  -- stat -> LOCAL NAME {`,' NAME} [`=' explist]
  local lhs = {}
  local this_tok = {token="localstat", lhs = lhs}
  repeat
    local name = assert_name()
    name.token = "local"
    lhs[#lhs+1] = name
  until not test_next(",")
  local assign = token
  if test_next("=") then
    this_tok.line = assign.line
    this_tok.column = assign.column
    this_tok.rhs = exp_list(scope)
  end
  for _,name in ipairs(this_tok.lhs) do
    scope.locals[#scope.locals+1] = {name = name, startafter = this_tok}
  end
  return this_tok
end

local function func_name(scope)
  -- funcname -> NAME {fieldsel} [`:' NAME]

  local dot_path = { check_ref(scope) }

  while token.token == "." do
    next_token() -- skip '.'
    dot_path[#dot_path+1] = assert_name()
  end

  if token.token == ":" then
    next_token() -- skip ':'
    dot_path[#dot_path+1] = assert_name()
    return true,dot_path
  end

  return false,dot_path
end

local function func_stat(line,scope)
  -- funcstat -> FUNCTION funcname body
  next_token() -- skip FUNCTION
  local ismethod,names = func_name(scope)
  local b = body(line,scope,ismethod)
  b.token = "funcstat"
  b.names = names
  return b
end

local function expr_stat(scope)
  -- stat -> func | assignment
  local first_exp = suffixed_exp(scope)
  if token.token == "=" or token.token == "," then
    -- stat -> assignment
    return assignment({first_exp},scope)
  else
    -- stat -> func
    if first_exp.token == "call" or first_exp.token == "selfcall" then
      return first_exp
    else
      syntax_error("Unexpected <exp>")
    end
  end
end

local function ret_stat(scope)
  -- stat -> RETURN [explist] [';']
  local el
  if block_follow(true) or token.token == ";" then
    -- return no values
  else
    el = exp_list(scope)
  end
  test_next(";")
  return {token="retstat", explist = el}
end

local statement_lut = {
  [";"] = function(scope) -- stat -> ';' (empty statement)
    next_token() -- skip
    return {token = "empty", }
  end,
  ["if"] = function(scope) -- stat -> ifstat
    local line = token.line;
    return if_stat(line,scope)
  end,
  ["while"] = function(scope) -- stat -> whilestat
    local line = token.line;
    return while_stat(line,scope)
  end,
  ["do"] = function(scope) -- stat -> DO block END
    local line = token.line;
    next_token() -- skip "do"
    local dostat = {
      token = "dostat",
      body = false, -- list body before local
      locals = {}, labels = {},
      parent = {type = "local", scope = scope}
    }
    dostat.body = stat_list(dostat)
    assert_match("end","do",line)
    return dostat
  end,
  ["for"] = function(scope) -- stat -> forstat
    local line = token.line;
    return for_stat(line,scope)
  end,
  ["repeat"] = function(scope) -- stat -> repeatstat
    local line = token.line;
    return repeat_stat(line, scope)
  end,
  ["function"] = function(scope) -- stat -> funcstat
    local line = token.line;
    return func_stat(line, scope)
  end,
  ["local"] = function(scope) -- stat -> localstat
    next_token() -- skip "local"
    if test_next("function") then
      return local_func(scope)
    else
      return local_stat(scope)
    end
  end,
  ["::"] = function(scope) -- stat -> label
    next_token() -- skip "::"
    return label_stat(assert_name(),scope)
  end,
  ["return"] = function(scope) -- stat -> retstat
    next_token() -- skip "return"
    return ret_stat(scope)
  end,

  ["break"] = function(scope) -- stat -> breakstat
    next_token() -- skip BREAK
    return {token = "breakstat"}
  end,
  ["goto"] = function(scope) -- stat -> 'goto' NAME
    next_token() -- skip GOTO
    return {token = "gotostat", target = assert_name()}
  end,
}
function statement(scope)
  return (statement_lut[token.token] or expr_stat)(scope)
end


local function main_func(chunk_name)
  local main = {
    token = "main",
    source = chunk_name,
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
  main.body = stat_list(main)
  return main
end

local tokenize = require("tokenize")
local function parse(text,source_name)
  local token_iter,str,index = tokenize(text)


  function next_token()
    leading = {}
    while true do
      index,token = token_iter(str,index)
      if not token then
        token = {token="eof"}
        break
      end
      if token.token == "comment" then
        leading[#leading+1] = token
        -- parse doc comments, accumulate them for the next token that wants them
        --[[ these patterns match all of the following:
          --- Description text, three dashes, a space, and any text
          ---@tag three dashes, at-tag, and any text
          -- @tag two dashes, a space, at-tag, and any text
        ]]
        if token.value:match("^%- ") or token.value:match("^[- ]@") then
          print("found doc comment " .. token.value)
        end
      elseif token.token == "blank" then
        leading[#leading+1] = token
      else
        break
      end
    end
  end

  function peek_token(start_at)
    local line, line_offset = str.line, str.line_offset
    start_at = start_at or index
    local peek_tok
    repeat
      start_at,peek_tok = token_iter(str,start_at)
    until peek_tok.token ~= "blank" and peek_tok.token ~= "comment"
    str.line, str.line_offset = line, line_offset
    return peek_tok, start_at
  end

  next_token()

  return main_func(source_name)
end

return parse