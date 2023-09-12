
local util = require("util")
local ast = require("ast_util")
local nodes = require("nodes")
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
local error_code_insts
local invalid_token_invalid_node_lut
---used to carry the position token over from `new_error_code_inst` to `syntax_error`
local err_pos_token
---only used by labels, it's simply just an extra node that's going to be added
---for 1 statement parse call. In other words: this is for when a statement has to
---add 2 nodes to the statement list instead of 1\
---this really just for special nodes like invalid nodes
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
  local node = nodes.new_token(use_prev and prev_token or token)
  if value ~= nil then
    node.value = value
  end
  return node
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

---@param invalid AstInvalidNode
---@param consumed_node AstNode
local function add_consumed_node(invalid, consumed_node)
  if not (consumed_node.node_type == "token" and consumed_node--[[@as AstTokenNode]].token_type == "eof") then
    invalid.consumed_nodes[#invalid.consumed_nodes+1] = consumed_node
  end
end

local function get_error_code_insts_count()
  return #error_code_insts
end

---TODO: make the correct object in the error message the focus, the thing that is actually wrong.
---for example when an assertion of some token failed, it's most likely not that token that
---is missing (like a closing }), but rather the actual token that was encountered that was unexpected
---Throw a Syntax Error at the current location
---@param error_code_inst ErrorCodeInstance
local function syntax_error(
  error_code_inst,
  location_descriptor,
  error_code_insts_insertion_index,
  current_invalid_token
)
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
  if error_code_insts_insertion_index then
    table.insert(error_code_insts, error_code_insts_insertion_index, error_code_inst)
  else
    error_code_insts[#error_code_insts+1] = error_code_inst
  end
  if current_invalid_token then
    invalid_token_invalid_node_lut[current_invalid_token] = invalid
  end
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
      message_args = {close, open_token.token_type, open_token.line..":"..open_token.column},
    })
  end
end

local block_ends = util.invert{"else", "elseif", "until", "end", "eof"}

--- Test if the next token closes a block.\
--- In regular lua's parser `until` can be excluded to be considered ending a block
--- because it does not actually end the current scope, since the condition is also
--- inside the scope. This is important for jump linking, but since jump linking is
--- kept separate in phobos (at least at the moment) that logic is not needed here
---@return boolean
local function next_token_ends_block()
  return block_ends[token.token_type]
end

--- Read a list of Statements and append them to `scope.body`\
--- `stat_list -> { stat [';'] }`
---@param scope AstScope
local function stat_list(scope)
  local stop
  while not next_token_ends_block() do
    if token.token_type == "eof" then
      break
    elseif token.token_type == "return" then
      stop = true
    end
    ast.append_stat(scope, statement(scope))
    if extra_node then
      ast.append_stat(scope, extra_node)
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
local function index_expr(scope)
  local open_token = new_token_node()
  next_token()
  local e = expr(scope)
  local close_token = assert_match(open_token, "]") or new_token_node(true)
  return e, open_token, close_token
end

--- Table Constructor record field
---@param scope AstScope
---@return AstRecordField
local function rec_field(scope)
  local field = {type = "rec"}
  if token.token_type == "ident" then
    field.key = nodes.new_string{
      position = token,
      value = token.value--[[@as string]],
      src_is_ident = true,
    }
    next_token()
  else
    field.key, field.key_open_token, field.key_close_token = index_expr(scope)
  end
  field.eq_token = assert_next("=") or new_token_node(true)
  if is_invalid(field.eq_token) then
    -- value should never be nil
    field.value = prevent_assert
  else
    field.value = expr(scope)
  end
  return field
end

--- Table Constructor list field
---@param scope AstScope
---@return AstListField
local function list_field(scope)
  return {type = "list", value = expr(scope)}
end

