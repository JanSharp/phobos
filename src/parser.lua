
local ast = require("ast_util")
local nodes = require("nodes")
local invert = require("invert")
local error_code_util = require("error_code_util")

---a fake value to prevent assertions from failing during node creation
---since there are cases where not all required information is available yet,
---but a reference to the incomplete node is already needed. Like for scopes.\
---or just because it's easier to set a field later\
---**assigned in `parse`**
local prevent_assert

-- (outdated)
-- these locals are kind of like registers in a register-machine if you are familiar with that concept
-- otherwise, just think of them as a way to carry information from a called function to the calling
-- function without actually returning said value. That way this value can be used by utility functions
-- to read the current value being "operated".
-- this saves a lot of passing around of values through returns, parameters and locals
-- without actually modifying the value at all

local source
local invalid_nodes
---used to carry the position token over from `new_error_code_inst` to `syntax_error`
local err_pos_token
---only used by labels, it's simply just an extra node that's going to be added
---for 1 statement parse call. In other words: this is for when a statement has to
---add 2 nodes to the statement list instead of 1\
---**Important:** The extra_node cannot use `stat_elem` of any kind, so it's really just
---for special nodes like invalid nodes
local extra_node

local token_iter_state
local token ---@type Token
---set by test_next() and therefore also assert_next() and assert_match()
local prev_token ---@type Token

-- end of these kinds of locals

local next_token
local peek_token
----------------------------------------------------------------------

local statement, expr

-- local function copy_iter_state()
--   return {
--     line = token_iter_state.line,
--     line_offset = token_iter_state.line_offset,
--   }
-- end

-- local function paste_iter_state(copy)
--   token_iter_state.line = copy.line
--   token_iter_state.line_offset = copy.line_offset
-- end

local function is_invalid(node)
  return node.node_type == "invalid"
end

---@param use_prev? boolean @ should this node be created using `prev_token`?
---@param value? string @ Default: `(use_prev and prev_token.token_type or token.token_type)`
---@return AstTokenNode
local function new_token_node(use_prev, value)
  return nodes.new_token(use_prev and prev_token or token, value)
end

local function new_error_code_inst(params)
  err_pos_token = params.position or token
  return error_code_util.new_error_code{
    error_code = params.error_code,
    message_args = params.message_args,
    -- TODO: somehow figure out the stop_position of the token
    -- if I ever do that, remember that there are some errors ranging across multiple tokens
    position = err_pos_token,
  }
end

---TODO: make the correct object in the error message the focus, the thing that is actually wrong.
---for example when an assertion of some token failed, it's most likely not that token that
---is missing (like a closing }), but rather the actual token that was encountered that was unexpected
---Throw a Syntax Error at the current location
---@param error_code_inst ErrorCodeInstance
local function syntax_error(error_code_inst, location_descriptor)
  if location_descriptor then
    location_descriptor = location_descriptor == "" and "" or " "..location_descriptor
  else
    location_descriptor = " near"
  end
  local location
  if err_pos_token.token_type == "blank" then
    -- this should never happen, blank tokens are all in `leading`
    location = location_descriptor.." <blank>"
  elseif err_pos_token.token_type == "comment" then
    -- same here
    location = location_descriptor.." <comment>"
  elseif err_pos_token.token_type == "string" then
    local str
    if err_pos_token.src_is_block_str then
      if err_pos_token.src_has_leading_newline
        or err_pos_token.value:find("\n")
      then
        location = location_descriptor.." <string>"
      else
        str = "["..err_pos_token.src_pad.."["..err_pos_token.value.."]"..err_pos_token.src_pad.."]"
      end
    else -- regular string
      if err_pos_token.src_value:find("\n") then
        location = location_descriptor.." <string>"
      else
        str = err_pos_token.src_quote..err_pos_token.src_value..err_pos_token.src_quote
      end
    end
    if str then
      if #str > 32 then
        -- this message is pretty long and descriptive, but honestly it'll be shown so
        -- rarely that i don't consider this to be problematic
        location = location_descriptor.." "..str:sub(1, 16).."..."..str:sub(-16, -1)
          .." (showing 32 of "..#str.." characters)"
      else
        location = location_descriptor.." "..str
      end
    end
  elseif err_pos_token.token_type == "number" then
    location = location_descriptor.." '"..err_pos_token.src_value.."'"
  elseif err_pos_token.token_type == "ident" then
    location = location_descriptor.." "..err_pos_token.value
  elseif err_pos_token.token_type == "invalid" then
    location = ""
  elseif err_pos_token.token_type == "eof" then
    location = location_descriptor.." <eof>"
  else
    location = location_descriptor.." '"..err_pos_token.token_type.."'"
  end
  location = location..(
    err_pos_token.token_type ~= "eof"
      and (" at "..err_pos_token.line..":"..err_pos_token.column)
      or ""
  )
  error_code_inst.location_str = location
  error_code_inst.source = source
  local invalid = nodes.new_invalid{error_code_inst = error_code_inst}
  invalid_nodes[#invalid_nodes+1] = invalid
  return invalid
end

--- Check that the current token is an "ident" token, and if so consume and return it.
---@return Token|AstInvalidNode ident_token
local function assert_ident()
  if token.token_type ~= "ident" then
    return syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.expected_ident,
    })
  end
  local ident = token
  next_token()
  return ident
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
    return syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.expected_token,
      message_args = {tok},
    })
  end
