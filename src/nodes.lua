
local ill = require("indexed_linked_list")
local invert = require("invert")

local nodes = {}

-- The idea behind all of these `new_*` functions is:
-- Allow for easy changes to some node type by modifying its constructor and/or finding all references
-- Improve/keep code readability because all constructors are using a `params` table,
--   which means you can see what values are being assigned to what field just by reading the code
-- Make it easier to create new nodes thanks to intellisense for all fields a node can have

local function assert_params_field(params, field_name)
  return assert(params[field_name], "missing param '"..field_name.."'")
end

function nodes.set_position(node, token)
  node.line = token.line
  node.column = token.column
  node.leading = token.leading
end

---@param node_type AstNodeType
local function new_node(node_type, position_token)
  local node = {node_type = node_type}
  if position_token then
    nodes.set_position(node, position_token)
  end
  return node
end

-- base nodes

---@class AstPositionParams
---@field position Token|AstTokenNode|nil

---@class AstStatementBaseParams
---@field stat_elem ILLNode<nil,AstStatement>

---@param params AstStatementBaseParams
local function stat_base(node, params)
  assert(node)
  node.stat_elem = assert_params_field(params, "stat_elem")
  return node
end

---@class AstExpressionBaseParams
---@field stat_elem ILLNode<nil,AstStatement>
---@field force_single_result boolean|nil
---@field src_paren_wrappers AstParenWrapper[]|nil

---@param params AstExpressionBaseParams
local function expr_base(node, params)
  assert(node)
  node.stat_elem = assert_params_field(params, "stat_elem")
  node.force_single_result = params.force_single_result or false
  node.src_paren_wrappers = params.src_paren_wrappers
  return node
end

---@class AstScopeBaseParams
---@field body AstStatementList|nil
---@field parent_scope AstScope|nil
---@field child_scopes AstScope[]|nil
---@field locals AstLocalDef[]|nil
---@field labels AstLabel[]|nil

---@param params AstScopeBaseParams
local function scope_base(node, params)
  assert(node)
  node.body = params.body or (function()
    local list = ill.new()
    list.scope = params.parent_scope
    return list
  end)()
  node.parent_scope = params.parent_scope
  node.child_scopes = params.child_scopes or {}
  node.locals = params.locals or {}
  node.labels = params.labels or {}
  return node
end

---@class AstLoopBaseParams
---@field linked_breaks AstBreakStat[]|nil

---@param params AstLoopBaseParams
local function loop_base(node, params)
  assert(node)
  node.linked_breaks = params.linked_breaks or {}
  return node
end

---@class AstFuncBaseBaseParams
---@field func_def AstFunctionDef

---@param params AstFuncBaseBaseParams
local function func_base_base(node, params)
  assert(node)
  node.func_def = assert_params_field(params, "func_def")
  return node
end

-- special

---@class AstEnvScopeParams : AstScopeBaseParams

---@param params AstEnvScopeParams
function nodes.new_env_scope(params)
  local node = new_node("env_scope")
  scope_base(node, params)
  return node
end

---@class AstFunctionDefParams : AstScopeBaseParams
---@field stat_elem ILLNode<nil,AstStatement>
---@field source string
---@field is_method boolean|nil
---@field func_protos AstFunctionDef[]|nil
---@field upvals AstUpvalDef[]|nil
---@field is_vararg boolean|nil
---@field params AstLocalReference[]|nil
---@field is_main boolean|nil
---@field vararg_token AstTokenNode|nil
---@field param_comma_tokens AstTokenNode|nil
---@field open_paren_token AstTokenNode|nil
---@field close_paren_token AstTokenNode|nil
---@field function_token AstTokenNode|nil
---@field end_token AstTokenNode|nil
---@field eof_token AstTokenNode|nil

---@param params AstFunctionDefParams
function nodes.new_functiondef(params)
  local node = new_node("functiondef")
  scope_base(node, params)
  node.stat_elem = assert_params_field(params, "stat_elem")
  node.source = assert_params_field(params, "source")
  node.is_method = params.is_method or false
  node.func_protos = params.func_protos or {}
  node.upvals = params.upvals or {}
  node.is_vararg = params.is_vararg or false
  node.params = params.params or {}
  node.is_main = params.is_main or false
  node.param_comma_tokens = params.param_comma_tokens
  node.vararg_token = params.vararg_token
  node.open_paren_token = params.open_paren_token
  node.close_paren_token = params.close_paren_token
  node.function_token = params.function_token
  node.end_token = params.end_token
  node.eof_token = params.eof_token
  return node
end

