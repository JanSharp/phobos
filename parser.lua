local invert = require("invert")

---leading `blank` and `comment` tokens for the current `token`
local leading ---@type Token[]
local token ---@type Token
---set by test_next() and therefore also assert_next() and assert_match()
local prev_leading ---@type Token[]
---set by test_next() and therefore also assert_next() and assert_match()
local prev_token ---@type Token
local next_token
local peek_token
----------------------------------------------------------------------


local statement, expr

--- Throw a Syntax Error at the current location
---@param msg string Error message
local function syntax_error(msg)
  error(msg .. " near '" .. token.token ..
        "' at line " .. (token.line or "(?)") .. ":" .. (token.column or "(?)"))
end

--- Check that the current token is an "ident" token, and if so consume and return it.
---@return AstIdent name
local function assert_name()
  if token.token ~= "ident" then
    syntax_error("<name> expected")
  end
  local name = token
  name.leading = leading
  next_token()
  return name
end

---create new AstNode using the current `token` and `leading`
---@param node_token AstNodeToken
---@param use_prev boolean @ should this node be created using `prev_token` and `prev_leading`?
local function new_node(node_token, use_prev)
  return {
    token = node_token,
    line = (use_prev and prev_token or token).line,
    column = (use_prev and prev_token or token).column,
    leading = (use_prev and prev_leading or leading),
  }
end

---@param use_prev? boolean @ should this node be created using `prev_token` and `prev_leading`? Default: `false`
---@param value? string @ Default: `(use_prev and prev_token.token or token.token)`
---@return AstTokenNode
local function new_token_node(use_prev, value)
  local node = new_node("token", use_prev)
  node.value = value or (use_prev and prev_token.token or token.token)
  return node
end

