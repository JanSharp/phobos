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
  error(msg .. " near '" .. token.token_type ..
        "' at line " .. (token.line or "(?)") .. ":" .. (token.column or "(?)"))
end

---create new AstNode using the current `token` and `leading`
---@param node_type AstNodeType
---@param use_prev boolean @ should this node be created using `prev_token` and `prev_leading`?
local function new_node(node_type, use_prev)
  return {
    node_type = node_type,
    line = (use_prev and prev_token or token).line,
    column = (use_prev and prev_token or token).column,
    leading = (use_prev and prev_leading or leading),
  }
end

local function copy_node(node, new_node_type)
  return {
    node_type = new_node_type,
    line = node.line,
    column = node.column,
    leading = node.leading,
  }
end

--- Check that the current token is an "ident" token, and if so consume and return it.
---@return AstIdent name
local function assert_name()
  if token.token_type ~= "ident" then
    syntax_error("<name> expected")
  end
  local name_node = new_node("ident")
  name_node.value = token.value
  next_token()
  return name_node
end

---@param use_prev? boolean @ should this node be created using `prev_token` and `prev_leading`? Default: `false`
---@param value? string @ Default: `(use_prev and prev_token.token_type or token.token_type)`
---@return AstTokenNode
local function new_token_node(use_prev, value)
  local node = new_node("token", use_prev)
  node.value = value or (use_prev and prev_token.token_type or token.token_type)
  return node
end

---@param ident_node AstIdent
---@return AstLocalDef def
---@return AstLocalReference ref
local function create_local(ident_node)
  local local_def = {
    def_type = "local",
    name = ident_node.value,
    child_defs = {},
  }

  local ref = copy_node(ident_node, "local_ref")
  ref.name = ident_node.value
  ref.reference_def = local_def
  return local_def, ref
end