local cannot_infer_value_for_token_type_lut = invert{
  "blank",
  "comment",
  "string",
  "number",
  "ident",
}

---@param token Token
---@param value string|nil @ default: `token.value`
function nodes.new_token(token, value)
  local node = new_node("token", token)
  if value then
    node.value = value
  elseif not cannot_infer_value_for_token_type_lut[token.token_type] then
    node.value = token.token_type
  end
  -- else `node.value = nil`
  return node
end

---@class AstInvalidParams : AstPositionParams
---@field error_message string
---@field tokens AstTokenNode[]|nil

---@param params AstInvalidParams
function nodes.new_invalid(params)
  local node = new_node("invalid", params.position)
  node.leading = nil -- doesn't use leading, period
  node.error_message = assert_params_field(params, "error_message")
  node.tokens = params.tokens or {}
  return node
end

-- statements

---@class AstEmptyParams : AstStatementBaseParams
---@field semi_colon_token AstTokenNode|nil

---@param params AstEmptyParams
function nodes.new_empty(params)
  local node = stat_base(new_node("empty"), params)
  node.semi_colon_token = params.semi_colon_token
  return node
end

---@class AstIfStatParams : AstStatementBaseParams
---@field ifs AstTestBlock[]|nil
---@field elseblock AstElseBlock|nil
---@field end_token AstTokenNode

---@param params AstIfStatParams
function nodes.new_ifstat(params)
  local node = stat_base(new_node("ifstat"), params)
  node.ifs = params.ifs or {}
  node.elseblock = params.elseblock
  node.end_token = params.end_token
  return node
end

---@class AstTestBlockParams : AstStatementBaseParams, AstScopeBaseParams
---@field condition AstExpression
---@field if_token AstTokenNode|nil
---@field then_token AstTokenNode|nil

---@param params AstTestBlockParams
function nodes.new_testblock(params)
  local node = stat_base(new_node("testblock"), params)
  scope_base(node, params)
  node.condition = assert_params_field(params, "condition")
  node.if_token = params.if_token
  node.then_token = params.then_token
  return node
end

---@class AstElseBlockParams : AstStatementBaseParams, AstScopeBaseParams
---@field else_token AstTokenNode|nil

---@param params AstElseBlockParams
function nodes.new_elseblock(params)
  local node = stat_base(new_node("elseblock"), params)
  scope_base(node, params)
  node.else_token = params.else_token
  return node
end

---@class AstWhileStatParams : AstStatementBaseParams, AstScopeBaseParams, AstLoopBaseParams
---@field condition AstExpression
---@field while_token AstTokenNode|nil
---@field do_token AstTokenNode|nil
---@field end_token AstTokenNode|nil

---@param params AstWhileStatParams
function nodes.new_whilestat(params)
  local node = stat_base(new_node("whilestat"), params)
  scope_base(node, params)
  loop_base(node, params)
  node.condition = assert_params_field(params, "condition")
  node.while_token = params.while_token
  node.do_token = params.do_token
  node.end_token = params.end_token
  return node
end

---@class AstDoStatParams : AstStatementBaseParams, AstScopeBaseParams
---@field do_token AstTokenNode|nil
---@field end_token AstTokenNode|nil

---@param params AstDoStatParams
function nodes.new_dostat(params)
  local node = stat_base(new_node("dostat"), params)
  scope_base(node, params)
  node.do_token = params.do_token
  node.end_token = params.end_token
  return node
end

---@class AstForNumParams : AstStatementBaseParams, AstScopeBaseParams, AstLoopBaseParams
---@field var AstExpression
---@field start AstExpression
---@field stop AstExpression
---@field step AstExpression|nil
---@field for_token AstTokenNode|nil
---@field eq_token AstTokenNode|nil
---@field first_comma_token AstTokenNode|nil
---@field second_comma_token AstTokenNode|nil
---@field do_token AstTokenNode|nil
---@field end_token AstTokenNode|nil

---@param params AstForNumParams
function nodes.new_fornum(params)
  local node = stat_base(new_node("fornum"), params)
  scope_base(node, params)
  loop_base(node, params)
  node.var = assert_params_field(params, "var")
  node.start = assert_params_field(params, "start")
  node.stop = assert_params_field(params, "stop")
  node.step = params.step
  node.for_token = params.for_token
  node.eq_token = params.eq_token
  node.first_comma_token = params.first_comma_token
  node.second_comma_token = params.second_comma_token
  node.do_token = params.do_token
  node.end_token = params.end_token
  return node
end