--- Search for a reference to a variable.
---@param scope AstScope scope within which to resolve the reference
---@param tok Token|nil Token naming a variable to search for a reference for. Consumes the next token if not given one.
local function check_ref(scope,tok)
  if not tok then tok = assert_name() end
  local original_scope = scope
  local is_upval = 0 -- 0 = local, 1 = upval from immediate parent scope, 2+ = chained upval
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
      if is_upval>0 then
        for i = 1,is_upval do
          local parent_upvals = upval_parent[i].upvals
          local new_upval = {name=tok.value,up_depth=i + (found.up_depth or 0),ref=found}
          if tok.value == "_ENV" then
            -- always put _ENV first, if present,
            -- so that `load`'s mangling will be correct
            table.insert(parent_upvals,1,new_upval)
          else
            parent_upvals[#parent_upvals+1] = new_upval
          end
          found = new_upval
        end
        tok.upval_parent = upval_parent
        tok.token = "upval"
      elseif found.up_depth then
        tok.token = "upval"
      else
        tok.token = "local"
      end
      tok.ref = found
      return tok
    end
    if scope.parent then
      if scope.parent.type == "upval" then
        is_upval = is_upval + 1
        upval_parent[is_upval] = scope
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
---@param tok TokenToken
---@return boolean
local function test_next(tok)
  if token.token == tok then
    prev_leading = leading
    prev_token = token
    next_token()
    return true
  end
  return false
end

--- Check if the next token is a `tok` token, and if so consume it. Throws a syntax error if token does not match.
---@param tok string
local function assert_next(tok)
  if not test_next(tok) then
    syntax_error("'" .. tok .. "' expected")
  end
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

local block_ends = invert{"else", "elseif", "end", "eof"}

--- Test if the next token closes a block
---@param with_until boolean if true, "until" token will count as closing a block
---@return boolean
local function block_follow(with_until)
  local tok = token.token
  if block_ends[tok] then
    return true
  elseif tok == "until" then
    return with_until
  else
    return false
  end
end

--- Read a list of Statements
--- `stat_list -> { stat [';'] }`
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
---@return AstExpression
---@return AstTokenNode open_token @ `[` token
---@return AstTokenNode close_token @ `]` token
local function y_index(scope) -- TODO: find a better word for y. I think it's just to prevent use of duplicate names right now
  local open_token = new_token_node()
  next_token()
  local e = expr(scope)
  local close_token = new_token_node()
  assert_match("]", "[", open_token.line)
  return e, open_token, close_token
end

--- Table Constructor record field
---@param scope AstScope
---@return AstRecordField
local function rec_field(scope)
  local field = {type = "rec"}
  if token.token == "ident" then
    field.key = new_node("string")
    field.key.value = token.value
    field.key.src_is_ident = true
    next_token()
  else
    field.key, field.key_open_token, field.key_close_token = y_index(scope)
  end
  field.eq_token = new_token_node()
  assert_next("=")
  field.value = expr(scope)
  return field
end

--- Table Constructor list field
---@param scope AstScope
---@return AstListField
local function list_field(scope)
  return {type="list",value=expr(scope)}
end

--- Table Constructor field
--- `field -> list_field | rec_field`
---@param scope AstScope
---@return AstField
local function field(scope)
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
---@return AstConstructor
local function constructor(scope)
  local line = token.line
  local node = new_node("constructor")
  node.fields = {}
  node.open_paren_token = new_token_node()
  node.comma_tokens = {}
  assert_next("{")
  while token.token ~= "}" do
    node.fields[#node.fields+1] = field(scope)
    if test_next(",") or test_next(";") then
      node.comma_tokens[#node.comma_tokens+1] = new_token_node(true)
    else
      break
    end
  end
  node.close_paren_token = new_token_node()
  assert_match("}","{",line)
  return node
end

--- Function Definition Parameter List
---@param scope AstFunctionDef
---@return number number of parameters matched
local function par_list(scope)
  -- param_list -> [ param { `,' param } ]
  if token.token == ")" then
    return 0
  end
  while true do
    if token.token == "ident" then
      token.token = "local"
      scope.locals[#scope.locals+1] = {name = token, whole_block = true}
      next_token()
    elseif token.token == "..." then
      scope.is_vararg = true
      next_token()
      return #scope.locals
    else
      syntax_error("<name> or '...' expected")
    end
    if test_next(",") then
      scope.param_comma_tokens[#scope.param_comma_tokens+1] = new_token_node(true)
    else
      break
    end
  end
  return #scope.locals
end

--- Function Definition
---@param function_token AstTokenNode
---@param scope AstScope
---@param is_method boolean Insert the extra first parameter `self`
---@return AstFuncProto
local function body(function_token, scope, is_method)
  -- body -> `(` param_list `)`  block END
  local parent = {type = "upval", scope = scope}
  ---@narrow scope AstScope|AstFunctionDef
  while not scope.func_protos do
    scope = scope.parent.scope
  end
  ---@narrow scope AstFunctionDef
  local ref_node = new_node("functiondef")
  ref_node.source = scope.source
  ref_node.is_method = is_method
  ref_node.func_protos = {}
  ref_node.locals = {}
  ref_node.upvals = {}
  ref_node.constants = {}
  ref_node.labels = {}
  ref_node.param_comma_tokens = {}
  ref_node.parent = parent
  if is_method then
    ref_node.locals[1] = {name = {token="self",value="self"}, whole_block = true}
  end
  ref_node.open_paren_token = new_token_node()
  local this_tok = new_node("func_proto")
  this_tok.ref = ref_node
  this_tok.function_token = function_token
  assert_next("(")
  ref_node.n_params = par_list(ref_node)
  ref_node.close_paren_token = new_token_node()
  assert_next(")")
  ref_node.body = stat_list(ref_node)
  ref_node.end_line = token.line
  ref_node.end_column = token.column + 3
  ref_node.end_token = new_token_node()
  assert_match("end", "function", function_token.line)
  scope.func_protos[#scope.func_protos+1] = ref_node
  return this_tok
end

--- Expression List
---@param scope AstScope
---@return AstExpression[] expression_list
---@return AstTokenNode[] comma_tokens @ length is `#expression_list - 1`
local function exp_list(scope)
  local el = {(expr(scope))}
  local comma_tokens = {}
  while test_next(",") do
    comma_tokens[#comma_tokens+1] = new_token_node(true)
    el[#el+1] = expr(scope)
  end
  return el, comma_tokens
end

--- Function Arguments
---@param node AstCall|AstSelfCall
---@param scope AstScope
---@return Token[]
local function func_args(node, scope)
  return (({
    ["("] = function(scope)
      node.open_paren_token = new_token_node()
      next_token()
      if token.token == ")" then
        next_token()
        return {}
      end
      local el = exp_list(scope)
      node.close_paren_token = new_token_node()
      assert_match(")","(",node.line)
      return el
    end,
    ["string"] = function(scope)
      token.leading = leading
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
    local open_paren_token = new_token_node()
    next_token() -- skip '('
    --TODO: compact lambda here:
    -- token is ')', empty args expect `'=>' expr` next
    -- token is 'ident'
    --  followed by `,` is multiple args, finish list then `=> expr`
    --  followed by `)` `=>` is single arg, expect `expr_list`
    --  followed by `)` or anything else is expr of inner, current behavior
    local ex = expr(scope)
    local close_paren_token = new_token_node()
    assert_match(")","(",open_paren_token.line)
    ex.src_paren_wrappers = ex.src_paren_wrappers or {}
    table.insert(ex.src_paren_wrappers, 1, {
      open_paren_token = open_paren_token,
      close_paren_token = close_paren_token,
    })
    return ex
  elseif token.token == "ident" then
    return check_ref(scope)
  else
    syntax_error("Unexpected symbol '" .. token.token .. "'")
  end
end

local suffixed_tab = {
  ["."] = function(ex)
    local node = new_node("index")
    node.ex = ex
    node.dot_token = new_token_node()
    next_token() -- skip '.'
    node.suffix = assert_name()
    node.suffix.token = "string"
    node.suffix.src_is_ident = true
    return node
  end,
  ["["] = function(ex,scope)
    local node = new_node("index")
    node.ex = ex
    node.suffix, node.suffix_open_token, node.suffix_close_token = y_index(scope)
    return node
  end,
  [":"] = function(ex,scope)
    local node = new_node("selfcall")
    node.ex = ex
    node.colon_token = new_token_node()
    next_token() -- skip ':'
    node.suffix = assert_name()
    node.suffix.token = "string"
    node.suffix.src_is_ident = true
    node.args = func_args(node, scope)
    return node
  end,
  ["("] = function(ex,scope)
    local node = new_node("call")
    node.ex = ex
    node.args = func_args(node, scope)
    return node
  end,
  ["string"] = function(ex,scope)
    local node = new_node("call")
    node.ex = ex
    node.args = func_args(node, scope)
    return node
  end,
  ["{"] = function(ex,scope)
    local node = new_node("call")
    node.ex = ex
    node.args = func_args(node, scope)
  end,
}

--- Suffixed Expression
---@param scope AstScope
---@return Token
local function suffixed_exp(scope)
  -- suffixed_exp ->
  --   primary_exp { '.' NAME | '[' exp ']' | ':' NAME func_args | func_args }
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

local simple_tokens = invert{"number","string","nil","true","false","..."}

--- Simple Expression
---@param scope AstScope
---@return Token
local function simple_exp(scope)
  -- simple_exp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
  --              constructor | FUNCTION body | suffixed_exp
  if simple_tokens[token.token] then
    local node = token
    node.leading = leading
    next_token() --consume it
    return node
  end

  if token.token == "{" then
    return constructor(scope)
  elseif test_next("function") then
    return body(new_token_node(true), scope)
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

--- sub_expression
--- `sub_expr -> (simple_exp | unop sub_expr) { binop sub_expr }`
--- where `binop' is any binary operator with a priority higher than `limit'
---@param limit number
---@param scope AstScope
---@return AstExpression completed
---@return string next_op
local function sub_expr(limit,scope)
  local node
  do
    local prio = unop_prio[token.token]
    if prio then
      node = new_node("unop")
      node.op = token.token
      node.op_token = new_token_node()
      next_token() -- consume unop
      node.sub = sub_expr(prio, scope)
    else
      node = simple_exp(scope)
    end
  end
  local binop = token.token
  local prio = binop_prio[binop]
  while prio and prio.left > limit do
    local op_token = new_token_node()
    next_token() -- consume `binop`
    local right_node, next_op = sub_expr(prio.right,scope)
    if binop == ".." then
      if right_node.token == "concat" then
        -- TODO: add start and end locations within the exp_list for src_paren_wrappers
        ---@narrow right_node AstConcat
        table.insert(right_node.exp_list, 1, node)
        node = right_node
        table.insert(node.op_tokens, 1, op_token)
      elseif node.token == "concat" then
        ---@narrow node AstConcat
        node.exp_list[#node.exp_list+1] = right_node
        node.op_tokens[#node.op_tokens+1] = op_token
      else
        local left_node = node
        node = new_node("concat")
        node.exp_list = {left_node, right_node}
        node.op_tokens = {op_token}
      end
    else
      local left_node = node
      node = new_node("binop")
      node.op = binop
      node.op_token = op_token
      node.left = left_node
      node.right = right_node
    end
    binop = next_op
    prio = binop_prio[binop]
  end
  return node, binop
end

--- Expression
---@param scope AstScope
---@return Token completed
---@return string next_op
function expr(scope)
  return sub_expr(0,scope)
end

--- Assignment Statement
---@param lhs AstExpression[]
---@param lhs_comma_tokens AstTokenNode[]
---@param scope AstScope
---@return AstAssignment
local function assignment(lhs, lhs_comma_tokens, scope)
  if test_next(",") then
    lhs_comma_tokens[#lhs_comma_tokens+1] = new_token_node(true)
    lhs[#lhs+1] = suffixed_exp(scope)
    return assignment(lhs, lhs_comma_tokens, scope)
  else
    assert_next("=")
    local this_tok = new_node("assignment")
    this_tok.eq_token = new_token_node(true)
    this_tok.lhs = lhs
    this_tok.lhs_comma_tokens = lhs_comma_tokens
    this_tok.rhs, this_tok.rhs_comma_tokens = exp_list(scope)
    return this_tok
  end
end

--- Label Statement
---@param scope AstScope
---@return AstLabel
local function label_stat(scope)
  local open_token = new_token_node()
  next_token() -- skip "::"
  local label = assert_name()
  label.open_token = open_token
  label.close_token = new_token_node()
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
--- `whilestat -> WHILE condition DO block END`
---@param line number
---@param scope AstScope
---@return Token
local function while_stat(line,scope)
  local this_tok = new_node("whilestat")
  this_tok.locals = {}
  this_tok.labels = {}
  this_tok.parent = {type = "local", scope = scope}
  this_tok.while_token = new_token_node()
  next_token() -- skip WHILE
  this_tok.condition = expr(this_tok)
  this_tok.do_token = new_token_node()
  assert_next("do")
  this_tok.body = stat_list(this_tok)
  this_tok.end_token = new_token_node()
  assert_match("end","while",line)
  return this_tok
end

--- Repeat Statement
--- `repeatstat -> REPEAT block UNTIL condition`
---@param line number
---@param scope AstScope
---@return Token
local function repeat_stat(line,scope)
  local this_tok = new_node("repeatstat")
  this_tok.locals = {}
  this_tok.labels = {}
  this_tok.parent = {type = "local", scope = scope}
  this_tok.repeatstat = new_token_node()
  next_token() -- skip REPEAT
  this_tok.body = stat_list(this_tok)
  this_tok.until_token = new_token_node()
  assert_match("until","repeat",line)
  this_tok.condition = expr(this_tok)
  return this_tok
end

--- Numeric For Statement
--- `fornum -> NAME = exp1,exp1[,exp1] DO block`
---@param first_name Token
---@param scope AstScope
---@return Token
local function for_num(first_name,scope)
  local this_tok = new_node("fornum")
  this_tok.var = first_name
  this_tok.locals = {{name = first_name, whole_block = true}}
  this_tok.labels = {}
  this_tok.parent = {type = "local", scope = scope}
  this_tok.eq_token = new_token_node()
  assert_next("=")
  this_tok.start = expr(scope)
  this_tok.first_comma_token = new_token_node()
  assert_next(",")
  this_tok.stop = expr(scope)
  this_tok.step = {token="number", value=1}
  if test_next(",") then
    this_tok.second_comma_token = new_token_node(true)
    this_tok.step = expr(scope)
  end
  this_tok.do_token = new_token_node()
  assert_next("do")
  this_tok.body = stat_list(this_tok)
  return this_tok
end

--- Generic For Statement
--- `forlist -> NAME {,NAME} IN exp_list DO block`
---@param first_name Token
---@param scope AstScope
---@return Token
local function for_list(first_name,scope)
  local nl = {first_name}
  local this_tok = new_node("forlist")
  this_tok.name_list = nl
  this_tok.locals = {{name = first_name, whole_block = true}}
  this_tok.labels = {}
  this_tok.parent = {type = "local", scope = scope}
  this_tok.comma_tokens = {}
  while test_next(",") do
    this_tok.comma_tokens[#this_tok.comma_tokens+1] = new_token_node(true)
    local name = assert_name()
    name.token = "local"
    this_tok.locals[#this_tok.locals+1] =
      {name = name, whole_block = true}
    nl[#nl+1] = name
  end
  this_tok.in_token = new_token_node()
  assert_next("in")
  this_tok.exp_list, this_tok.exp_list_comma_tokens = exp_list(scope)
  this_tok.do_token = new_token_node()
  assert_next("do")
  this_tok.body = stat_list(this_tok)
  return this_tok
end

--- For Statement
--- `for_stat -> FOR (fornum | forlist) END`
---@param line number
---@param parent AstScope
---@return Token
local function for_stat(line,parent)
  local for_token = new_token_node()
  next_token() -- skip FOR
  local first_name = assert_name()
  first_name.token = "local"
  local t = token.token
  local for_node
  if t == "=" then
    for_node = for_num(first_name,parent)
  elseif t == "," or t == "in" then
    for_node = for_list(first_name,parent)
  else
    syntax_error("'=', ',' or 'in' expected")
  end
  for_node.for_token = for_token
  for_node.end_token = new_token_node()
  assert_match("end","for",line)
  return for_node
end


local function test_then_block(scope)
  -- test_then_block -> [IF | ELSEIF] condition THEN block
  --TODO: [IF | ELSEIF] ( condition | name_list '=' exp_list  [';' condition] ) THEN block
  -- if first token is ident, and second is ',' or '=', use if-init, else original parse
  -- if no condition in if-init, first name/expr is used
  local this_tok = new_node("testblock")
  this_tok.locals = {}
  this_tok.labels = {}
  this_tok.parent = {type = "local", scope = scope}
  this_tok.if_token = new_token_node()
  next_token() -- skip IF or ELSEIF
  this_tok.condition = expr(this_tok)
  this_tok.then_token = new_token_node()
  assert_next("then")
  this_tok.body = stat_list(this_tok)
  return this_tok
end

local function if_stat(line,scope)
  -- ifstat -> IF condition THEN block {ELSEIF condition THEN block} [ELSE block] END
  local this_tok = new_node("ifstat")
  this_tok.ifs = {}
  repeat
    this_tok.ifs[#this_tok.ifs+1] = test_then_block(scope)
  until token.token ~= "elseif"
  if test_next("else") then
    local else_block = new_node("elseblock")
    this_tok.elseblock = else_block
    else_block.locals = {}
    else_block.labels = {}
    else_block.parent = {type = "local", scope = scope}
    else_block.else_token = new_token_node(true)
    else_block.body = stat_list(else_block)
  end
  this_tok.end_token = new_token_node()
  assert_match("end","if",line)
  return
end

local function local_func(local_token, function_token, scope)
  local name = assert_name()
  name.token = "local"
  local this_local = {name = name}
  scope.locals[#scope.locals+1] = this_local
  local b = body(function_token, scope)
  b.token = "localfunc"
  b.local_token = local_token
  b.name = name
  this_local.start_before = b
  return b
end

local function local_stat(local_token, scope)
  -- stat -> LOCAL NAME {`,' NAME} [`=' exp_list]
  local lhs = {}
  local this_tok = new_node("localstat")
  ---@narrow this_tok AstLocalStat
  this_tok.local_token = local_token
  this_tok.lhs = lhs
  local lhs_comma_tokens = {}
  this_tok.lhs_comma_tokens = lhs_comma_tokens
  local function test_comma()
    if test_next(",") then
      lhs_comma_tokens[#lhs_comma_tokens+1] = new_token_node(true)
      return true
    end
    return false
  end
  repeat
    local name = assert_name()
    name.token = "local"
    lhs[#lhs+1] = name
  until not test_comma()
  if test_next("=") then
    this_tok.eq_token = new_token_node(true)
    this_tok.line = this_tok.eq_token.line
    this_tok.column = this_tok.eq_token.column
    this_tok.leading = this_tok.eq_token.leading
    this_tok.rhs, this_tok.rhs_comma_tokens = exp_list(scope)
  end
  for _,name in ipairs(this_tok.lhs) do
    scope.locals[#scope.locals+1] = {name = name, start_after = this_tok}
  end
  return this_tok
end

---@param scope AstScope
---@return boolean
---@return AstExpression[] names
---@return AstTokenNode[] dot_tokens @ length is `#names - 1`
local function func_name(scope)
  -- func_name -> NAME {field_selector} [`:' NAME]
  -- TODO: field_selector? i think that's already an extension from regular Lua

  local names = { check_ref(scope) }
  local dot_tokens = {}

  while test_next(".") do
    dot_tokens[#dot_tokens+1] = new_token_node(true)
    names[#names+1] = assert_name()
  end

  if test_next(":") then
    dot_tokens[#dot_tokens+1] = new_token_node(true)
    names[#names+1] = assert_name()
    return true, names, dot_tokens
  end

  return false, names, dot_tokens
end

local function func_stat(line,scope)
  -- funcstat -> FUNCTION func_name body
  local function_token = new_token_node()
  next_token() -- skip FUNCTION
  local is_method, names, dot_tokens = func_name(scope)
  local b = body(function_token, scope, is_method)
  b.token = "funcstat"
  b.names = names
  b.dot_tokens = dot_tokens
  return b
end

local function expr_stat(scope)
  -- stat -> func | assignment
  local first_exp = suffixed_exp(scope)
  if token.token == "=" or token.token == "," then
    -- stat -> assignment
    return assignment({first_exp}, {}, scope)
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
  -- stat -> RETURN [exp_list] [';']
  local this_tok = new_node("retstat")
  this_tok.return_token = new_token_node()
  next_token() -- skip "return"
  if block_follow(true) then
    -- return no values
  elseif token.token == ";" then
    -- also return no values
    this_tok.semi_colon_token = new_token_node()
    next_token()
  else
    this_tok.exp_list, this_tok.exp_list_comma_tokens = exp_list(scope)
  end
  return this_tok
end

local statement_lut = {
  [";"] = function(scope) -- stat -> ';' (empty statement)
    local this_tok = new_node("empty")
    this_tok.semi_colon_token = new_token_node()
    next_token() -- skip
    return this_tok
  end,
  ["if"] = function(scope) -- stat -> ifstat
    return if_stat(token.line,scope)
  end,
  ["while"] = function(scope) -- stat -> whilestat
    return while_stat(token.line,scope)
  end,
  ["do"] = function(scope) -- stat -> DO block END
    local line = token.line
    local do_stat = new_node("dostat")
    do_stat.locals = {}
    do_stat.labels = {}
    do_stat.parent = {type = "local", scope = scope}
    do_stat.do_token = new_token_node()
    next_token() -- skip "do"
    do_stat.body = stat_list(do_stat)
    do_stat.end_token = new_token_node()
    assert_match("end","do",line)
    return do_stat
  end,
  ["for"] = function(scope) -- stat -> for_stat
    return for_stat(token.line,scope)
  end,
  ["repeat"] = function(scope) -- stat -> repeatstat
    return repeat_stat(token.line, scope)
  end,
  ["function"] = function(scope) -- stat -> funcstat
    return func_stat(token.line, scope)
  end,
  ["local"] = function(scope) -- stat -> localstat
    local local_token_node = new_token_node()
    next_token() -- skip "local"
    if test_next("function") then
      return local_func(local_token_node, new_token_node(true), scope)
    else
      return local_stat(local_token_node, scope)
    end
  end,
  ["::"] = function(scope) -- stat -> label
    return label_stat(scope)
  end,
  ["return"] = function(scope) -- stat -> retstat
    return ret_stat(scope)
  end,

  ["break"] = function(scope) -- stat -> breakstat
    local this_tok = new_node("breakstat")
    this_tok.break_token = new_token_node()
    next_token() -- skip BREAK
    return this_tok
  end,
  ["goto"] = function(scope) -- stat -> 'goto' NAME
    local this_tok = new_node("gotostat")
    this_tok.goto_token = new_token_node()
    next_token() -- skip GOTO
    this_tok.target = assert_name()
    return this_tok
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
          {name = {token="_ENV",value="_ENV"}, whole_block = true}
        }
      }
    },
    func_protos = {},
    body = false, -- list body before locals
    is_vararg = true, -- main is always vararg
    locals = {}, upvals = {}, constants = {}, labels = {},

    is_method = false,
    line = 0,
    end_line = 0,
    column = 0,
    end_column = 0,
    n_params = 0,
  }
  main.body = stat_list(main)
  main.eof_token = new_token_node()
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