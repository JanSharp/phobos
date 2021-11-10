
local ast = require("ast_util")
local invert = require("invert")
local ill = require("indexed_linked_list")

local token ---@type Token
---set by test_next() and therefore also assert_next() and assert_match()
local prev_token ---@type Token
local next_token
local peek_token
----------------------------------------------------------------------


local statement, expr

---TODO: make the right object in the error message the focus, the thing that is actually wrong.
---for example when an assertion of some token failed, it's most likely not that token that
---is missing (like a closing }), but rather the actual token that was encountered that was unexpected
---Throw a Syntax Error at the current location
---@param msg string Error message
local function syntax_error(msg)
  error(msg.." near '"..token.token_type.."'"..(
    token.token_type ~= "eof"
      and (" at "..token.line..":"..token.column)
      or ""
    )
  )
end

---@param node_type AstNodeType
---@param use_prev? boolean @ indicates if this node was created for the current or previous token (unused)
local function new_node(node_type, use_prev)
  return ast.new_node(node_type)
end

---create new AstNode using the current or previous `token`
---@param node_type AstNodeType
---@param use_prev? boolean @ should this node be created using `prev_token`?
local function new_full_node(node_type, use_prev)
  local node = new_node(node_type, use_prev)
  node.line = (use_prev and prev_token or token).line
  node.column = (use_prev and prev_token or token).column
  node.leading = (use_prev and prev_token or token).leading
  return node
end

--- Check that the current token is an "ident" token, and if so consume and return it.
---@return Token ident_token
local function assert_ident()
  if token.token_type ~= "ident" then
    syntax_error("<name> expected")
  end
  local ident = token
  next_token()
  return ident
end

---@param use_prev? boolean @ should this node be created using `prev_token`?
---@param value? string @ Default: `(use_prev and prev_token.token_type or token.token_type)`
---@return AstTokenNode
local function new_token_node(use_prev, value)
  local node = new_full_node("token", use_prev)
  node.value = value or (use_prev and prev_token.token_type or token.token_type)
  return node
end

--- Check if the next token is a `tok` token, and if so consume it. Returns the result of the test.
---@param tok TokenType
---@return boolean
local function test_next(tok)
  if token.token_type == tok then
    prev_token = token
    next_token()
    return true
  end
  return false
end

---Check if the next token is a `tok` token, and if so consume it.
---Throws a syntax error if token does not match.
---@param tok string
local function assert_next(tok)
  if not test_next(tok) then
    syntax_error("'" .. tok .. "' expected")
  end
end

--- Check for the matching `close` token to a given `open` token
---@param open_token AstTokenNode
---@param close string
local function assert_match(open_token, close)
  if not test_next(close) then
    syntax_error("'"..close.."' expected (to close '"..open_token.value
      .."' at "..open_token.line..":"..open_token.column..")"
    )
  end
end

local block_ends = invert{"else", "elseif", "end", "eof"}

--- Test if the next token closes a block
---@param with_until boolean if true, "until" token will count as closing a block
---@return boolean
local function block_follow(with_until)
  if block_ends[token.token_type] then
    return true
  elseif token.token_type == "until" then
    return with_until
  else
    return false
  end
end

--- Read a list of Statements
--- `stat_list -> { stat [';'] }`
---@param scope AstScope
---@return AstStatementList
local function stat_list(scope)
  local sl = ill.new()
  sl.scope = scope
  local stop
  while not block_follow(true) do
    if token.token_type == "eof" then
      break
    elseif token.token_type == "return" then
      stop = true
    end
    local stat_elem = ill.append(sl)
    stat_elem.value = statement(scope, stat_elem)
    if stop then
      break
    end
  end
  return sl
end

--- `index -> '[' expr ']'`
---@param scope AstScope
---@return AstExpression
---@return AstTokenNode open_token @ `[` token
---@return AstTokenNode close_token @ `]` token
local function index_expr(scope, stat_elem)
  local open_token = new_token_node()
  next_token()
  local e = expr(scope, stat_elem)
  local close_token = new_token_node()
  assert_match(open_token, "]")
  return e, open_token, close_token
end