---@class AstForListParams : AstStatementBaseParams, AstScopeBaseParams, AstLoopBaseParams
---@field name_list AstExpression[]|nil
---@field exp_list AstExpression[]|nil
---@field exp_list_comma_tokens AstTokenNode[]|nil
---@field for_token AstTokenNode|nil
---@field comma_tokens AstTokenNode[]|nil
---@field in_token AstTokenNode|nil
---@field do_token AstTokenNode|nil
---@field end_token AstTokenNode|nil

---@param params AstForListParams
function nodes.new_forlist(params)
  local node = stat_base(new_node("forlist"), params)
  scope_base(node, params)
  loop_base(node, params)
  node.name_list = params.name_list or {}
  assert(params.exp_list and params.exp_list[1], "'forlist' nodes without any expressions are invalid")
  node.exp_list = params.exp_list or {}
  node.exp_list_comma_tokens = params.exp_list_comma_tokens
  node.for_token = params.for_token
  node.comma_tokens = params.comma_tokens
  node.in_token = params.in_token
  node.do_token = params.do_token
  node.end_token = params.end_token
  return node
end

---@class AstRepeatStatParams : AstStatementBaseParams, AstScopeBaseParams, AstLoopBaseParams
---@field condition AstExpression
---@field repeat_token AstTokenNode|nil
---@field until_token AstTokenNode|nil

---@param params AstRepeatStatParams
function nodes.new_repeatstat(params)
  local node = stat_base(new_node("repeatstat"), params)
  scope_base(node, params)
  loop_base(node, params)
  node.condition = assert_params_field(params, "condition")
  node.repeat_token = params.repeat_token
  node.until_token = params.until_token
  return node
end

---@class AstFuncStatParams : AstStatementBaseParams, AstFuncBaseBaseParams
---@field name AstExpression

---@param params AstFuncStatParams
function nodes.new_funcstat(params)
  local node = stat_base(new_node("funcstat"), params)
  func_base_base(node, params)
  node.name = assert_params_field(params, "name")
  return node
end

---@class AstLocalStatParams : AstStatementBaseParams
---@field lhs AstLocalReference[]|nil
---@field rhs AstExpression[]|nil
---@field local_token AstTokenNode|nil
---@field lhs_comma_tokens AstTokenNode[]|nil
---@field rhs_comma_tokens AstTokenNode[]|nil
---@field eq_token AstTokenNode|nil

---@param params AstLocalStatParams
function nodes.new_localstat(params)
  local node = stat_base(new_node("localstat"), params)
  node.lhs = params.lhs or {}
  node.rhs = params.rhs
  node.local_token = params.local_token
  node.lhs_comma_tokens = params.lhs_comma_tokens
  node.rhs_comma_tokens = params.rhs_comma_tokens
  node.eq_token = params.eq_token
  return node
end

---@class AstLocalFuncParams : AstStatementBaseParams, AstFuncBaseBaseParams
---@field name AstLocalReference
---@field local_token AstTokenNode|nil

---@param params AstLocalFuncParams
function nodes.new_localfunc(params)
  local node = stat_base(new_node("localfunc"), params)
  func_base_base(node, params)
  node.name = assert_params_field(params, "name")
  node.local_token = params.local_token
  return node
end

---@class AstLabelParams : AstStatementBaseParams
---@field name string
---@field linked_gotos AstGotoStat[]|nil
---@field name_token AstTokenNode|nil
---@field open_token AstTokenNode|nil
---@field close_token AstTokenNode|nil

---@param params AstLabelParams
function nodes.new_label(params)
  local node = stat_base(new_node("label"), params)
  node.name = assert_params_field(params, "name")
  node.linked_gotos = params.linked_gotos or {}
  node.name_token = params.name_token
  node.open_token = params.open_token
  node.close_token = params.close_token
  return node
end

---@class AstRetStatParams : AstStatementBaseParams
---@field exp_list AstExpression[]|nil
---@field return_token AstTokenNode|nil
---@field exp_list_comma_tokens AstTokenNode[]|nil
---@field semi_colon_token AstTokenNode|nil

---@param params AstRetStatParams
function nodes.new_retstat(params)
  local node = stat_base(new_node("retstat"), params)
  node.exp_list = params.exp_list or {}
  node.return_token = params.return_token
  node.exp_list_comma_tokens = params.exp_list_comma_tokens
  node.semi_colon_token = params.semi_colon_token
  return node
end

---@class AstBreakStatParams : AstStatementBaseParams
---@field linked_loop AstLoop
---@field break_token AstTokenNode|nil

---@param params AstBreakStatParams
function nodes.new_breakstat(params)
  local node = stat_base(new_node("breakstat"), params)
  node.linked_loop = params.linked_loop
  node.break_token = params.break_token
  return node
end