end

--- Check for the matching `close` token to a given `open` token
---@param open_token AstTokenNode
---@param close string
local function assert_match(open_token, close)
  if not test_next(close) then
    return syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.expected_closing_match,
      message_args = {close, open_token.value, open_token.line..":"..open_token.column},
    })
  end
end

local block_ends = invert{"else", "elseif", "end", "eof"}

--- Test if the next token closes a block
---@param with_until boolean if true, "until" token will count as closing a block
---@return boolean
local function next_token_ends_block(with_until)
  if block_ends[token.token_type] then
    return true
  elseif token.token_type == "until" then
    return with_until
  else
    return false
  end
end

--- Read a list of Statements and append them to `scope.body`\
--- `stat_list -> { stat [';'] }`
---@param scope AstScope
local function stat_list(scope)
  local stop
  while not next_token_ends_block(true) do
    if token.token_type == "eof" then
      break
    elseif token.token_type == "return" then
      stop = true
    end
    ast.append_stat(scope, function(stat_elem)
      return statement(scope, stat_elem)
    end)
    if extra_node then
      ast.append_stat(scope, function()
        return extra_node
      end)
      extra_node = nil
    end
    if stop then
      break
    end
  end
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
  local close_token = assert_match(open_token, "]") or new_token_node(true)
  return e, open_token, close_token
end