--- Table Constructor record field
---@param scope AstScope
---@return AstRecordField
local function rec_field(scope, stat_elem)
  local field = {type = "rec"}
  if token.token_type == "ident" then
    field.key = new_full_node("string")
    field.key.stat_elem = stat_elem
    field.key.value = token.value
    field.key.src_is_ident = true
    next_token()
  else
    field.key, field.key_open_token, field.key_close_token = index_expr(scope, stat_elem)
  end
  field.eq_token = new_token_node()
  assert_next("=")
  field.value = expr(scope, stat_elem)
  return field
end

--- Table Constructor list field
---@param scope AstScope
---@return AstListField
local function list_field(scope, stat_elem)
  return {type = "list", value = expr(scope, stat_elem)}
end

--- Table Constructor field
--- `field -> list_field | rec_field`
---@param scope AstScope
---@return AstField
local function field(scope, stat_elem)
  return (({
    ["ident"] = function()
      local peek_tok = peek_token()
      if peek_tok.token_type ~= "=" then
        return list_field(scope, stat_elem)
      else
        return rec_field(scope, stat_elem)
      end
    end,
    ["["] = rec_field,
  })[token.token_type] or list_field)(scope, stat_elem)
end

--- Table Constructor
--- `constructor -> '{' [ field { sep field } [sep] ] '}'`
--- `sep -> ',' | ';'`
---@param scope AstScope
---@return AstConstructor
local function constructor(scope, stat_elem)
  local node = new_node("constructor")
  node.stat_elem = stat_elem
  node.fields = {}
  node.open_token = new_token_node()
  node.comma_tokens = {}
  assert_next("{")
  while token.token_type ~= "}" do
    node.fields[#node.fields+1] = field(scope, stat_elem)
    if test_next(",") or test_next(";") then
      node.comma_tokens[#node.comma_tokens+1] = new_token_node(true)
    else
      break
    end
  end
  node.close_token = new_token_node()
  assert_match(node.open_token, "}")
  return node
end

--- Function Definition Parameter List
---@param scope AstFunctionDef
---@return number number of parameters matched
local function par_list(scope, stat_elem)
  -- param_list -> [ param { `,' param } ]
  local params = {}
  if token.token_type == ")" then
    return params
  end
  while true do
    if test_next("ident") then
      local param_def
      param_def, params[#params+1] = ast.create_local(prev_token, stat_elem)
      param_def.whole_block = true
      scope.locals[#scope.locals+1] = param_def
    elseif token.token_type == "..." then
      scope.is_vararg = true
      scope.vararg_token = new_token_node()
      next_token()
      return params
    else
      syntax_error("<name> or '...' expected")
    end
    if test_next(",") then
      scope.param_comma_tokens[#scope.param_comma_tokens+1] = new_token_node(true)
    else
      break
    end
  end
  return params
end

--- Function Definition
---@param function_token AstTokenNode
---@param scope AstScope|AstFunctionDef
---@param is_method boolean Insert the extra first parameter `self`
---@param on_func_proto_created fun(func_proto: AstFuncProto)
---@return AstFuncProto
local function body(function_token, scope, is_method, stat_elem, on_func_proto_created)
  -- body -> `(` param_list `)`  block END
  local parent_scope = scope
  -- ---@narrow scope AstScope|AstFunctionDef
  while scope.node_type ~= "functiondef" do
    scope = scope.parent_scope
  end
  -- ---@narrow scope AstFunctionDef
  local func_def_node = new_node("functiondef")
  func_def_node.stat_elem = stat_elem
  func_def_node.source = scope.source
  func_def_node.is_method = is_method
  func_def_node.func_protos = {}
  func_def_node.locals = {}
  func_def_node.upvals = {}
  func_def_node.labels = {}
  func_def_node.param_comma_tokens = {}
  func_def_node.parent_scope = parent_scope
  if is_method then
    local self_local = ast.create_local_def("self")
    self_local.whole_block = true
    self_local.src_is_method_self = true
    func_def_node.locals[1] = self_local
  end
  func_def_node.function_token = function_token
  func_def_node.open_paren_token = new_token_node()
  local this_node = new_node("func_proto")
  if on_func_proto_created then
    on_func_proto_created(this_node)
  end
  this_node.stat_elem = stat_elem
  this_node.func_def = func_def_node
  assert_next("(")
  func_def_node.params = par_list(func_def_node, stat_elem)
  func_def_node.close_paren_token = new_token_node()
  assert_next(")")
  func_def_node.body = stat_list(func_def_node)
  func_def_node.end_token = new_token_node()
  assert_match(function_token, "end")
  scope.func_protos[#scope.func_protos+1] = func_def_node
  return this_node
end

--- Expression List
---@param scope AstScope
---@return AstExpression[] expression_list
---@return AstTokenNode[] comma_tokens @ length is `#expression_list - 1`
local function exp_list(scope, stat_elem)
  local el = {(expr(scope, stat_elem))}
  local comma_tokens = {}
  while test_next(",") do
    comma_tokens[#comma_tokens+1] = new_token_node(true)
    el[#el+1] = expr(scope, stat_elem)
  end
  return el, comma_tokens
end

--- Function Arguments
---@param node AstCall|AstSelfCall
---@param scope AstScope
---@return Token[]
local function func_args(node, scope, stat_elem)
  return (({
    ["("] = function()
      node.open_paren_token = new_token_node()
      next_token()
      if token.token_type == ")" then
        node.close_paren_token = new_token_node()
        next_token()
        return {}
      end
      local el, comma_tokens = exp_list(scope, stat_elem)
      node.close_paren_token = new_token_node()
      assert_match(node.open_paren_token, ")")
      return el, comma_tokens
    end,
    ["string"] = function()
      local string_node = new_full_node("string")
      string_node.stat_elem = stat_elem
      string_node.value = token.value
      string_node.src_is_block_str = token.src_is_block_str
      string_node.src_quote = token.src_quote
      string_node.src_value = token.src_value
      string_node.src_has_leading_newline = token.src_has_leading_newline
      string_node.src_pad = token.src_pad
      local el = {string_node}
      next_token()
      return el, {}
    end,
    ["{"] = function()
      return {(constructor(scope, stat_elem))}, {}
    end,
  })[token.token_type] or function()
    syntax_error("Expected function arguments")
  end)()
end

--- Primary Expression
---@param scope AstScope
---@return Token
local function primary_exp(scope, stat_elem)
  if token.token_type == "(" then
    local open_paren_token = new_token_node()
    next_token() -- skip '('
    --TODO: compact lambda here:
    -- token_type is ')', empty args expect `'=>' expr` next
    -- token_type is 'ident'
    --  followed by `,` is multiple args, finish list then `=> expr`
    --  followed by `)` `=>` is single arg, expect `expr_list`
    --  followed by `)` or anything else is expr of inner, current behavior
    local ex = expr(scope, stat_elem)
    local close_paren_token = new_token_node()
    assert_match(open_paren_token, ")")
    ex.force_single_result = true
    ex.src_paren_wrappers = ex.src_paren_wrappers or {}
    ex.src_paren_wrappers[#ex.src_paren_wrappers+1] = {
      open_paren_token = open_paren_token,
      close_paren_token = close_paren_token,
    }
    return ex
  elseif token.token_type == "ident" then
    local ident = assert_ident()
    return ast.get_ref(scope, stat_elem, ident.value, ident)
  else
    syntax_error("Unexpected symbol '" .. token.token_type .. "'")
  end
end

local suffixed_lut = {
  ["."] = function(ex, scope, stat_elem)
    local node = new_node("index")
    node.ex = ex
    node.dot_token = new_token_node()
    next_token() -- skip '.'
    local ident = assert_ident()
    node.suffix = ast.copy_node(ident, "string")
    node.suffix.value = ident.value
    node.suffix.stat_elem = stat_elem
    node.suffix.src_is_ident = true
    return node
  end,
  ["["] = function(ex, scope, stat_elem)
    local node = new_node("index")
    node.ex = ex
    node.suffix, node.suffix_open_token, node.suffix_close_token = index_expr(scope, stat_elem)
    return node
  end,
  [":"] = function(ex, scope, stat_elem)
    local node = new_node("selfcall")
    node.ex = ex
    node.colon_token = new_token_node()
    next_token() -- skip ':'
    local ident = assert_ident()
    node.suffix = ast.copy_node(ident, "string")
    node.suffix.value = ident.value
    node.suffix.src_is_ident = true
    node.args, node.args_comma_tokens = func_args(node, scope, stat_elem)
    return node
  end,
  ["("] = function(ex, scope, stat_elem)
    local node = new_node("call")
    node.ex = ex
    node.args, node.args_comma_tokens = func_args(node, scope, stat_elem)
    return node
  end,
  ["string"] = function(ex, scope, stat_elem)
    local node = new_node("call")
    node.ex = ex
    node.args, node.args_comma_tokens = func_args(node, scope, stat_elem)
    return node
  end,
  ["{"] = function(ex, scope, stat_elem)
    local node = new_node("call")
    node.ex = ex
    node.args, node.args_comma_tokens = func_args(node, scope, stat_elem)
    return node
  end,
}

--- Suffixed Expression
---@param scope AstScope
---@return AstExpression
local function suffixed_exp(scope, stat_elem)
  -- suffixed_exp ->
  --   primary_exp { '.' NAME | '[' exp ']' | ':' NAME func_args | func_args }
  --TODO: safe chaining adds optional '?' in front of each suffix
  local ex = primary_exp(scope, stat_elem)
  local should_break = false
  repeat
    ex = ((suffixed_lut)[token.token_type] or function(ex)
      should_break = true
      return ex
    end)(ex, scope, stat_elem)
    ex.stat_elem = stat_elem
  until should_break
  return ex
end

---value is set outside, for all of them
local simple_lut = {
  ["number"] = function()
    local node = new_full_node("number")
    node.src_value = token.src_value
    return node
  end,
  ["string"] = function()
    local node = new_full_node("string")
    node.src_is_block_str = token.src_is_block_str
    node.src_quote = token.src_quote
    node.src_value = token.src_value
    node.src_has_leading_newline = token.src_has_leading_newline
    node.src_pad = token.src_pad
    return node
  end,
  ["nil"] = function()
    return new_full_node("nil")
  end,
  ["true"] = function()
    return new_full_node("boolean")
  end,
  ["false"] = function()
    return new_full_node("boolean")
  end,
  ["..."] = function(scope)
    while scope.node_type ~= "functiondef" do
      scope = scope.parent_scope
    end
    if not scope.is_vararg then
      syntax_error("Cannot use '...' outside a vararg function")
    end
    return new_full_node("vararg")
  end,
}

--- Simple Expression
---@param scope AstScope
---@return Token
local function simple_exp(scope, stat_elem)
  -- simple_exp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
  --              constructor | FUNCTION body | suffixed_exp
  if simple_lut[token.token_type] then
    local node = simple_lut[token.token_type](scope)
    node.stat_elem = stat_elem
    node.value = token.value
    next_token() --consume it
    return node
  end

  if token.token_type == "{" then
    return constructor(scope, stat_elem)
  elseif test_next("function") then
    return body(new_token_node(true), scope, false, stat_elem)
  else
    return suffixed_exp(scope, stat_elem)
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
local function sub_expr(limit, scope, stat_elem)
  local node
  do
    local prio = unop_prio[token.token_type]
    if prio then
      node = new_node("unop")
      node.stat_elem = stat_elem
      node.op = token.token_type
      node.op_token = new_token_node()
      next_token() -- consume unop
      node.ex = sub_expr(prio, scope, stat_elem)
    else
      node = simple_exp(scope, stat_elem)
    end
  end
  local binop = token.token_type
  local prio = binop_prio[binop]
  while prio and prio.left > limit do
    local op_token = new_token_node()
    next_token() -- consume `binop`
    ---@type AstExpression|AstConcat
    local right_node, next_op = sub_expr(prio.right, scope, stat_elem)
    if binop == ".." then
      if right_node.node_type == "concat" then
        -- TODO: add start and end locations within the exp_list for src_paren_wrappers
        -- ---@narrow right_node AstConcat
        table.insert(right_node.exp_list, 1, node)
        node = right_node
        table.insert(node.op_tokens, 1, op_token)
      elseif node.node_type == "concat" then
        -- ---@narrow node AstConcat
        node.exp_list[#node.exp_list+1] = right_node
        node.op_tokens[#node.op_tokens+1] = op_token
      else
        local left_node = node
        node = new_node("concat", true)
        node.stat_elem = stat_elem
        node.exp_list = {left_node, right_node}
        node.op_tokens = {op_token}
      end
    else
      local left_node = node
      node = new_node("binop", true)
      node.stat_elem = stat_elem
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
function expr(scope, stat_elem)
  return sub_expr(0, scope, stat_elem)
end

--- Assignment Statement
---@param lhs AstExpression[]
---@param lhs_comma_tokens AstTokenNode[]
---@param scope AstScope
---@return AstAssignment
local function assignment(lhs, lhs_comma_tokens, scope, stat_elem)
  if test_next(",") then
    lhs_comma_tokens[#lhs_comma_tokens+1] = new_token_node(true)
    lhs[#lhs+1] = suffixed_exp(scope, stat_elem)
    return assignment(lhs, lhs_comma_tokens, scope, stat_elem)
  else
    assert_next("=")
    local this_tok = new_node("assignment")
    this_tok.eq_token = new_token_node(true)
    this_tok.lhs = lhs
    this_tok.lhs_comma_tokens = lhs_comma_tokens
    this_tok.rhs, this_tok.rhs_comma_tokens = exp_list(scope, stat_elem)
    return this_tok
  end
end

--- Label Statement
---@param scope AstScope
---@return AstLabel
local function label_stat(scope, stat_elem)
  local open_token = new_token_node()
  next_token() -- skip "::"
  local name_token = new_token_node()
  name_token.value = nil
  local ident = assert_ident()
  local label = new_node("label")
  label.stat_elem = stat_elem
  label.name = ident.value
  label.open_token = open_token
  label.name_token = name_token
  label.close_token = new_token_node()
  assert_next("::")
  local prev_label = scope.labels[label.name]
  if prev_label then
    error("Duplicate label '" .. label.name .. "' at "
      .. label.line .. ":" .. label.column ..
      " previously defined at "
      .. prev_label.line .. ":" .. prev_label.column)
  else
    scope.labels[label.name] = label
  end
  return label
end

--- While Statement
--- `whilestat -> WHILE condition DO block END`
---@param scope AstScope
---@return Token
local function while_stat(scope, stat_elem)
  local this_tok = new_node("whilestat")
  this_tok.stat_elem = stat_elem
  this_tok.while_token = new_token_node()
  this_tok.locals = {}
  this_tok.labels = {}
  this_tok.parent_scope = scope
  next_token() -- skip WHILE
  this_tok.condition = expr(this_tok, stat_elem)
  this_tok.do_token = new_token_node()
  assert_next("do")
  this_tok.body = stat_list(this_tok)
  this_tok.end_token = new_token_node()
  assert_match(this_tok.while_token, "end")
  return this_tok
end

--- Repeat Statement
--- `repeatstat -> REPEAT block UNTIL condition`
---@param scope AstScope
---@return Token
local function repeat_stat(scope, stat_elem)
  local this_tok = new_node("repeatstat")
  this_tok.stat_elem = stat_elem
  this_tok.repeat_token = new_token_node()
  this_tok.locals = {}
  this_tok.labels = {}
  this_tok.parent_scope = scope
  this_tok.repeatstat = new_token_node()
  next_token() -- skip REPEAT
  this_tok.body = stat_list(this_tok)
  this_tok.until_token = new_token_node()
  assert_match(this_tok.repeat_token, "until")
  this_tok.condition = expr(this_tok, stat_elem)
  return this_tok
end

--- Numeric For Statement
--- `fornum -> NAME = exp1,exp1[,exp1] DO block`
---@param first_name Token
---@param scope AstScope
---@return Token
local function for_num(first_name, scope, stat_elem)
  local this_tok = new_node("fornum")
  this_tok.stat_elem = stat_elem
  local var_local, var_ref = ast.create_local(first_name, stat_elem)
  var_local.whole_block = true
  this_tok.var = var_ref
  this_tok.locals = {var_local}
  this_tok.labels = {}
  this_tok.parent_scope = scope
  this_tok.eq_token = new_token_node()
  assert_next("=")
  this_tok.start = expr(scope, stat_elem)
  this_tok.first_comma_token = new_token_node()
  assert_next(",")
  this_tok.stop = expr(scope, stat_elem)
  this_tok.step = nil
  if test_next(",") then
    this_tok.second_comma_token = new_token_node(true)
    this_tok.step = expr(scope, stat_elem)
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
local function for_list(first_name, scope, stat_elem)
  local name_local, name_ref = ast.create_local(first_name, stat_elem)
  name_local.whole_block = true
  local nl = {name_ref}
  local this_tok = new_node("forlist")
  this_tok.stat_elem = stat_elem
  this_tok.name_list = nl
  this_tok.locals = {name_local}
  this_tok.labels = {}
  this_tok.parent_scope = scope
  this_tok.comma_tokens = {}
  while test_next(",") do
    this_tok.comma_tokens[#this_tok.comma_tokens+1] = new_token_node(true)
    this_tok.locals[#this_tok.locals+1], nl[#nl+1] = ast.create_local(assert_ident(), stat_elem)
    this_tok.locals[#this_tok.locals].whole_block = true
  end
  this_tok.in_token = new_token_node()
  assert_next("in")
  this_tok.exp_list, this_tok.exp_list_comma_tokens = exp_list(scope, stat_elem)
  this_tok.do_token = new_token_node()
  assert_next("do")
  this_tok.body = stat_list(this_tok)
  return this_tok
end

--- For Statement
--- `for_stat -> FOR (fornum | forlist) END`
---@param scope AstScope
---@return Token
local function for_stat(scope, stat_elem)
  local for_token = new_token_node()
  next_token() -- skip FOR
  local first_ident = assert_ident()
  local t = token.token_type
  local for_node
  if t == "=" then
    for_node = for_num(first_ident, scope, stat_elem)
  elseif t == "," or t == "in" then
    for_node = for_list(first_ident, scope, stat_elem)
  else
    syntax_error("'=', ',' or 'in' expected")
  end
  for_node.for_token = for_token
  for_node.end_token = new_token_node()
  assert_match(for_token, "end")
  return for_node
end


local function test_then_block(scope, stat_elem)
  -- test_then_block -> [IF | ELSEIF] condition THEN block
  --TODO: [IF | ELSEIF] ( condition | name_list '=' exp_list  [';' condition] ) THEN block
  -- if first token is ident, and second is ',' or '=', use if-init, else original parse
  -- if no condition in if-init, first name/expr is used
  local this_tok = new_node("testblock")
  this_tok.stat_elem = stat_elem
  this_tok.locals = {}
  this_tok.labels = {}
  this_tok.parent_scope = scope
  this_tok.if_token = new_token_node()
  next_token() -- skip IF or ELSEIF
  this_tok.condition = expr(this_tok, stat_elem)
  this_tok.then_token = new_token_node()
  assert_next("then")
  this_tok.body = stat_list(this_tok)
  return this_tok
end

local function if_stat(scope, stat_elem)
  -- ifstat -> IF condition THEN block {ELSEIF condition THEN block} [ELSE block] END
  local this_tok = new_node("ifstat")
  this_tok.stat_elem = stat_elem
  this_tok.ifs = {}
  repeat
    this_tok.ifs[#this_tok.ifs+1] = test_then_block(scope, stat_elem)
  until token.token_type ~= "elseif"
  if test_next("else") then
    local elseblock = new_node("elseblock")
    this_tok.elseblock = elseblock
    elseblock.stat_elem = stat_elem
    elseblock.locals = {}
    elseblock.labels = {}
    elseblock.parent_scope = scope
    elseblock.else_token = new_token_node(true)
    elseblock.body = stat_list(elseblock)
  end
  this_tok.end_token = new_token_node()
  assert_match(this_tok.ifs[1].if_token, "end")
  return this_tok
end

local function local_func(local_token, function_token, scope, stat_elem)
  local name_local, name_ref = ast.create_local(assert_ident(), stat_elem)
  scope.locals[#scope.locals+1] = name_local
  return body(function_token, scope, false, stat_elem, function(b)
    b.node_type = "localfunc"
    b.local_token = local_token
    b.name = name_ref
    name_local.start_at = b
    name_local.start_offset = 0
  end)
end

local function local_stat(local_token, scope, stat_elem)
  -- stat -> LOCAL NAME {`,' NAME} [`=' exp_list]
  local lhs = {}
  ---@type AstLocalStat
  local this_tok = new_node("localstat")
  this_tok.stat_elem = stat_elem
  -- ---@narrow this_tok AstLocalStat
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
  local local_defs = {}
  repeat
    local_defs[#local_defs+1], lhs[#lhs+1] = ast.create_local(assert_ident(), stat_elem)
    local_defs[#local_defs].start_at = this_tok
    local_defs[#local_defs].start_offset = 1
  until not test_comma()
  if test_next("=") then
    this_tok.eq_token = new_token_node(true)
    this_tok.rhs, this_tok.rhs_comma_tokens = exp_list(scope, stat_elem)
  end
  for _, name_local in ipairs(local_defs) do
    scope.locals[#scope.locals+1] = name_local
  end
  return this_tok
end

---@param scope AstScope
---@return boolean
---@return AstExpression name
local function func_name(scope, stat_elem)
  -- func_name -> NAME {‘.’ NAME} [`:' NAME]

  local ident = assert_ident()
  local name = ast.get_ref(scope, stat_elem, ident.value, ident)

  while token.token_type == "." do
    name = suffixed_lut["."](name)
  end

  if token.token_type == ":" then
    name = suffixed_lut["."](name)
    return true, name
  end

  return false, name
end

local function func_stat(scope, stat_elem)
  -- funcstat -> FUNCTION func_name body
  local function_token = new_token_node()
  next_token() -- skip FUNCTION
  local is_method, name = func_name(scope, stat_elem)
  return body(function_token, scope, is_method, stat_elem, function(b)
    b.node_type = "funcstat"
    b.name = name
  end)
end

local function expr_stat(scope, stat_elem)
  -- stat -> func | assignment
  local first_exp = suffixed_exp(scope, stat_elem)
  if token.token_type == "=" or token.token_type == "," then
    -- stat -> assignment
    return assignment({first_exp}, {}, scope, stat_elem)
  else
    -- stat -> func
    if first_exp.node_type == "call" or first_exp.node_type == "selfcall" then
      return first_exp
    else
      syntax_error("Unexpected <exp>")
    end
  end
end

local function ret_stat(scope, stat_elem)
  -- stat -> RETURN [exp_list] [';']
  local this_node = new_node("retstat")
  this_node.stat_elem = stat_elem
  this_node.return_token = new_token_node()
  next_token() -- skip "return"
  if block_follow(true) then
    -- return no values
  elseif token.token_type == ";" then
    -- also return no values
  else
    this_node.exp_list, this_node.exp_list_comma_tokens = exp_list(scope, stat_elem)
  end
  if test_next(";") then
    this_node.semi_colon_token = new_token_node(true)
  end
  return this_node
end

local statement_lut = {
  [";"] = function(scope, stat_elem) -- stat -> ';' (empty statement)
    local this_tok = new_node("empty")
    this_tok.stat_elem = stat_elem
    this_tok.semi_colon_token = new_token_node()
    next_token() -- skip
    return this_tok
  end,
  ["if"] = function(scope, stat_elem) -- stat -> ifstat
    return if_stat(scope, stat_elem)
  end,
  ["while"] = function(scope, stat_elem) -- stat -> whilestat
    return while_stat(scope, stat_elem)
  end,
  ["do"] = function(scope, stat_elem) -- stat -> DO block END
    local do_stat = new_node("dostat")
    do_stat.stat_elem = stat_elem
    do_stat.locals = {}
    do_stat.labels = {}
    do_stat.parent_scope = scope
    do_stat.do_token = new_token_node()
    next_token() -- skip "do"
    do_stat.body = stat_list(do_stat)
    do_stat.end_token = new_token_node()
    assert_match(do_stat.do_token, "end")
    return do_stat
  end,
  ["for"] = function(scope, stat_elem) -- stat -> for_stat
    return for_stat(scope, stat_elem)
  end,
  ["repeat"] = function(scope, stat_elem) -- stat -> repeatstat
    return repeat_stat(scope, stat_elem)
  end,
  ["function"] = function(scope, stat_elem) -- stat -> funcstat
    return func_stat(scope, stat_elem)
  end,
  ["local"] = function(scope, stat_elem) -- stat -> localstat
    local local_token_node = new_token_node()
    next_token() -- skip "local"
    if test_next("function") then
      return local_func(local_token_node, new_token_node(true), scope, stat_elem)
    else
      return local_stat(local_token_node, scope, stat_elem)
    end
  end,
  ["::"] = function(scope, stat_elem) -- stat -> label
    return label_stat(scope, stat_elem)
  end,
  ["return"] = function(scope, stat_elem) -- stat -> retstat
    return ret_stat(scope, stat_elem)
  end,

  ["break"] = function(scope, stat_elem) -- stat -> breakstat
    local this_tok = new_node("breakstat")
    this_tok.stat_elem = stat_elem
    this_tok.break_token = new_token_node()
    next_token() -- skip BREAK
    return this_tok
  end,
  ["goto"] = function(scope, stat_elem) -- stat -> 'goto' NAME
    local this_tok = new_node("gotostat")
    this_tok.stat_elem = stat_elem
    this_tok.goto_token = new_token_node()
    next_token() -- skip GOTO
    local name_token = new_token_node()
    name_token.value = nil
    local target_ident = assert_ident()
    this_tok.target_name = target_ident.value
    this_tok.target_token = name_token
    return this_tok
  end,
}
function statement(scope, stat_elem)
  return (statement_lut[token.token_type] or expr_stat)(scope, stat_elem)
end


local function main_func(chunk_name)
  local main = {
    node_type = "functiondef",
    is_main = true,
    source = chunk_name,
    -- fake parent scope of main to provide _ENV upval
    parent_scope = {
      node_type = "env_scope",
      body = ill.new(),
      child_scopes = {},
      locals = {
        -- Lua emits _ENV as if it's a local in the parent scope
        -- of the file. I'll probably change this one day to be
        -- the first upval of the parent scope, since load()
        -- clobbers the first upval anyway to be the new _ENV value
        (function()
          local def = ast.create_local_def("_ENV")
          def.whole_block = true
          def.scope = nil -- set down below
          return def
        end)(),
      },
      labels = {},
    },
    child_scopes = {},
    func_protos = {},
    body = false, -- list body before locals
    is_method = false,
    is_vararg = true, -- main is always vararg
    params = {},
    locals = {}, upvals = {}, labels = {},
  }
  main.parent_scope.locals[1].scope = main.parent_scope
  main.stat_elem = ill.append(main.parent_scope.body, main)
  main.parent_scope.body.scope = main.parent_scope

  main.body = stat_list(main)
  main.eof_token = new_token_node()
  return main
end

local tokenize = require("tokenize")
local function parse(text,source_name)
  local token_iter,str,index = tokenize(text)


  function next_token()
    local leading = {}
    while true do
      index,token = token_iter(str,index)
      if not token then
        token = {token_type="eof", leading = leading}
        break
      end
      if token.token_type == "comment" then
        leading[#leading+1] = token
        -- parse doc comments, accumulate them for the next token that wants them
        --[[ these patterns match all of the following:
          --- Description text, three dashes, a space, and any text
          ---@tag three dashes, at-tag, and any text
          -- @tag two dashes, a space, at-tag, and any text
        ]]
        if token.value:match("^%- ") or token.value:match("^[- ]@") then
          -- print("found doc comment " .. token.value)
        end
      elseif token.token_type == "blank" then
        leading[#leading+1] = token
      else
        token.leading = leading
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
    until peek_tok.token_type ~= "blank" and peek_tok.token_type ~= "comment"
    str.line, str.line_offset = line, line_offset
    return peek_tok, start_at
  end

  next_token()

  return main_func(source_name)
end

return parse