---@class AstGotoStatParams : AstStatementBaseParams
---@field target_name string
---@field linked_label AstLabel|nil
---@field target_token AstTokenNode|nil
---@field goto_token AstTokenNode|nil

---@param params AstGotoStatParams
function nodes.new_gotostat(params)
  local node = stat_base(new_node("gotostat"), params)
  node.target_name = assert_params_field(params, "target_name")
  node.linked_label = params.linked_label
  node.target_token = params.target_token
  node.goto_token = params.goto_token
  return node
end

---@class AstCallParams : AstStatementBaseParams, AstExpressionBaseParams
---@field is_selfcall boolean|nil
---@field ex AstExpression
---@field suffix AstString|nil @ required if `is_selfcall == true`
---@field args AstExpression[]|nil
---@field args_comma_tokens AstTokenNode[]|nil
---@field colon_token AstTokenNode|nil
---@field open_paren_token AstTokenNode|nil
---@field close_paren_token AstTokenNode|nil

---expression or statement
---@param params AstCallParams
function nodes.new_call(params)
  local node = stat_base(new_node("call"), params)
  expr_base(node, params)
  if params.is_selfcall then
    assert(params.suffix, "if 'is_selfcall == true', 'suffix' must not be nil")
  end
  node.is_selfcall = params.is_selfcall or false
  node.ex = assert_params_field(params, "ex")
  node.suffix = params.suffix
  node.args = params.args or {}
  node.args_comma_tokens = params.args_comma_tokens
  node.colon_token = params.colon_token
  node.open_paren_token = params.open_paren_token
  node.close_paren_token = params.close_paren_token
  return node
end

---@class AstAssignmentParams : AstStatementBaseParams
---@field lhs AstExpression[]|nil
---@field rhs AstExpression[]|nil
---@field lhs_comma_tokens AstTokenNode[]|nil
---@field eq_token AstTokenNode|nil
---@field rhs_comma_tokens AstTokenNode[]|nil

---@param params AstAssignmentParams
function nodes.new_assignment(params)
  local node = stat_base(new_node("assignment"), params)
  node.lhs = params.lhs or {}
  node.rhs = params.rhs or {}
  node.lhs_comma_tokens = params.lhs_comma_tokens
  node.eq_token = params.eq_token
  node.rhs_comma_tokens = params.rhs_comma_tokens
  return node
end

-- optimizer statements

function nodes.new_inline_iife_retstat()
  error("-- TODO: refactor inline iife")
end

---@class AstLoopStatParams : AstStatementBaseParams, AstScopeBaseParams, AstLoopBaseParams
---@field do_jump_back boolean|nil
---@field open_token AstTokenNode|nil
---@field close_token AstTokenNode|nil

---@param params AstLoopStatParams
function nodes.new_loopstat(params)
  local node = stat_base(new_node("loopstat"), params)
  scope_base(node, params)
  loop_base(node, params)
  node.do_jump_back = params.do_jump_back or false
  node.open_token = params.open_token
  node.close_token = params.close_token
  return node
end

-- expressions

---@class AstLocalReferenceParams : AstExpressionBaseParams, AstPositionParams
---@field name string
---@field reference_def AstLocalDef

---@param params AstLocalReferenceParams
function nodes.new_local_ref(params)
  local node = expr_base(new_node("local_ref", params.position), params)
  node.name = assert_params_field(params, "name")
  assert(params.reference_def.def_type == "local")
  node.reference_def = assert_params_field(params, "reference_def")
  return node
end

---@class AstUpvalReferenceParams : AstExpressionBaseParams, AstPositionParams
---@field name string
---@field reference_def AstUpvalDef

---@param params AstUpvalReferenceParams
function nodes.new_upval_ref(params)
  local node = expr_base(new_node("upval_ref", params.position), params)
  node.name = assert_params_field(params, "name")
  assert(params.reference_def.def_type == "upval")
  node.reference_def = assert_params_field(params, "reference_def")
  return node
end

---@class AstIndexParams : AstExpressionBaseParams
---@field ex AstExpression
---@field suffix AstExpression
---@field src_ex_did_not_exist boolean|nil
---@field dot_token AstTokenNode|nil
---@field suffix_open_token AstTokenNode|nil
---@field suffix_close_token AstTokenNode|nil

---@param params AstIndexParams
function nodes.new_index(params)
  local node = expr_base(new_node("index"), params)
  node.ex = assert_params_field(params, "ex")
  node.suffix = assert_params_field(params, "suffix")
  node.src_ex_did_not_exist = params.src_ex_did_not_exist or false
  node.dot_token = params.dot_token
  node.suffix_open_token = params.suffix_open_token
  node.suffix_close_token = params.suffix_close_token
  return node