local get_ref
do
  ---@diagnostic disable: undefined-field
  -- because AstScope doesn't have upvals, but some deriving classes do
  -- to be exact, only functions do

  ---@param scope AstScope
  ---@param name string
  ---@return AstLocalDef|AstUpvalDef|nil
  local function try_get_def(scope, name)
    -- search top down to find most recently defined one
    -- in case of redefined locals in the same scope
    for i = #scope.locals, 1, -1 do
      if scope.locals[i].name == name then
        return scope.locals[i]
      end
    end

    if scope.upvals then
      for _, upval in ipairs(scope.upvals) do
        if upval.name == name then
          return upval
        end
      end
    end

    if scope.parent_scope then
      local def = try_get_def(scope.parent_scope, name)
      if def then
        if scope.upvals then
          local new_def = {
            def_type = "upval",
            name = name,
            scope = scope,
            parent_def = def,
            child_defs = {},
          }
          def.child_defs[#def.child_defs+1] = new_def
          if name == "_ENV" then
            -- always put _ENV first so that `load`'s mangling will be correct
            table.insert(scope.upvals, 1, new_def)
          else
            scope.upvals[#scope.upvals+1] = new_def
          end
          return new_def
        else
          return def
        end
      end
    end
  end
  ---@diagnostic enable: undefined-field

  ---@param scope AstScope
  ---@param ident_node AstIdent
  ---@return AstUpvalReference|AstLocalReference
  function get_ref(scope, ident_node)
    local def = try_get_def(scope, ident_node.value)
    if def then
      return {
        node_type = def.def_type.."_ref", -- `local_ref` or `upval_ref`
        name = ident_node.value,
        line = ident_node.line,
        column = ident_node.column,
        leading = ident_node.leading,
        reference_def = def,
      }
    end

    return {
      node_type = "index",
      line = ident_node.line,
      column = ident_node.column,
      leading = {},
      ex = get_ref(scope, {
        node_type = "ident",
        value = "_ENV",
        line = ident_node.line,
        column = ident_node.column,
        leading = {},
      }),
      suffix = {
        node_type = "string",
        line = ident_node.line,
        column = ident_node.column,
        value = ident_node.value,
        leading = ident_node.leading,
        src_is_ident = true,
      },
      src_did_not_exist = true,
    }
  end
end

--- Check if the next token is a `tok` token, and if so consume it. Returns the result of the test.
---@param tok TokenType
---@return boolean
local function test_next(tok)
  if token.token_type == tok then
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
---@return AstStatement[]
local function stat_list(scope)
  local sl = {}
  while not block_follow(true) do
    if token.token_type == "eof" then
      return sl
    elseif token.token_type == "return" then
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
local function index_expr(scope)
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
  if token.token_type == "ident" then
    field.key = new_node("string")
    field.key.value = token.value
    field.key.src_is_ident = true
    next_token()
  else
    field.key, field.key_open_token, field.key_close_token = index_expr(scope)
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
      if peek_tok.token_type ~= "=" then
        return list_field(scope)
      else
        return rec_field(scope)
      end
    end,
    ["["] = rec_field,
  })[token.token_type] or list_field)(scope)
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
  while token.token_type ~= "}" do
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
  if token.token_type == ")" then
    return 0
  end
  while true do
    if token.token_type == "ident" then
      local param_def = create_local(assert_name())
      param_def.whole_block = true
      scope.locals[#scope.locals+1] = param_def
    elseif token.token_type == "..." then
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
  local parent_scope = scope
  ---@narrow scope AstScope|AstFunctionDef
  while not scope.func_protos do
    scope = scope.parent_scope
  end
  ---@narrow scope AstFunctionDef
  local func_def_node = new_node("functiondef")
  func_def_node.source = scope.source
  func_def_node.is_method = is_method
  func_def_node.func_protos = {}
  func_def_node.locals = {}
  func_def_node.upvals = {}
  func_def_node.constants = {}
  func_def_node.labels = {}
  func_def_node.param_comma_tokens = {}
  func_def_node.parent_scope = parent_scope
  func_def_node.increase_upval_depth = true
  if is_method then
    local self_ident = copy_node(func_def_node, "ident")
    self_ident.value = "self"
    local self_local = create_local(self_ident)
    -- TODO: maybe add info on the local def that this did not exist in source
    -- TODO: create_local really only needs the local name here,
    -- since the reference is not used. _maybe_ do something about that
    self_local.whole_block = true
    func_def_node.locals[1] = self_local
  end
  func_def_node.open_paren_token = new_token_node()
  local this_node = new_node("func_proto")
  this_node.ref = func_def_node
  this_node.function_token = function_token
  assert_next("(")
  func_def_node.n_params = par_list(func_def_node)
  func_def_node.close_paren_token = new_token_node()
  assert_next(")")
  func_def_node.body = stat_list(func_def_node)
  func_def_node.end_line = token.line
  func_def_node.end_column = token.column + 3
  func_def_node.end_token = new_token_node()
  assert_match("end", "function", function_token.line)
  scope.func_protos[#scope.func_protos+1] = func_def_node
  return this_node
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
      if token.token_type == ")" then
        next_token()
        return {}
      end
      local el = exp_list(scope)
      node.close_paren_token = new_token_node()
      assert_match(")","(",node.line)
      return el
    end,
    ["string"] = function(scope)
      local string_node = new_node("string")
      string_node.value = token.value
      string_node.src_is_block_str = token.src_is_block_str
      string_node.src_quote = token.src_quote
      string_node.src_value = token.src_value
      string_node.src_has_leading_newline = token.src_has_leading_newline
      string_node.src_pad = token.src_pad
      local el = {string_node}
      next_token()
      return el
    end,
    ["{"] = function(scope)
      return {(constructor(scope))}
    end,
  })[token.token_type] or function()
    syntax_error("Function arguments expected")
  end)(scope)
end

--- Primary Expression
---@param scope AstScope
---@return Token
local function primary_exp(scope)
  if token.token_type == "(" then
    local open_paren_token = new_token_node()
    next_token() -- skip '('
    --TODO: compact lambda here:
    -- token_type is ')', empty args expect `'=>' expr` next
    -- token_type is 'ident'
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
  elseif token.token_type == "ident" then
    return get_ref(scope, assert_name())
  else
    syntax_error("Unexpected symbol '" .. token.token_type .. "'")
  end
end