--- Table Constructor record field
---@param scope AstScope
---@return AstRecordField
local function rec_field(scope, stat_elem)
  local field = {type = "rec"}
  if token.token_type == "ident" then
    field.key = nodes.new_string{
      stat_elem = stat_elem,
      position = token,
      value = token.value,
      src_is_ident = true,
    }
    next_token()
  else
    field.key, field.key_open_token, field.key_close_token = index_expr(scope, stat_elem)
  end
  field.eq_token = assert_next("=") or new_token_node(true)
  if is_invalid(field.eq_token) then
    -- value should never be nil
    field.value = prevent_assert
  else
    field.value = expr(scope, stat_elem)
  end
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
  local node = nodes.new_constructor{
    stat_elem = stat_elem,
    open_token = new_token_node(),
    comma_tokens = {},
  }
  assert(assert_next("{") == nil, "Do not call 'constructor' if the current token is not '{'.")
  while token.token_type ~= "}" do
    node.fields[#node.fields+1] = field(scope, stat_elem)
    if test_next(",") or test_next(";") then
      node.comma_tokens[#node.comma_tokens+1] = new_token_node(true)
    else
      break
    end
  end
  node.close_token = assert_match(node.open_token, "}") or new_token_node(true)
  return node
end

--- Function Definition Parameter List
---@param scope AstFunctionDef
---@return AstLocalReference[]
local function par_list(scope, stat_elem)
  -- param_list -> [ param { ',' param } ]
  local params = {}
  if token.token_type == ")" then
    return params
  end
  while true do
    if test_next("ident") then
      local param_def
      param_def, params[#params+1] = ast.create_local(prev_token, scope, stat_elem)
      param_def.whole_block = true
      scope.locals[#scope.locals+1] = param_def
    elseif token.token_type == "..." then
      scope.is_vararg = true
      scope.vararg_token = new_token_node()
      next_token()
      return params
    else
      params[#params+1] = syntax_error(new_error_code_inst{
        error_code = error_code_util.codes.expected_ident_or_vararg,
      })
      return params
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
---@return AstFunctionDef
local function functiondef(function_token, scope, is_method, stat_elem)
  -- body -> `(` param_list `)`  block END
  local parent_functiondef = scope
  -- ---@narrow scope AstScope|AstFunctionDef
  while parent_functiondef.node_type ~= "functiondef" do
    parent_functiondef = parent_functiondef.parent_scope
  end
  -- ---@narrow scope AstFunctionDef
  local node = nodes.new_functiondef{
    stat_elem = stat_elem,
    parent_scope = scope,
    source = source,
    is_method = is_method,
    param_comma_tokens = {},
  }
  -- add to parent before potential early returns
  parent_functiondef.func_protos[#parent_functiondef.func_protos+1] = node
  if is_method then
    local self_local = ast.create_local_def("self", node)
    self_local.whole_block = true
    self_local.src_is_method_self = true
    node.locals[1] = self_local
  end
  node.function_token = function_token
  node.open_paren_token = assert_next("(") or new_token_node(true)
  if is_invalid(node.open_paren_token) then
    return node
  end
  node.params = par_list(node, stat_elem)
  -- if par list was invalid but the current token is `")"` then just continue
  -- because there is a good chance there merely was a trailing comma in the par list
  if node.params[1] and is_invalid(node.params[#node.params]) and token.token_type ~= ")" then
    return node
  end
  node.close_paren_token = assert_next(")") or new_token_node(true)
  if is_invalid(node.close_paren_token) then
    return node
  end
  stat_list(node)
  node.end_token = assert_match(function_token, "end") or new_token_node(true)
  return node
end

--- Expression List
---@param scope AstScope
---@return AstExpression[] expression_list
---@return AstTokenNode[] comma_tokens @ length is `#expression_list - 1`
local function exp_list(scope, stat_elem)
  local el = {expr(scope, stat_elem)}
  local comma_tokens = {}
  while test_next(",") do
    comma_tokens[#comma_tokens+1] = new_token_node(true)
    el[#el+1] = expr(scope, stat_elem)
  end
  return el, comma_tokens
end

--- Function Arguments
---@param node AstCall
---@param scope AstScope
---@return AstExpression[]
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
      local invalid = assert_match(node.open_paren_token, ")")
      if invalid then
        node.close_paren_token = nil
        el[#el+1] = invalid
      end
      return el, comma_tokens
    end,
    ["string"] = function()
      local string_node = nodes.new_string{
        stat_elem = stat_elem,
        position = token,
        value = token.value,
        src_is_block_str = token.src_is_block_str,
        src_quote = token.src_quote,
        src_value = token.src_value,
        src_has_leading_newline = token.src_has_leading_newline,
        src_pad = token.src_pad,
      }
      next_token()
      return {string_node}, {}
    end,
    ["{"] = function()
      return {(constructor(scope, stat_elem))}, {}
    end,
  })[token.token_type] or function()
    return {syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.expected_func_args,
    })}
  end)()
end

local function init_concat_src_paren_wrappers(node)
  node.concat_src_paren_wrappers = node.concat_src_paren_wrappers or {}
  for i = 1, #node.exp_list - 1 do
    node.concat_src_paren_wrappers[i] = node.concat_src_paren_wrappers[i] or {}
  end
end

--- Primary Expression
---@param scope AstScope
---@return AstExpression
local function primary_exp(scope, stat_elem)
  if test_next("(") then
    local open_paren_token = new_token_node(true)
    --TODO: compact lambda here:
    -- token_type is ')', empty args expect `'=>' expr` next
    -- token_type is 'ident'
    --  followed by `,` is multiple args, finish list then `=> expr`
    --  followed by `)` `=>` is single arg, expect `expr_list`
    --  followed by `)` or anything else is expr of inner, current behavior
    local ex = expr(scope, stat_elem)
    local close_paren_token = assert_match(open_paren_token, ")") or new_token_node(true)
    ex.force_single_result = true
    local wrapper = {
      open_paren_token = open_paren_token,
      close_paren_token = close_paren_token,
    }
    if ex.node_type == "concat" then
      init_concat_src_paren_wrappers(ex)
      ex.concat_src_paren_wrappers[1][#ex.concat_src_paren_wrappers[1]+1] = wrapper
    else
      ex.src_paren_wrappers = ex.src_paren_wrappers or {}
      ex.src_paren_wrappers[#ex.src_paren_wrappers+1] = wrapper
    end
    return ex
  elseif token.token_type == "ident" then
    local ident = assert_ident()
    if is_invalid(ident) then
      return ident
    end
    return ast.get_ref(scope, stat_elem, ident.value, ident)
  else
    if token.token_type == "invalid" then
      return invalid_nodes[#invalid_nodes]
    else
      local invalid = syntax_error(new_error_code_inst{
        error_code = error_code_util.codes.unexpected_token,
      }, "")
      -- consume the invalid token, it would infinitely loop otherwise
      invalid.consumed_nodes[#invalid.consumed_nodes+1] = new_token_node()
      next_token()
      return invalid
    end
  end
end

local function new_regular_call(ex, scope, stat_elem)
  local node = nodes.new_call{
    stat_elem = stat_elem,
    ex = ex,
  }
  node.args, node.args_comma_tokens = func_args(node, scope, stat_elem)
  return node
end

local suffixed_lut = {
  ["."] = function(ex, scope, stat_elem)
    local node = nodes.new_index{
      stat_elem = stat_elem,
      ex = ex,
      dot_token = new_token_node(),
      suffix = prevent_assert,
    }
    next_token() -- skip '.'
    local ident = assert_ident()
    if is_invalid(ident) then
      node.suffix = ident
    else
      node.suffix = nodes.new_string{
        stat_elem = stat_elem,
        position = ident,
        value = ident.value,
        src_is_ident = true,
      }
    end
    return node
  end,
  ["["] = function(ex, scope, stat_elem)
    local node = nodes.new_index{
      stat_elem = stat_elem,
      ex = ex,
      suffix = prevent_assert,
    }
    node.suffix, node.suffix_open_token, node.suffix_close_token = index_expr(scope, stat_elem)
    return node
  end,
  [":"] = function(ex, scope, stat_elem)
    local node = nodes.new_call{
      stat_elem = stat_elem,
      is_selfcall = true,
      ex = ex,
      colon_token = new_token_node(),
      suffix = prevent_assert,
    }
    next_token() -- skip ':'
    local ident = assert_ident()
    if is_invalid(ident) then
      node.suffix = ident
    else
      node.suffix = nodes.new_string{
        stat_elem = stat_elem,
        position = ident,
        value = ident.value,
        src_is_ident = true,
      }
    end
    node.args, node.args_comma_tokens = func_args(node, scope, stat_elem)
    return node
  end,
  ["("] = new_regular_call,
  ["string"] = new_regular_call,
  ["{"] = new_regular_call,
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
  while ex.node_type ~= "invalid" do
    ex = ((suffixed_lut)[token.token_type] or function(ex)
      should_break = true
      return ex
    end)(ex, scope, stat_elem)
    if should_break then
      break
    end
  end
  return ex
end

---value is set outside, for all of them
local simple_lut = {
  ["number"] = function(scope, stat_elem)
    return nodes.new_number{
      stat_elem = stat_elem,
      position = token,
      value = token.value,
      src_value = token.src_value,
    }
  end,
  ["string"] = function(scope, stat_elem)
    return nodes.new_string{
      stat_elem = stat_elem,
      position = token,
      value = token.value,
      src_is_block_str = token.src_is_block_str,
      src_quote = token.src_quote,
      src_value = token.src_value,
      src_has_leading_newline = token.src_has_leading_newline,
      src_pad = token.src_pad,
    }
  end,
  ["nil"] = function(scope, stat_elem)
    return nodes.new_nil{
      stat_elem = stat_elem,
      position = token,
    }
  end,
  ["true"] = function(scope, stat_elem)
    return nodes.new_boolean{
      stat_elem = stat_elem,
      position = token,
      value = true,
    }
  end,
  ["false"] = function(scope, stat_elem)
    return nodes.new_boolean{
      stat_elem = stat_elem,
      position = token,
      value = false,
    }
  end,
  ["..."] = function(scope, stat_elem)
    while scope.node_type ~= "functiondef" do
      scope = scope.parent_scope
    end
    if not scope.is_vararg then
      local invalid = syntax_error(new_error_code_inst{
        error_code = error_code_util.codes.vararg_outside_vararg_func,
      }, "at")
      invalid.consumed_nodes[#invalid.consumed_nodes+1] = new_token_node()
      return invalid
    end
    return nodes.new_vararg{
      stat_elem = stat_elem,
      position = token,
    }
  end,
}

---Simple Expression\
---can result in invalid nodes
---@param scope AstScope
---@return AstExpression
local function simple_exp(scope, stat_elem)
  -- simple_exp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
  --              constructor | FUNCTION body | suffixed_exp
  if simple_lut[token.token_type] then
    local node = simple_lut[token.token_type](scope, stat_elem)
    next_token() --consume it
    return node
  end

  if token.token_type == "{" then
    return constructor(scope, stat_elem)
  elseif test_next("function") then
    return nodes.new_func_proto{
      stat_elem = stat_elem,
      func_def = functiondef(new_token_node(true), scope, false, stat_elem),
    }
  else
    return suffixed_exp(scope, stat_elem)
  end
end

local unop_prio = {
  ["not"] = 8,
  ["-"] = 8,
  ["#"] = 8,
}
-- the way to think about this, at least in my opinion is:
-- if the left priority of the next operator is higher than
-- the right priority of the previous operator then the current
-- operator will evaluate first.
-- evaluating first means creating a node first, which will then
-- be the right side of the previous operator
--
-- and the way the unop prio plays into this is that it is basically
-- like the right priority of binops.
--
-- examples:
-- ((foo + bar) + baz)
-- ((foo or (bar and baz)) or hi)
-- (foo ^ (bar ^ baz))
-- (-(foo ^ bar))
--
-- another way to think about this:
-- looking at an expression "affected" by 2 operators, look at both their
-- priorities. For example:
-- foo + bar * baz
--   <6-6> <7-7>
-- the expression bar has both priority 6 and 7 "applied" to it.
-- 7 is greater than 6, so that side will evaluate first; It will be the inner node
-- another example:
-- -foo ^ bar
-- 8><10-9>
-- 10 beats 8, so foo will be part of the inner node on the right
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
-- right associative doesn't affect the order in which the expressions
-- get evaluated, but it affects the order the operators get evaluated
-- in the case of ^ this is obvious since the right one ends up being the inner node:
-- foo ^ bar ^ baz => (foo ^ (bar ^ baz))
-- in the case of a concat

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
      node = nodes.new_unop{
        stat_elem = stat_elem,
        op = token.token_type,
        op_token = new_token_node(),
        ex = prevent_assert,
      }
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
        -- needs to init before adding the node to the exp_list so that the
        -- insert of another concat_src_paren_wrappers doesn't make the list too long
        init_concat_src_paren_wrappers(right_node)
        table.insert(right_node.exp_list, 1, node)
        node = right_node
        table.insert(node.op_tokens, 1, op_token)
        table.insert(node.concat_src_paren_wrappers, 1, {})
      elseif node.node_type == "concat" and not node.force_single_result then
        error("Impossible -- TODO: explain why it's impossible. Note to jog my memory: \z
          concat is right associative, so the right ones are going to be parsed first. \z
          the only way for the current `node` to be a concat node is if the simple expression \z
          at the very beginning parsed a concat node wrapped in parenthesis, however those are \z
          excluded by the if condition."
        )
      else
        local left_node = node
        node = nodes.new_concat{
          stat_elem = stat_elem,
          exp_list = {left_node, right_node},
          op_tokens = {op_token},
        }
      end
    else
      local left_node = node
      node = nodes.new_binop{
        stat_elem = stat_elem,
        left = left_node,
        op = binop,
        right = right_node,
        op_token = op_token,
      }
    end
    binop = next_op
    prio = binop_prio[binop]
  end
  return node, binop
end

--- Expression
---@param scope AstScope
---@return AstExpression completed
function expr(scope, stat_elem)
  return (sub_expr(0, scope, stat_elem))
end

--- Assignment Statement
---@param lhs AstExpression[]
---@param lhs_comma_tokens AstTokenNode[]
---@param scope AstScope
---@return AstAssignment
local function assignment(lhs, lhs_comma_tokens, prev_lhs_first_token, scope, stat_elem)
  if lhs[#lhs].force_single_result or lhs[#lhs].node_type == "call" then
    -- TODO: position the error correctly
    -- TODO: maybe insert the syntax error at the correct location
    -- (so the order of syntax errors is in the same order as they appeared in the file)
    local invalid = syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.unexpected_expression,
      position = prev_lhs_first_token,
    })
    invalid.consumed_nodes[#invalid.consumed_nodes+1] = lhs[#lhs]
    lhs[#lhs] = invalid
  end
  if test_next(",") then
    lhs_comma_tokens[#lhs_comma_tokens+1] = new_token_node(true)
    local first_token = token
    lhs[#lhs+1] = suffixed_exp(scope, stat_elem)
    -- TODO: disallow `(exp)` (so force single result expressions) and `exp()` (call expressions)
    return assignment(lhs, lhs_comma_tokens, first_token, scope, stat_elem)
  else
    local invalid = assert_next("=")
    local node = nodes.new_assignment{
      stat_elem = stat_elem,
      eq_token = invalid or new_token_node(true),
      lhs = lhs,
      lhs_comma_tokens = lhs_comma_tokens,
    }
    if not invalid then
      node.rhs, node.rhs_comma_tokens = exp_list(scope, stat_elem)
    end
    return node
  end
end

--- Label Statement
---@param scope AstScope
---@return AstLabel
local function label_stat(scope, stat_elem)
  local open_token = new_token_node()
  next_token() -- skip "::"
  local name_token = new_token_node()
  local ident = assert_ident()
  if is_invalid(ident) then
    ident.consumed_nodes[#ident.consumed_nodes+1] = open_token
    return ident
  end
  local prev_label = scope.labels[ident.value]
  if prev_label then
    local invalid = syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.duplicate_label,
      message_args = {ident.value, prev_label.name_token.line..":"..prev_label.name_token.column},
      position = ident,
    })
    invalid.consumed_nodes[#invalid.consumed_nodes+1] = open_token
    invalid.consumed_nodes[#invalid.consumed_nodes+1] = name_token
    -- order is important, assert for :: after creating the previous syntax error
    local close_token = assert_next("::") or new_token_node(true)
    if is_invalid(close_token) then
      -- add another node to the stat list which is the invalid node
      -- because there wasn't a '::' token
      extra_node = close_token
    else
      invalid.consumed_nodes[#invalid.consumed_nodes+1] = close_token
    end
    return invalid
  else
    -- deduplicate the value, since it's stored in the `name` of the node
    name_token.value = nil
    local node = nodes.new_label{
      stat_elem = stat_elem,
      name = ident.value,
      open_token = open_token,
      name_token = name_token,
      close_token = assert_next("::") or new_token_node(true),
    }
    scope.labels[node.name] = node
    return node
  end
end

--- While Statement
--- `whilestat -> WHILE condition DO block END`
---@param scope AstScope
---@return AstWhileStat
local function while_stat(scope, stat_elem)
  local node = nodes.new_whilestat{
    stat_elem = stat_elem,
    parent_scope = scope,
    while_token = new_token_node(),
    condition = prevent_assert,
  }
  next_token() -- skip WHILE
  node.condition = expr(node, stat_elem)
  local invalid = assert_next("do")
  node.do_token = invalid or new_token_node(true)
  if invalid then
    return node
  end
  stat_list(node)
  node.end_token = assert_match(node.while_token, "end") or new_token_node(true)
  return node
end

--- Repeat Statement
--- `repeatstat -> REPEAT block UNTIL condition`
---@param scope AstScope
---@return AstRepeatStat
local function repeat_stat(scope, stat_elem)
  local node = nodes.new_repeatstat{
    stat_elem = stat_elem,
    parent_scope = scope,
    repeat_token = new_token_node(),
    condition = prevent_assert,
  }
  next_token() -- skip REPEAT
  stat_list(node)
  local invalid = assert_match(node.repeat_token, "until")
  node.until_token = invalid or new_token_node(true)
  if not invalid then
    node.condition = expr(node, stat_elem)
  end
  return node
end

--- Numeric For Statement
--- `fornum -> NAME = exp1,exp1[,exp1] DO block`
---@param first_name AstTokenNode
---@param scope AstScope
---@return AstForNum
local function for_num(first_name, scope, stat_elem)
  -- TODO: check this when doing IL: the scope of this is wrong imo... but I'm not sure.
  local var_local, var_ref = ast.create_local(first_name, scope, stat_elem)
  var_local.whole_block = true
  -- currently the only place calling for_num is for_stat which will only call
  -- this function if the current token is '=', but we're handling invalid anyway
  local invalid = assert_next("=")
  local node = nodes.new_fornum{
    stat_elem = stat_elem,
    parent_scope = scope,
    var = var_ref,
    locals = {var_local},
    eq_token = invalid or new_token_node(true),
    start = prevent_assert,
    stop = prevent_assert,
  }
  if invalid then
    return node, true
  end
  node.start = expr(scope, stat_elem)
  invalid = assert_next(",")
  node.first_comma_token = invalid or new_token_node(true)
  if invalid then
    return node, true
  end
  node.stop = expr(scope, stat_elem)
  node.step = nil
  if test_next(",") then
    node.second_comma_token = new_token_node(true)
    node.step = expr(scope, stat_elem)
  end
  invalid = assert_next("do")
  node.do_token = invalid or new_token_node(true)
  if invalid then
    return node, true
  end
  stat_list(node)
  return node, false
end

--- Generic For Statement
--- `forlist -> NAME {,NAME} IN exp_list DO block`
---@param first_name AstTokenNode
---@param scope AstScope
---@return AstForList
local function for_list(first_name, scope, stat_elem)
  local name_local, name_ref = ast.create_local(first_name, scope, stat_elem)
  name_local.whole_block = true
  local name_list = {name_ref}
  local node = nodes.new_forlist{
    stat_elem = stat_elem,
    parent_scope = scope,
    name_list = name_list,
    locals = {name_local},
    exp_list = {prevent_assert},
    comma_tokens = {},
  }
  while test_next(",") do
    node.comma_tokens[#node.comma_tokens+1] = new_token_node(true)
    local ident = assert_ident()
    if is_invalid(ident) then
      name_list[#name_list+1] = ident
      -- if it's an 'in' then basically just ignore the extra comma and continue with this node
      if token.token_type ~= "in" then
        return node, true
      end
    else
      node.locals[#node.locals+1], name_list[#name_list+1] = ast.create_local(ident, scope, stat_elem)
      node.locals[#node.locals].whole_block = true
    end
  end
  local invalid = assert_next("in")
  node.in_token = invalid or new_token_node(true)
  if invalid then
    return node, true
  end
  node.exp_list, node.exp_list_comma_tokens = exp_list(scope, stat_elem)
  invalid = assert_next("do")
  node.do_token = invalid or new_token_node(true)
  if invalid then
    return node, true
  end
  stat_list(node)
  return node, false
end

--- For Statement
--- `for_stat -> FOR (fornum | forlist) END`
---@param scope AstScope
---@return Token
local function for_stat(scope, stat_elem)
  local for_token = new_token_node()
  next_token() -- skip FOR
  local first_ident = assert_ident()
  if is_invalid(first_ident) then
    first_ident.consumed_nodes[#first_ident.consumed_nodes+1] = for_token
    return first_ident
  end
  local t = token.token_type
  local node
  local is_partially_invalid
  if t == "=" then
    node, is_partially_invalid = for_num(first_ident, scope, stat_elem)
  elseif t == "," or t == "in" then
    node, is_partially_invalid = for_list(first_ident, scope, stat_elem)
  else
    local invalid = syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.expected_eq_comma_or_in,
    })
    invalid.consumed_nodes[#invalid.consumed_nodes+1] = for_token
    invalid.consumed_nodes[#invalid.consumed_nodes+1] = nodes.new_token(first_ident)
    return invalid
  end
  node.for_token = for_token
  if not is_partially_invalid then
    node.end_token = assert_match(for_token, "end") or new_token_node(true)
  end
  return node
end


local function test_then_block(scope, stat_elem)
  -- test_then_block -> [IF | ELSEIF] condition THEN block
  --TODO: [IF | ELSEIF] ( condition | name_list '=' exp_list  [';' condition] ) THEN block
  -- if first token is ident, and second is ',' or '=', use if-init, else original parse
  -- if no condition in if-init, first name/expr is used
  local node = nodes.new_testblock{
    stat_elem = stat_elem,
    parent_scope = scope,
    if_token = new_token_node(),
    condition = prevent_assert,
  }
  next_token() -- skip IF or ELSEIF
  node.condition = expr(node, stat_elem)
  local invalid = assert_next("then")
  node.then_token = invalid or new_token_node(true)
  if invalid then
    return node, true
  end
  stat_list(node)
  return node
end

local function if_stat(scope, stat_elem)
  -- ifstat -> IF condition THEN block {ELSEIF condition THEN block} [ELSE block] END
  local ifs = {}
  local invalid = false
  repeat
    ifs[#ifs+1], invalid = test_then_block(scope, stat_elem)
  until token.token_type ~= "elseif" or invalid
  local elseblock
  if not invalid and test_next("else") then
    elseblock = nodes.new_elseblock{
      stat_elem = stat_elem,
      parent_scope = scope,
      else_token = new_token_node(true),
    }
    stat_list(elseblock)
  end
  local node = nodes.new_ifstat{
    stat_elem = stat_elem,
    ifs = ifs,
    elseblock = elseblock,
  }
  if not invalid then
    node.end_token = assert_match(ifs[1].if_token, "end") or new_token_node(true)
  end
  return node
end

local function local_func(local_token, function_token, scope, stat_elem)
  local ident = assert_ident()
  local name_local, name_ref
  if is_invalid(ident) then
    name_ref = ident
  else
    name_local, name_ref = ast.create_local(ident, scope, stat_elem)
    scope.locals[#scope.locals+1] = name_local
  end
  local node = nodes.new_localfunc{
    stat_elem = stat_elem,
    name = name_ref,
    func_def = prevent_assert,
    local_token = local_token,
  }
  if name_local then
    name_local.start_at = node
    name_local.start_offset = 0
  end
  node.func_def = functiondef(function_token, scope, false, stat_elem)
  return node
end

local function local_stat(local_token, scope, stat_elem)
  -- stat -> LOCAL NAME {',' NAME} ['=' exp_list]
  local node = nodes.new_localstat{
    stat_elem = stat_elem,
    local_token = local_token,
    lhs_comma_tokens = {},
  }
  local function test_comma()
    if test_next(",") then
      node.lhs_comma_tokens[#node.lhs_comma_tokens+1] = new_token_node(true)
      return true
    end
    return false
  end
  local local_defs = {}
  repeat
    local ident = assert_ident()
    if is_invalid(ident) then
      node.lhs[#node.lhs+1] = ident
      break
    else
      local_defs[#local_defs+1], node.lhs[#node.lhs+1] = ast.create_local(ident, scope, stat_elem)
      local_defs[#local_defs].start_at = node
      local_defs[#local_defs].start_offset = 1
    end
  until not test_comma()
  -- just continue even if it was invalid, because an '=' token would just be another syntax error
  if test_next("=") then
    node.eq_token = new_token_node(true)
    node.rhs, node.rhs_comma_tokens = exp_list(scope, stat_elem)
  end
  -- add the locals after the expression list has been parsed
  for _, name_local in ipairs(local_defs) do
    scope.locals[#scope.locals+1] = name_local
  end
  return node
end

---@param scope AstScope
---@return boolean
---@return AstExpression|AstInvalidNode name
local function func_name(scope, stat_elem)
  -- func_name -> NAME {'.' NAME} [':' NAME]

  local ident = assert_ident()
  if is_invalid(ident) then
    return false, ident
  end
  local name = ast.get_ref(scope, stat_elem, ident.value, ident)

  while token.token_type == "." do
    name = suffixed_lut["."](name, scope, stat_elem)
  end

  if token.token_type == ":" then
    name = suffixed_lut["."](name, scope, stat_elem)
    return true, name
  end

  return false, name
end

local function func_stat(scope, stat_elem)
  -- funcstat -> FUNCTION func_name body
  local function_token = new_token_node()
  next_token() -- skip FUNCTION
  local is_method, name = func_name(scope, stat_elem)
  if is_invalid(name) then
    -- using table.insert?! disgusting!! but we have to put the token first
    table.insert(name.consumed_nodes, 1, function_token)
    return name
  end
  return nodes.new_funcstat{
    stat_elem = stat_elem,
    name = name,
    func_def = functiondef(function_token, scope, is_method, stat_elem),
  }
end

local function expr_stat(scope, stat_elem)
  -- stat -> func | assignment
  local first_token = token
  local first_exp = suffixed_exp(scope, stat_elem)
  if token.token_type == "=" or token.token_type == "," then
    -- stat -> assignment
    return assignment({first_exp}, {}, first_token, scope, stat_elem)
  else
    -- stat -> func
    if first_exp.node_type == "call" then
      return first_exp
    elseif first_exp.node_type == "invalid" then
      -- wherever this invalid node came from is responsible for consuming the
      -- current token, or not consuming it. If it isn't, it has to make sure
      -- that whichever token it is leaving unconsumed will not lead down the
      -- same branches again, sine that would be an infinite loop
      return first_exp
    else
      -- TODO: maybe insert the syntax error at the correct location
      -- (so the order of syntax errors is in the same order as they appeared in the file)
      local invalid = syntax_error(new_error_code_inst{
        error_code = error_code_util.codes.unexpected_expression,
        position = first_token,
      })
      invalid.consumed_nodes[#invalid.consumed_nodes+1] = first_exp
      return invalid
    end
  end
end

local function retstat(scope, stat_elem)
  -- stat -> RETURN [exp_list] [';']
  local this_node = nodes.new_retstat{
    stat_elem = stat_elem,
    return_token = new_token_node(),
  }
  next_token() -- skip "return"
  if next_token_ends_block(true) then
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
    local node = nodes.new_empty{
      stat_elem = stat_elem,
      semi_colon_token = new_token_node(),
    }
    next_token() -- skip
    return node
  end,
  ["if"] = function(scope, stat_elem) -- stat -> ifstat
    return if_stat(scope, stat_elem)
  end,
  ["while"] = function(scope, stat_elem) -- stat -> whilestat
    return while_stat(scope, stat_elem)
  end,
  ["do"] = function(scope, stat_elem) -- stat -> DO block END
    local node = nodes.new_dostat{
      stat_elem = stat_elem,
      parent_scope = scope,
      do_token = new_token_node(),
    }
    next_token() -- skip "do"
    stat_list(node)
    node.end_token = assert_match(node.do_token, "end") or new_token_node(true)
    return node
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
    return retstat(scope, stat_elem)
  end,

  ["break"] = function(scope, stat_elem) -- stat -> breakstat
    local this_tok = nodes.new_breakstat{
      stat_elem = stat_elem,
      break_token = new_token_node(),
    }
    next_token() -- skip BREAK
    return this_tok
  end,
  ["goto"] = function(scope, stat_elem) -- stat -> 'goto' NAME
    local goto_token = new_token_node()
    next_token() -- skip GOTO
    local name_token = new_token_node()
    name_token.value = nil
    local target_ident = assert_ident()
    if is_invalid(target_ident) then
      target_ident.consumed_nodes[#target_ident.consumed_nodes+1] = goto_token
      return target_ident
    else
      return nodes.new_gotostat{
        stat_elem = stat_elem,
        goto_token = goto_token,
        target_name = target_ident.value,
        target_token = name_token,
      }
    end
  end,
}
function statement(scope, stat_elem)
  return (statement_lut[token.token_type] or expr_stat)(scope, stat_elem)
end


local function main_func()
  local env_scope = nodes.new_env_scope{}
  -- Lua emits _ENV as if it's a local in the parent scope
  -- of the file. I'll probably change this one day to be
  -- the first upval of the parent scope, since load()
  -- clobbers the first upval anyway to be the new _ENV value
  local def = ast.create_local_def("_ENV", env_scope)
  def.whole_block = true
  env_scope.locals[1] = def

  local main = ast.append_stat(env_scope, function(stat_elem)
    local main = nodes.new_functiondef{
      stat_elem = stat_elem,
      is_main = true,
      source = source,
      parent_scope = env_scope,
      is_vararg = true,
    }
    stat_list(main)
    -- this will only fail either if there previously were syntax errors or an early return
    local invalid = assert_next("eof")
    if invalid then
      ast.append_stat(main, function() return invalid end)
      -- continue parsing the rest of the file as if it's part of the main body
      -- because the main body is the highest scope we got
      while not test_next("eof") do
        ast.append_stat(main, function(stat_elem_2)
          return statement(main, stat_elem_2)
        end)
      end
    end
    main.eof_token = new_token_node()
    return main
  end)
  return main
end

local tokenize = require("tokenize")
local function parse(text,source_name)
  source = source_name
  prevent_assert = nodes.new_invalid{
    error_code_inst = error_code_util.new_error_code{
      error_code = error_code_util.codes.incomplete_node,
      source = source_name,
      position = {line = 0, column = 0},
    }
  }
  invalid_nodes = {}
  local token_iter, index
  token_iter,token_iter_state,index = tokenize(text)


  function next_token()
    if token and token.token_type == "eof" then
      return
    end
    local leading = {}
    while true do
      index,token = token_iter(token_iter_state,index)
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
        if token.token_type == "invalid" then
          for _, error_code_inst in ipairs(token.error_code_insts) do
            syntax_error(error_code_inst)
          end
        end
        break
      end
    end
  end

  function peek_token(start_at)
    local line, line_offset = token_iter_state.line, token_iter_state.line_offset
    start_at = start_at or index
    local peek_tok
    repeat
      start_at,peek_tok = token_iter(token_iter_state,start_at)
    until peek_tok.token_type ~= "blank" and peek_tok.token_type ~= "comment"
    token_iter_state.line, token_iter_state.line_offset = line, line_offset
    return peek_tok, start_at
  end

  next_token()
  local main = main_func()

  -- have to reset token, otherwise the next parse call will think its already reached the end
  token = nil
  -- clear these references to not hold on to memory
  local current_invalid_nodes = invalid_nodes
  invalid_nodes = nil
  source = nil
  prevent_assert = nil
  prev_token = nil
  token_iter_state = nil
  -- with token_iter_state cleared, next_token and peek_token
  -- don't really have any other big upvals, so no need to clear them

  return main, current_invalid_nodes
end

return parse