--- Table Constructor field
--- `field -> list_field | rec_field`
---@param scope AstScope
---@return AstField
local function field(scope)
  return (({
    ["ident"] = function()
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
  local node = nodes.new_constructor{
    open_token = new_token_node(),
    comma_tokens = {},
  }
  assert(assert_next("{") == nil, "Do not call 'constructor' if the current token is not '{'.")
  while token.token_type ~= "}" do
    node.fields[#node.fields+1] = field(scope)
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
local function par_list(scope)
  -- param_list -> [ param { ',' param } ]
  local params = {}
  if token.token_type == ")" then
    return params
  end
  while true do
    if test_next("ident") then
      local param_def
      param_def, params[#params+1] = ast.create_local(prev_token, scope)
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
local function functiondef(function_token, scope, is_method)
  -- body -> `(` param_list `)`  block END
  local parent_functiondef = scope
  while parent_functiondef.node_type ~= "functiondef" do
    parent_functiondef = parent_functiondef.parent_scope
  end
  local node = nodes.new_functiondef{
    parent_scope = scope,
    source = source,
    is_method = is_method,
    param_comma_tokens = {},
  }
  -- add to parent before potential early returns
  parent_functiondef.func_protos[#parent_functiondef.func_protos+1] = node
  if is_method then
    local self_local = ast.new_local_def("self", node)
    self_local.whole_block = true
    self_local.src_is_method_self = true
    node.locals[1] = self_local
  end
  node.function_token = function_token
  node.open_paren_token = assert_next("(") or new_token_node(true)
  if is_invalid(node.open_paren_token) then
    return node
  end
  node.params = par_list(node)
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
local function exp_list(scope)
  local el = {expr(scope)}
  local comma_tokens = {}
  while test_next(",") do
    comma_tokens[#comma_tokens+1] = new_token_node(true)
    el[#el+1] = expr(scope)
  end
  return el, comma_tokens
end

--- Function Arguments
---@param node AstCall
---@param scope AstScope
---@return AstExpression[]
local function func_args(node, scope)
  return (({
    ["("] = function()
      node.open_paren_token = new_token_node()
      next_token()
      if token.token_type == ")" then
        node.close_paren_token = new_token_node()
        next_token()
        return {}
      end
      local el, comma_tokens = exp_list(scope)
      node.close_paren_token = assert_match(node.open_paren_token, ")") or new_token_node(true)
      return el, comma_tokens
    end,
    ["string"] = function()
      local string_node = nodes.new_string{
        position = token,
        value = token.value--[[@as string]],
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
      return {(constructor(scope))}, {}
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
local function primary_exp(scope)
  if test_next("(") then
    local open_paren_token = new_token_node(true)
    -- NOTE: compact lambda here:
    -- token_type is ')', empty args expect `'=>' expr` next
    -- token_type is 'ident'
    --  followed by `,` is multiple args, finish list then `=> expr`
    --  followed by `)` `=>` is single arg, expect `expr_list`
    --  followed by `)` or anything else is expr of inner, current behavior
    local ex = expr(scope)
    local close_paren_token = assert_match(open_paren_token, ")") or new_token_node(true)
    ex.force_single_result = true
    local wrapper = {
      open_paren_token = open_paren_token,
      close_paren_token = close_paren_token,
    }
    if ex.node_type == "concat" then
      ---@cast ex AstConcat
      init_concat_src_paren_wrappers(ex)
      ex.concat_src_paren_wrappers[1][#ex.concat_src_paren_wrappers[1]+1] = wrapper
    else
      ---@cast ex AstExpression
      ex.src_paren_wrappers = ex.src_paren_wrappers or {}
      ex.src_paren_wrappers[#ex.src_paren_wrappers+1] = wrapper
    end
    return ex
  elseif token.token_type == "ident" then
    local ident = assert_ident() -- can't be invalid
    return ast.resolve_ref_at_end(scope, ident.value, ident)
  else
    if token.token_type == "invalid" then
      local invalid = invalid_token_invalid_node_lut[token]
      add_consumed_node(invalid, new_token_node())
      next_token()
      return invalid
    else
      local invalid = syntax_error(new_error_code_inst{
        error_code = error_code_util.codes.unexpected_token,
      }, "")
      -- consume the invalid token, it would infinitely loop otherwise
      add_consumed_node(invalid, new_token_node())
      next_token()
      return invalid
    end
  end
end

local function new_regular_call(ex, scope)
  local node = nodes.new_call{
    ex = ex,
  }
  node.args, node.args_comma_tokens = func_args(node, scope)
  return node
end

local suffixed_lut = {
  ["."] = function(ex, scope)
    local node = nodes.new_index{
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
        position = ident,
        value = ident.value--[[@as string]],
        src_is_ident = true,
      }
    end
    return node
  end,
  ["["] = function(ex, scope)
    local node = nodes.new_index{
      ex = ex,
      suffix = prevent_assert,
    }
    node.suffix, node.suffix_open_token, node.suffix_close_token = index_expr(scope)
    return node
  end,
  [":"] = function(ex, scope)
    local node = nodes.new_call{
      is_selfcall = true,
      ex = ex,
      colon_token = new_token_node(),
      suffix = prevent_assert,
    }
    next_token() -- skip ':'
    local ident = assert_ident()
    if is_invalid(ident) then
      node.suffix = ident
      if token.token_type ~= "(" and token.token_type ~= "string" and token.token_type ~= "{" then
        -- return early to prevent the additional syntax error
        return node
      end
    else
      node.suffix = nodes.new_string{
        position = ident,
        value = ident.value--[[@as string]],
        src_is_ident = true,
      }
    end
    node.args, node.args_comma_tokens = func_args(node, scope)
    return node
  end,
  ["("] = new_regular_call,
  ["string"] = new_regular_call,
  ["{"] = new_regular_call,
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
  while ex.node_type ~= "invalid" do
    ex = ((suffixed_lut)[token.token_type] or function(ex)
      should_break = true
      return ex
    end)(ex, scope)
    if should_break then
      break
    end
  end
  return ex
end

---value is set outside, for all of them
local simple_lut = {
  ["number"] = function(scope)
    return nodes.new_number{
      position = token,
      value = token.value--[[@as number]],
      src_value = token.src_value,
    }
  end,
  ["string"] = function(scope)
    return nodes.new_string{
      position = token,
      value = token.value--[[@as string]],
      src_is_block_str = token.src_is_block_str,
      src_quote = token.src_quote,
      src_value = token.src_value,
      src_has_leading_newline = token.src_has_leading_newline,
      src_pad = token.src_pad,
    }
  end,
  ["nil"] = function(scope)
    return nodes.new_nil{
      position = token,
    }
  end,
  ["true"] = function(scope)
    return nodes.new_boolean{
      position = token,
      value = true,
    }
  end,
  ["false"] = function(scope)
    return nodes.new_boolean{
      position = token,
      value = false,
    }
  end,
  ["..."] = function(scope)
    while scope.node_type ~= "functiondef" do
      scope = scope.parent_scope
    end
    if not scope.is_vararg then
      local invalid = syntax_error(new_error_code_inst{
        error_code = error_code_util.codes.vararg_outside_vararg_func,
      }, "at")
      add_consumed_node(invalid, new_token_node())
      return invalid
    end
    return nodes.new_vararg{
      position = token,
    }
  end,
}

---Simple Expression\
---can result in invalid nodes
---@param scope AstScope
---@return AstExpression
local function simple_exp(scope)
  -- simple_exp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
  --              constructor | FUNCTION body | suffixed_exp
  if simple_lut[token.token_type] then
    local node = simple_lut[token.token_type](scope)
    next_token() --consume it
    return node
  end

  if token.token_type == "{" then
    return constructor(scope)
  elseif test_next("function") then
    return nodes.new_func_proto{
      func_def = functiondef(new_token_node(true), scope, false),
    }
  else
    return suffixed_exp(scope)
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
local function sub_expr(limit, scope)
  local node
  do
    local prio = unop_prio[token.token_type]
    if prio then
      node = nodes.new_unop{
        op = token.token_type--[[@as AstUnOpOp]],
        op_token = new_token_node(),
        ex = prevent_assert,
      }
      next_token() -- consume unop
      node.ex = sub_expr(prio, scope)
    else
      node = simple_exp(scope)
    end
  end
  local binop = token.token_type--[[@as AstBinOpOp|".."]]
  local prio = binop_prio[binop]
  while prio and prio.left > limit do
    local op_token = new_token_node()
    next_token() -- consume `binop`
    local right_node, next_op = sub_expr(prio.right, scope)
    if binop == ".." then
      if right_node.node_type == "concat" then
        ---@cast right_node AstConcat
        -- needs to init before adding the node to the exp_list so that the
        -- insert of another concat_src_paren_wrappers doesn't make the list too long
        init_concat_src_paren_wrappers(right_node)
        table.insert(right_node.exp_list, 1, node)
        node = right_node
        table.insert(node.op_tokens, 1, op_token)
        table.insert(node.concat_src_paren_wrappers, 1, {})
      elseif node.node_type == "concat" and not node.force_single_result then
        util.debug_abort("Impossible because concat is right associative which causes `sub_expr` to \z
          recursively parse until the end of the concat chain and the if block above handles that. \z
          The only case where `node` could be a concat node is if it is wrapped in parens, but that's \z
          excluded in the if condition, so the else block runs below."
        )
      else
        local left_node = node
        node = nodes.new_concat{
          exp_list = {left_node, right_node},
          op_tokens = {op_token},
        }
      end
    else
      ---@cast binop AstBinOpOp
      local left_node = node
      node = nodes.new_binop{
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
function expr(scope)
  return (sub_expr(0, scope))
end

--- Assignment Statement
---@param lhs AstExpression[]
---@param lhs_comma_tokens AstTokenNode[]
---@param scope AstScope
---@return AstAssignment
local function assignment(lhs, lhs_comma_tokens, state_for_unexpected_expressions, scope)
  if lhs[#lhs].force_single_result or lhs[#lhs].node_type == "call" then
    -- insert the syntax error at the correct location
    -- (so the order of syntax errors is in the same order as they appeared in the file)
    local invalid = syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.unexpected_expression,
      position = state_for_unexpected_expressions.position,
    }, nil, state_for_unexpected_expressions.error_code_insts_count + 1)
    add_consumed_node(invalid, lhs[#lhs])
    lhs[#lhs] = invalid
  end
  if test_next(",") then
    lhs_comma_tokens[#lhs_comma_tokens+1] = new_token_node(true)
    local first_token = token
    local initial_error_code_insts_count = get_error_code_insts_count()
    lhs[#lhs+1] = suffixed_exp(scope)
    return assignment(
      lhs,
      lhs_comma_tokens,
      {position = first_token, error_code_insts_count = initial_error_code_insts_count},
      scope
    )
  else
    local invalid = assert_next("=")
    local node = nodes.new_assignment{
      eq_token = invalid or new_token_node(true),
      lhs = lhs,
      lhs_comma_tokens = lhs_comma_tokens,
    }
    if not invalid then
      node.rhs, node.rhs_comma_tokens = exp_list(scope)
    end
    return node
  end
end

--- Label Statement
---@param scope AstScope
---@return AstLabel|AstInvalidNode
local function label_stat(scope)
  local open_token = new_token_node()
  next_token() -- skip "::"
  local name_token = new_token_node()
  local ident = assert_ident()
  if is_invalid(ident) then
    ---@cast ident AstInvalidNode
    add_consumed_node(ident, open_token)
    return ident
  end
  ---@cast ident Token
  local prev_label = scope.labels[ident.value]
  if prev_label then
    local invalid = syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.duplicate_label,
      message_args = {ident.value, prev_label.name_token.line..":"..prev_label.name_token.column},
      position = ident,
    })
    add_consumed_node(invalid, open_token)
    add_consumed_node(invalid, name_token)
    -- order is important, assert for :: after creating the previous syntax error
    local close_token = assert_next("::") or new_token_node(true)
    if is_invalid(close_token) then
      -- add another node to the stat list which is the invalid node
      -- because there wasn't a '::' token
      extra_node = close_token
    else
      add_consumed_node(invalid, close_token)
    end
    return invalid
  else
    -- storing the value both in `name` and `name_token.value`
    local node = nodes.new_label{
      name = ident.value--[[@as string]],
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
local function while_stat(scope)
  local node = nodes.new_whilestat{
    parent_scope = scope,
    while_token = new_token_node(),
    condition = prevent_assert,
  }
  next_token() -- skip WHILE
  node.condition = expr(node)
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
local function repeat_stat(scope)
  local node = nodes.new_repeatstat{
    parent_scope = scope,
    repeat_token = new_token_node(),
    condition = prevent_assert,
  }
  next_token() -- skip REPEAT
  stat_list(node)
  local invalid = assert_match(node.repeat_token, "until")
  node.until_token = invalid or new_token_node(true)
  if not invalid then
    node.condition = expr(node)
  end
  return node
end

--- Numeric For Statement
--- `fornum -> NAME = exp1,exp1[,exp1] DO block`
---@param first_name Token
---@param scope AstScope
---@return AstForNum
---@return boolean
local function for_num(first_name, scope)
  -- currently the only place calling for_num is for_stat which will only call
  -- this function if the current token is '=', but we're handling invalid anyway
  local invalid = assert_next("=")
  local node = nodes.new_fornum{
    parent_scope = scope,
    var = prevent_assert,
    locals = {prevent_assert},
    eq_token = invalid or new_token_node(true),
    start = prevent_assert,
    stop = prevent_assert,
  }
  local var_local, var_ref = ast.create_local(first_name, node)
  var_local.whole_block = true
  node.locals[1] = var_local
  node.var = var_ref
  if invalid then
    return node, true
  end
  node.start = expr(scope)
  invalid = assert_next(",")
  node.first_comma_token = invalid or new_token_node(true)
  if invalid then
    return node, true
  end
  node.stop = expr(scope)
  node.step = nil
  if test_next(",") then
    node.second_comma_token = new_token_node(true)
    node.step = expr(scope)
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
---@param first_name Token
---@param scope AstScope
---@return AstForList
---@return boolean
local function for_list(first_name, scope)
  local name_local, name_ref = ast.create_local(first_name, scope)
  name_local.whole_block = true
  ---@type AstExpression[]
  local name_list = {name_ref}
  local node = nodes.new_forlist{
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
      name_list[#name_list+1] = ident--[[@as AstExpression]]
      -- if it's an 'in' then basically just ignore the extra comma and continue with this node
      if token.token_type ~= "in" then
        return node, true
      end
    else
      node.locals[#node.locals+1], name_list[#name_list+1] = ast.create_local(ident--[[@as Token]], scope)
      node.locals[#node.locals].whole_block = true
    end
  end
  local invalid = assert_next("in")
  node.in_token = invalid or new_token_node(true)
  if invalid then
    return node, true
  end
  node.exp_list, node.exp_list_comma_tokens = exp_list(scope)
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
---@return AstForNum|AstForList|AstInvalidNode
local function for_stat(scope)
  local for_token = new_token_node()
  next_token() -- skip FOR
  local first_ident = assert_ident()
  if is_invalid(first_ident) then
    ---@cast first_ident AstInvalidNode
    add_consumed_node(first_ident, for_token)
    return first_ident
  end
  ---@cast first_ident Token
  local t = token.token_type
  local node
  local is_partially_invalid
  if t == "=" then
    node, is_partially_invalid = for_num(first_ident, scope)
  elseif t == "," or t == "in" then
    node, is_partially_invalid = for_list(first_ident, scope)
  else
    local invalid = syntax_error(new_error_code_inst{
      error_code = error_code_util.codes.expected_eq_comma_or_in,
    })
    add_consumed_node(invalid, for_token)
    add_consumed_node(invalid, nodes.new_token(first_ident))
    return invalid
  end
  node.for_token = for_token
  if not is_partially_invalid then
    node.end_token = assert_match(for_token, "end") or new_token_node(true)
  end
  return node
end


local function test_then_block(scope)
  -- test_then_block -> [IF | ELSEIF] condition THEN block
  -- NOTE: [IF | ELSEIF] ( condition | name_list '=' exp_list  [';' condition] ) THEN block
  -- if first token is ident, and second is ',' or '=', use if-init, else original parse
  -- if no condition in if-init, first name/expr is used
  local node = nodes.new_testblock{
    parent_scope = scope,
    if_token = new_token_node(),
    condition = prevent_assert,
  }
  next_token() -- skip IF or ELSEIF
  node.condition = expr(node)
  local invalid = assert_next("then")
  node.then_token = invalid or new_token_node(true)
  if invalid then
    return node, true
  end
  stat_list(node)
  return node
end

local function if_stat(scope)
  -- ifstat -> IF condition THEN block {ELSEIF condition THEN block} [ELSE block] END
  local ifs = {}
  local invalid ---@type boolean?
  repeat
    ifs[#ifs+1], invalid = test_then_block(scope)
  until token.token_type ~= "elseif" or invalid
  local elseblock
  if not invalid and test_next("else") then
    elseblock = nodes.new_elseblock{
      parent_scope = scope,
      else_token = new_token_node(true),
    }
    stat_list(elseblock)
  end
  local node = nodes.new_ifstat{
    ifs = ifs,
    elseblock = elseblock,
  }
  if not invalid then
    node.end_token = assert_match(ifs[1].if_token, "end") or new_token_node(true)
  end
  return node
end

local function local_func(local_token, function_token, scope)
  local ident = assert_ident()
  local name_local, name_ref
  if is_invalid(ident) then
    name_ref = ident--[[@as AstInvalidNode]]
  else
    name_local, name_ref = ast.create_local(ident--[[@as Token]], scope)
    scope.locals[#scope.locals+1] = name_local
  end
  local node = nodes.new_localfunc{
    name = name_ref--[[@as AstLocalReference]],
    func_def = prevent_assert,
    local_token = local_token,
  }
  node.func_def = functiondef(function_token, scope, false)
  if name_local then
    -- set this right before returning to tell the ast_util that this local definition
    -- doesn't have a start_at node yet when trying to resolve references to it within
    -- the function body
    name_local.start_at = node
    name_local.start_offset = 0
  end
  return node
end

local function local_stat(local_token, scope)
  -- stat -> LOCAL NAME {',' NAME} ['=' exp_list]
  local node = nodes.new_localstat{
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
      node.lhs[#node.lhs+1] = ident--[[@as AstLocalReference]]
      break
    else
      local_defs[#local_defs+1], node.lhs[#node.lhs+1] = ast.create_local(ident--[[@as Token]], scope)
      local_defs[#local_defs].start_at = node
      local_defs[#local_defs].start_offset = 1
    end
  until not test_comma()
  -- just continue even if it was invalid, because an '=' token would just be another syntax error
  if test_next("=") then
    node.eq_token = new_token_node(true)
    node.rhs, node.rhs_comma_tokens = exp_list(scope)
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
local function func_name(scope)
  -- func_name -> NAME {'.' NAME} [':' NAME]

  local ident = assert_ident()
  if is_invalid(ident) then
    return false, ident--[[@as AstInvalidNode]]
  end
  local name = ast.resolve_ref_at_end(scope, ident.value, ident)

  while token.token_type == "." do
    name = suffixed_lut["."](name, scope)
  end

  if token.token_type == ":" then
    name = suffixed_lut["."](name, scope)
    return true, name
  end

  return false, name
end

local function func_stat(scope)
  -- funcstat -> FUNCTION func_name body
  local function_token = new_token_node()
  next_token() -- skip FUNCTION
  local is_method, name = func_name(scope)
  if is_invalid(name) then
    ---@cast name AstInvalidNode
    -- using table.insert?! disgusting!! but we have to put the token first
    table.insert(name.consumed_nodes, 1, function_token)
    return name
  end
  ---@cast name AstExpression
  return nodes.new_funcstat{
    name = name,
    func_def = functiondef(function_token, scope, is_method),
  }
end

local function expr_stat(scope)
  -- stat -> func | assignment
  local first_token = token
  local initial_error_code_insts_count = get_error_code_insts_count()
  local first_exp = suffixed_exp(scope)
  if token.token_type == "=" or token.token_type == "," then
    -- stat -> assignment
    return assignment(
      {first_exp},
      {},
      {position = first_token, error_code_insts_count = initial_error_code_insts_count},
      scope
    )
  else
    -- stat -> func
    if first_exp.node_type == "call" and not first_exp.force_single_result then
      return first_exp
    elseif first_exp.node_type == "invalid" then
      -- wherever this invalid node came from is responsible for consuming the
      -- current token, or not consuming it. If it isn't, it has to make sure
      -- that whichever token it is leaving unconsumed will not lead down the
      -- same branches again, sine that would be an infinite loop
      return first_exp
    else
      -- insert the syntax error at the correct location
      -- (so the order of syntax errors is in the same order as they appeared in the file)
      local invalid = syntax_error(new_error_code_inst{
        error_code = error_code_util.codes.unexpected_expression,
        position = first_token,
      }, nil, initial_error_code_insts_count + 1)
      add_consumed_node(invalid, first_exp)
      return invalid
    end
  end
end

local function retstat(scope)
  -- stat -> RETURN [exp_list] [';']
  local this_node = nodes.new_retstat{
    return_token = new_token_node(),
  }
  next_token() -- skip "return"
  if next_token_ends_block() then
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
    local node = nodes.new_empty{
      semi_colon_token = new_token_node(),
    }
    next_token() -- skip
    return node
  end,
  ["if"] = function(scope) -- stat -> ifstat
    return if_stat(scope)
  end,
  ["while"] = function(scope) -- stat -> whilestat
    return while_stat(scope)
  end,
  ["do"] = function(scope) -- stat -> DO block END
    local node = nodes.new_dostat{
      parent_scope = scope,
      do_token = new_token_node(),
    }
    next_token() -- skip "do"
    stat_list(node)
    node.end_token = assert_match(node.do_token, "end") or new_token_node(true)
    return node
  end,
  ["for"] = function(scope) -- stat -> for_stat
    return for_stat(scope)
  end,
  ["repeat"] = function(scope) -- stat -> repeatstat
    return repeat_stat(scope)
  end,
  ["function"] = function(scope) -- stat -> funcstat
    return func_stat(scope)
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
    return retstat(scope)
  end,

  ["break"] = function(scope) -- stat -> breakstat
    local this_tok = nodes.new_breakstat{
      break_token = new_token_node(),
    }
    next_token() -- skip BREAK
    return this_tok
  end,
  ["goto"] = function(scope) -- stat -> 'goto' NAME
    local goto_token = new_token_node()
    next_token() -- skip GOTO
    local name_token = new_token_node()
    local target_ident = assert_ident()
    if is_invalid(target_ident) then
      add_consumed_node(target_ident--[[@as AstInvalidNode]], goto_token)
      return target_ident
    else
      -- storing the value both in `target_name` and `target_token.value`
      return nodes.new_gotostat{
        goto_token = goto_token,
        target_name = target_ident.value--[[@as string]],
        target_token = name_token,
      }
    end
  end,
}
function statement(scope)
  return (statement_lut[token.token_type] or expr_stat)(scope)
end


local function main_func()
  local main = ast.new_main(source)
  main.shebang_line = token_iter_state.shebang_line
  stat_list(main)
  -- this will only fail either if there previously were syntax errors or an early return
  local invalid = assert_next("eof")
  if invalid then
    ast.append_stat(main, invalid)
    -- continue parsing the rest of the file as if it's part of the main body
    -- because the main body is the highest scope we got
    while not test_next("eof") do
      ast.append_stat(main, statement(main))
    end
  end
  main.eof_token = new_token_node()
  return main
end

local tokenize = require("tokenize")
---@param text string
---@param source_name string
---@param options Options?
local function parse(text, source_name, options)
  source = source_name
  prevent_assert = nodes.new_invalid{
    error_code_inst = error_code_util.new_error_code{
      error_code = error_code_util.codes.incomplete_node,
      source = source,
      position = {line = 0, column = 0},
    }
  }
  error_code_insts = {}
  invalid_token_invalid_node_lut = {}
  local token_iter, index
  -- technically this doesn't have to pass along source because it gets set int the syntax_error function,
  -- but it is more correct this way
  token_iter,token_iter_state,index = tokenize(text, source, options)


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
        -- if token.value:match("^%- ") or token.value:match("^[- ]@") then
        --   print("found doc comment " .. token.value)
        -- end
      elseif token.token_type == "blank" then
        leading[#leading+1] = token
      else
        token.leading = leading
        if token.token_type == "invalid" then
          err_pos_token = token
          for _, error_code_inst in ipairs(token.error_code_insts) do
            syntax_error(error_code_inst, nil, nil, token)
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

  -- have to reset token because if the previous `parse` call was interrupted by an error
  -- which was caught by pcall the current token might still be eof which would cause
  -- this parse call to do literally nothing
  -- errors should be impossible in the parse function, but there can always be bugs
  token = (nil)--[[@as Token]]
  next_token()
  local main = main_func()

  -- have to reset token, otherwise the next parse call will think its already reached the end
  token = (nil)--[[@as Token]]
  -- clear these references to not hold on to memory
  local result_error_code_insts = error_code_insts
  error_code_insts = nil
  invalid_token_invalid_node_lut = nil
  source = nil
  prevent_assert = nil
  prev_token = (nil)--[[@as Token]]
  token_iter_state = nil
  -- with token_iter_state cleared, next_token and peek_token
  -- don't really have any other big upvals, so no need to clear them

  return main, result_error_code_insts
end

return parse