local suffixed_lut = {
  ["."] = function(ex)
    local node = new_node("index")
    node.ex = ex
    node.dot_token = new_token_node()
    next_token() -- skip '.'
    node.suffix = assert_name()
    node.suffix.node_type = "string"
    node.suffix.src_is_ident = true
    return node
  end,
  ["["] = function(ex,scope)
    local node = new_node("index")
    node.ex = ex
    node.suffix, node.suffix_open_token, node.suffix_close_token = index_expr(scope)
    return node
  end,
  [":"] = function(ex,scope)
    local node = new_node("selfcall")
    node.ex = ex
    node.colon_token = new_token_node()
    next_token() -- skip ':'
    node.suffix = assert_name()
    node.suffix.node_type = "string"
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
    return node
  end,
}

--- Suffixed Expression
---@param scope AstScope
---@return AstExpression
local function suffixed_exp(scope)
  -- suffixed_exp ->
  --   primary_exp { '.' NAME | '[' exp ']' | ':' NAME func_args | func_args }
  --TODO: safe chaining adds optional '?' in front of each suffix
  local ex = primary_exp(scope)
  local should_break = false
  repeat
    ex = ((suffixed_lut)[token.token_type] or function(ex)
      should_break = true
      return ex
    end)(ex,scope)
  until should_break
  return ex
end

local simple_lut = {
  ["number"] = function()
    return new_node("number")
  end,
  ["string"] = function()
    local node = new_node("string")
    node.src_is_block_str = token.src_is_block_str
    node.src_quote = token.src_quote
    node.src_value = token.src_value
    node.src_has_leading_newline = token.src_has_leading_newline
    node.src_pad = token.src_pad
    return node
  end,
  ["nil"] = function()
    return new_node("nil")
  end,
  ["true"] = function()
    return new_node("boolean")
  end,
  ["false"] = function()
    return new_node("boolean")
  end,
  ["..."] = function()
    return new_node("vararg")
  end,
}