end

---@class AstUnOpParams : AstExpressionBaseParams
---@field op AstUnOpOp
---@field ex AstExpression
---@field op_token AstTokenNode|nil

local unop_ops = invert{"not", "-", "#"}
---@param params AstUnOpParams
function nodes.new_unop(params)
  local node = expr_base(new_node("unop"), params)
  assert(unop_ops[params.op], "invalid unop op '"..params.op.."'")
  node.op = params.op
  node.ex = assert_params_field(params, "ex")
  node.op_token = params.op_token
  return node
end

---@class AstBinOpParams : AstExpressionBaseParams
---@field op AstBinOpOp
---@field left AstExpression
---@field right AstExpression
---@field op_token AstTokenNode|nil

local binop_ops = invert{"^", "*", "/", "%", "+", "-", "==", "<", "<=", "~=", ">", ">=", "and", "or"}
---@param params AstBinOpParams
function nodes.new_binop(params)
  local node = expr_base(new_node("binop"), params)
  assert(binop_ops[params.op], "invalid binop op '"..params.op.."'")
  node.op = params.op
  node.left = assert_params_field(params, "left")
  node.right = assert_params_field(params, "right")
  node.op_token = params.op_token
  return node
end

---@class AstConcatParams : AstExpressionBaseParams
---@field exp_list AstExpression[]
---@field op_tokens AstTokenNode|[]

---@param params AstConcatParams
function nodes.new_concat(params)
  local node = expr_base(new_node("concat"), params)
  assert(params.exp_list and params.exp_list[1], "'concat' nodes without any expressions are invalid")
  node.exp_list = params.exp_list or {}
  node.op_tokens = params.op_tokens
  return node
end

---@class AstNumberParams : AstExpressionBaseParams, AstPositionParams
---@field value number
---@field src_value string|nil

---@param params AstNumberParams
function nodes.new_number(params)
  local node = expr_base(new_node("number", params.position), params)
  node.value = assert_params_field(params, "value")
  node.src_value = params.src_value
  return node
end

---@class AstStringParams : AstExpressionBaseParams, AstPositionParams
---@field value string
---@field src_is_ident boolean|nil
---@field src_is_block_str boolean|nil
---@field src_quote string|nil
---@field src_value string|nil
---@field src_has_leading_newline boolean|nil
---@field src_pad string|nil

---@param params AstStringParams
function nodes.new_string(params)
  local node = expr_base(new_node("string", params.position), params)
  node.value = assert(params.value, "null strings might be valid, but they truly are useless and annoying, so no")
  node.src_is_ident = params.src_is_ident
  node.src_is_block_str = params.src_is_block_str
  node.src_quote = params.src_quote
  node.src_value = params.src_value
  node.src_has_leading_newline = params.src_has_leading_newline
  node.src_pad = params.src_pad
  return node
end

---@class AstNilParams : AstExpressionBaseParams, AstPositionParams

---@param params AstNilParams
function nodes.new_nil(params)
  local node = expr_base(new_node("nil", params.position), params)
  return node
end

---@class AstBooleanParams : AstExpressionBaseParams, AstPositionParams
---@field value boolean

---@param params AstBooleanParams
function nodes.new_boolean(params)
  local node = expr_base(new_node("boolean", params.position), params)
  assert(params.value == true or params.value == false, "'boolean' nodes need a boolean value")
  node.value = params.value
  return node
end

---@class AstVarArgParams : AstExpressionBaseParams, AstPositionParams

---@param params AstVarArgParams
function nodes.new_vararg(params)
  local node = expr_base(new_node("vararg", params.position), params)
  return node
end

---@class AstFuncProtoParams : AstExpressionBaseParams, AstFuncBaseBaseParams

---@param params AstFuncProtoParams
function nodes.new_func_proto(params)
  local node = expr_base(new_node("func_proto"), params)
  func_base_base(node, params)
  return node
end

---@class AstConstructorParams : AstExpressionBaseParams
---@field fields AstField[]|nil
---@field open_token AstTokenNode|nil
---@field comma_tokens AstTokenNode[]|nil
---@field close_token AstTokenNode|nil

---@param params AstConstructorParams
function nodes.new_constructor(params)
  local node = expr_base(new_node("constructor"), params)
  node.fields = params.fields or {}
  node.open_token = params.open_token
  node.comma_tokens = params.comma_tokens
  node.close_token = params.close_token
  return node
end

-- optimizer expressions

function nodes.new_inline_iife()
  error("-- TODO: refactor inline iife")
end

return nodes