--- Simple Expression
---@param scope AstScope
---@return Token
local function simple_exp(scope)
  -- simple_exp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
  --              constructor | FUNCTION body | suffixed_exp
  if simple_lut[token.token_type] then
    local node = simple_lut[token.token_type]()
    node.value = token.value
    next_token() --consume it
    return node
  end

  if token.token_type == "{" then
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
    local prio = unop_prio[token.token_type]
    if prio then
      node = new_node("unop")
      node.op = token.token_type
      node.op_token = new_token_node()
      next_token() -- consume unop
      node.ex = sub_expr(prio, scope)
    else
      node = simple_exp(scope)
    end
  end
  local binop = token.token_type
  local prio = binop_prio[binop]
  while prio and prio.left > limit do
    local op_token = new_token_node()
    next_token() -- consume `binop`
    local right_node, next_op = sub_expr(prio.right,scope)
    if binop == ".." then
      if right_node.node_type == "concat" then
        -- TODO: add start and end locations within the exp_list for src_paren_wrappers
        ---@narrow right_node AstConcat
        table.insert(right_node.exp_list, 1, node)
        node = right_node
        table.insert(node.op_tokens, 1, op_token)
      elseif node.node_type == "concat" then
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
  label.node_type = "label"
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
  this_tok.parent_scope = scope
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
  this_tok.parent_scope = scope
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
  local var_local, var_ref = create_local(first_name)
  var_local.whole_block = true
  this_tok.var = var_ref
  this_tok.locals = {var_local}
  this_tok.labels = {}
  this_tok.parent_scope = scope
  this_tok.eq_token = new_token_node()
  assert_next("=")
  this_tok.start = expr(scope)
  this_tok.first_comma_token = new_token_node()
  assert_next(",")
  this_tok.stop = expr(scope)
  this_tok.step = {node_type="number", value=1}
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
  local name_local, name_ref = create_local(first_name)
  name_local.whole_block = true
  local nl = {name_ref}
  local this_tok = new_node("forlist")
  this_tok.name_list = nl
  this_tok.locals = {name_local}
  this_tok.labels = {}
  this_tok.parent_scope = scope
  this_tok.comma_tokens = {}
  while test_next(",") do
    this_tok.comma_tokens[#this_tok.comma_tokens+1] = new_token_node(true)
    local name = assert_name()
    this_tok.locals[#this_tok.locals+1], nl[#nl+1] = create_local(name)
    this_tok.locals[#this_tok.locals].whole_block = true
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
---@param scope AstScope
---@return Token
local function for_stat(line,scope)
  local for_token = new_token_node()
  next_token() -- skip FOR
  local first_name = assert_name()
  local t = token.token_type
  local for_node
  if t == "=" then
    for_node = for_num(first_name,scope)
  elseif t == "," or t == "in" then
    for_node = for_list(first_name,scope)
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
  this_tok.parent_scope = scope
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
  until token.token_type ~= "elseif"
  if test_next("else") then
    local else_block = new_node("elseblock")
    this_tok.elseblock = else_block
    else_block.locals = {}
    else_block.labels = {}
    else_block.parent_scope = scope
    else_block.else_token = new_token_node(true)
    else_block.body = stat_list(else_block)
  end
  this_tok.end_token = new_token_node()
  assert_match("end","if",line)
  return this_tok
end

local function local_func(local_token, function_token, scope)
  local name_local, name_ref = create_local(assert_name())
  scope.locals[#scope.locals+1] = name_local
  local b = body(function_token, scope)
  b.node_type = "localfunc"
  b.local_token = local_token
  b.name = name_ref
  name_local.start_before = b
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
  local local_defs = {}
  repeat
    local_defs[#local_defs+1], lhs[#lhs+1] = create_local(assert_name())
  until not test_comma()
  if test_next("=") then
    this_tok.eq_token = new_token_node(true)
    this_tok.line = this_tok.eq_token.line
    this_tok.column = this_tok.eq_token.column
    this_tok.leading = this_tok.eq_token.leading
    this_tok.rhs, this_tok.rhs_comma_tokens = exp_list(scope)
  end
  for _, name_local in ipairs(local_defs) do
    scope.locals[#scope.locals+1] = name_local
  end
  return this_tok
end

---@param scope AstScope
---@return boolean
---@return AstExpression name
local function func_name(scope)
  -- func_name -> NAME {field_selector} [`:' NAME]
  -- TODO: field_selector? i think that's already an extension from regular Lua

  local name = get_ref(scope, assert_name())

  while token.token_type == "." do
    name = suffixed_lut["."](name)
  end

  if token.token_type == ":" then
    name = suffixed_lut["."](name)
    return true, name
  end

  return false, name
end

local function func_stat(line,scope)
  -- funcstat -> FUNCTION func_name body
  local function_token = new_token_node()
  next_token() -- skip FUNCTION
  local is_method, name = func_name(scope)
  local b = body(function_token, scope, is_method)
  b.node_type = "funcstat"
  b.name = name
  return b
end

local function expr_stat(scope)
  -- stat -> func | assignment
  local first_exp = suffixed_exp(scope)
  if token.token_type == "=" or token.token_type == "," then
    -- stat -> assignment
    return assignment({first_exp}, {}, scope)
  else
    -- stat -> func
    if first_exp.node_type == "call" or first_exp.node_type == "selfcall" then
      return first_exp
    else
      syntax_error("Unexpected <exp>")
    end
  end
end

local function ret_stat(scope)
  -- stat -> RETURN [exp_list] [';']
  local this_node = new_node("retstat")
  this_node.return_token = new_token_node()
  next_token() -- skip "return"
  if block_follow(true) then
    -- return no values
  elseif token.token_type == ";" then
    -- also return no values
  else
    this_node.exp_list, this_node.exp_list_comma_tokens = exp_list(scope)
  end
  if test_next(";") then
    this_node.semi_colon_token = new_token_node(true)
  end
  return this_node
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
    do_stat.parent_scope = scope
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
  return (statement_lut[token.token_type] or expr_stat)(scope)
end


local function main_func(chunk_name)
  local main = {
    node_type = "main",
    source = chunk_name,
    -- fake parent scope of main to provide _ENV upval
    parent_scope = {
      node_type = "env",
      body = {},
      locals = {
        -- Lua emits _ENV as if it's a local in the parent scope
        -- of the file. I'll probably change this one day to be
        -- the first upval of the parent scope, since load()
        -- clobbers the first upval anyway to be the new _ENV value
        {
          def_type = "local",
          name = "_ENV",
          child_defs = {},
          whole_block = true,
          scope = nil, -- set down below
        },
      },
      labels = {},
    },
    increase_upval_depth = true,
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
  main.parent_scope.locals[1].scope = main.parent_scope

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
        token = {token_type="eof"}
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