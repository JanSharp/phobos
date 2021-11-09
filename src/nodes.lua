
local ill = require("indexed_linked_list")
local invert = require("invert")

local nodes = {}

---@param node_type AstNodeType
local function new_node(node_type, line, column, leading)
  return {
    node_type = node_type,
    line = line,
    column = column,
    leading = leading,
  }
end

-- base nodes

local function stat_base(
  node,
  stat_elem
)
  assert(node)
  node.stat_elem = assert(stat_elem)
  return node
end

local function expr_base(
  node,
  stat_elem,
  force_single_result,
  src_paren_wrappers
)
  assert(node)
  node.stat_elem = assert(stat_elem)
  node.force_single_result = force_single_result or false
  node.src_paren_wrappers = src_paren_wrappers
  return node
end

local function scope_base(
  node,
  body,
  locals,
  labels
)
  assert(node)
  node.body = body or ill.new()
  node.locals = locals or {}
  node.labels = labels or {}
  return node
end

local function loop_base(
  node,
  linked_breaks
)
  assert(node)
  node.linked_breaks = linked_breaks or {}
  return node
end

local function func_base_base(
  node,
  func_def
)
  assert(node)
  node.func_def = assert(func_def)
  return node
end

-- special

function nodes.new_env_scope(
  body,
  locals,
  labels
)
  local node = new_node("env_scope")
  scope_base(node, body, locals, labels)
  return node
end

function nodes.new_functiondef(
  stat_elem,
  source,
  body,
  locals,
  labels,
  is_method,
  func_protos,
  upvals,
  is_vararg,
  params,
  is_main,
  vararg_token,
  param_comma_tokens,
  open_paren_token,
  close_paren_token,
  function_token,
  end_token
)
  local node = new_node("functiondef")
  scope_base(node, body, locals, labels)
  node.stat_elem = assert(stat_elem)
  node.source = assert(source)
  node.is_method = is_method or false
  node.func_protos = func_protos or {}
  node.upvals = upvals or {}
  node.is_vararg = is_vararg or false
  node.params = params or {}
  node.is_main = is_main or false
  node.param_comma_tokens = param_comma_tokens
  node.vararg_token = vararg_token
  node.open_paren_token = open_paren_token
  node.close_paren_token = close_paren_token
  node.function_token = function_token
  node.end_token = end_token
  return node
end

function nodes.new_token(
  token
)
  local node = new_node("token", token.line, token.column, token.leading)
  node.value = token.value
  return node
end

-- statements

function nodes.new_empty(
  stat_elem,
  semi_colon_token
)
  local node = stat_base(new_node("empty"), stat_elem)
  node.semi_colon_token = semi_colon_token
  return node
end

function nodes.new_ifstat(
  stat_elem,
  ifs,
  elseblock
)
  local node = stat_base(new_node("ifstat"), stat_elem)
  node.ifs = ifs or {}
  node.elseblock = elseblock
  return node
end

function nodes.new_testblock(
  stat_elem,
  condition,
  body,
  locals,
  labels,
  if_token,
  then_token
)
  local node = stat_base(new_node("testblock"), stat_elem)
  scope_base(node, body, locals, labels)
  node.condition = assert(condition)
  node.if_token = if_token
  node.then_token = then_token
  return node
end

function nodes.new_elseblock(
  stat_elem,
  body,
  locals,
  labels,
  else_token
)
  local node = stat_base(new_node("elseblock"), stat_elem)
  scope_base(node, body, locals, labels)
  node.else_token = else_token
  return node
end

function nodes.new_whilestat(
  stat_elem,
  condition,
  body,
  locals,
  labels,
  linked_breaks,
  while_token,
  do_token,
  end_token
)
  local node = stat_base(new_node("whilestat"), stat_elem)
  scope_base(node, body, locals, labels)
  loop_base(node, linked_breaks)
  node.condition = assert(condition)
  node.while_token = while_token
  node.do_token = do_token
  node.end_token = end_token
  return node
end

function nodes.new_dostat(
  stat_elem,
  body,
  locals,
  labels,
  do_token,
  end_token
)
  local node = stat_base(new_node("dostat"), stat_elem)
  scope_base(node, body, locals, labels)
    node.do_token = do_token
  node.end_token = end_token
  return node
end

function nodes.new_fornum(
  stat_elem,
  var,
  start,
  stop,
  step,
  body,
  locals,
  labels,
  for_token,
  eq_token,
  first_comma_token,
  second_comma_token,
  do_token,
  end_token
)
  local node = stat_base(new_node("fornum"), stat_elem)
  scope_base(node, body, locals, labels)
  node.var = assert(var)
  node.start = assert(start)
  node.stop = assert(stop)
  node.step = step
  node.for_token = for_token
  node.eq_token = eq_token
  node.first_comma_token = first_comma_token
  node.second_comma_token = second_comma_token
  node.do_token = do_token
  node.end_token = end_token
  return node
end

function nodes.new_forlist(
  stat_elem,
  name_list,
  exp_list,
  body,
  locals,
  labels,
  exp_list_comma_tokens,
  for_token,
  comma_tokens,
  in_token,
  do_token,
  end_token
)
  local node = stat_base(new_node("forlist"), stat_elem)
  scope_base(node, body, locals, labels)
  node.name_list = name_list or {}
  node.exp_list = exp_list or {}
  node.exp_list_comma_tokens = exp_list_comma_tokens
  node.for_token = for_token
  node.comma_tokens = comma_tokens
  node.in_token = in_token
  node.do_token = do_token
  node.end_token = end_token
  return node
end

function nodes.new_repeatstat(
  stat_elem,
  condition,
  body,
  locals,
  labels,
  repeat_token,
  until_token
)
  local node = stat_base(new_node("repeatstat"), stat_elem)
  scope_base(node, body, locals, labels)
  node.condition = assert(condition)
  node.repeat_token = repeat_token
  node.until_token = until_token
  return node
end

function nodes.new_funcstat(
  stat_elem,
  func_def
)
  local node = stat_base(new_node("funcstat"), stat_elem)
  func_base_base(node, func_def)
  return node
end

function nodes.new_localstat(
  stat_elem,
  lhs,
  rhs,
  local_token,
  lhs_comma_tokens,
  rhs_comma_tokens,
  eq_token
)
  local node = stat_base(new_node("localstat"), stat_elem)
  node.lhs = lhs or {}
  node.rhs = rhs
  node.local_token = local_token
  node.lhs_comma_tokens = lhs_comma_tokens
  node.rhs_comma_tokens = rhs_comma_tokens
  node.eq_token = eq_token
  return node
end

function nodes.new_localfunc(
  stat_elem,
  name,
  func_def,
  local_token
)
  local node = stat_base(new_node("localfunc"), stat_elem)
  func_base_base(node, func_def)
  node.name = assert(name)
  node.local_token = local_token
  return node
end

function nodes.new_label(
  stat_elem,
  name,
  linked_gotos,
  name_token,
  open_token,
  close_token
)
  local node = stat_base(new_node("label"), stat_elem)
  node.name = assert(name)
  node.linked_gotos = linked_gotos or {}
  node.name_token = name_token
  node.open_token = open_token
  node.close_token = close_token
  return node
end

function nodes.new_retstat(
  stat_elem,
  exp_list,
  return_token,
  exp_list_comma_tokens,
  semi_colon_token
)
  local node = stat_base(new_node("retstat"), stat_elem)
  node.exp_list = exp_list or {}
  node.return_token = return_token
  node.exp_list_comma_tokens = exp_list_comma_tokens
  node.semi_colon_token = semi_colon_token
  return node
end

function nodes.new_breakstat(
  stat_elem,
  linked_loop,
  break_token
)
  local node = stat_base(new_node("breakstat"), stat_elem)
  node.linked_loop = linked_loop
  node.break_token = break_token
  return node
end

function nodes.new_gotostat(
  stat_elem,
  target_name,
  linked_label,
  target_token,
  goto_token
)
  local node = stat_base(new_node("gotostat"), stat_elem)
  node.target_name = target_name
  node.linked_label = linked_label
  node.target_token = target_token
  node.goto_token = goto_token
  return node
end

---expression or statement
function nodes.new_selfcall(
  stat_elem,
  ex,
  suffix,
  args,
  args_comma_tokens,
  colon_token,
  open_paren_token,
  close_paren_token,
  force_single_result,
  src_paren_wrappers
)
  local node = stat_base(new_node("selfcall"), stat_elem)
  expr_base(node, stat_elem, force_single_result, src_paren_wrappers)
  node.ex = assert(ex)
  node.suffix = assert(suffix)
  node.args = args or {}
  node.args_comma_tokens = args_comma_tokens
  node.colon_token = colon_token
  node.open_paren_token = open_paren_token
  node.close_paren_token = close_paren_token
  return node
end

---expression or statement
function nodes.new_call(
  stat_elem,
  ex,
  args,
  args_comma_tokens,
  open_paren_token,
  close_paren_token,
  force_single_result,
  src_paren_wrappers
)
  local node = stat_base(new_node("call"), stat_elem)
  expr_base(node, stat_elem, force_single_result, src_paren_wrappers)
  node.ex = assert(ex)
  node.args = args or {}
  node.args_comma_tokens = args_comma_tokens
  node.open_paren_token = open_paren_token
  node.close_paren_token = close_paren_token
  return node
end

function nodes.new_assignment(
  stat_elem,
  lhs,
  rhs,
  lhs_comma_tokens,
  eq_token,
  rhs_comma_tokens
)
  local node = stat_base(new_node("assignment"), stat_elem)
  node.lhs = lhs or {}
  node.rhs = rhs or {}
  node.lhs_comma_tokens = lhs_comma_tokens
  node.eq_token = eq_token
  node.rhs_comma_tokens = rhs_comma_tokens
  return node
end

-- optimizer statements

function nodes.new_inline_iife_retstat()
  error("-- TODO: refactor inline iife")
end

function nodes.new_loopstat(
  stat_elem,
  do_jump_back,
  body,
  locals,
  labels,
  linked_breaks,
  open_token,
  close_token
)
  local node = stat_base(new_node("loopstat"), stat_elem)
  scope_base(node, body, locals, labels)
  loop_base(node, linked_breaks)
  node.do_jump_back = do_jump_back
  node.open_token = open_token
  node.close_token = close_token
  return node
end

-- expressions

function nodes.new_local_ref(
  stat_elem,
  name,
  reference_def,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("local_ref"), stat_elem, force_single_result, src_paren_wrappers)
  node.name = assert(name)
  assert(reference_def.def_type == "local")
  node.reference_def = assert(reference_def)
  return node
end

function nodes.new_upval_ref(
  stat_elem,
  name,
  reference_def,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("upval_ref"), stat_elem, force_single_result, src_paren_wrappers)
  node.name = assert(name)
  assert(reference_def.def_type == "upval")
  node.reference_def = assert(reference_def)
  return node
end

function nodes.new_index(
  stat_elem,
  ex,
  suffix,
  src_ex_did_not_exist,
  dot_token,
  suffix_open_token,
  suffix_close_token,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("index"), stat_elem, force_single_result, src_paren_wrappers)
  node.ex = assert(ex)
  node.suffix = assert(suffix)
  node.src_ex_did_not_exist = src_ex_did_not_exist or false
  node.dot_token = dot_token
  node.suffix_open_token = suffix_open_token
  node.suffix_close_token = suffix_close_token
  return node
end

local unop_ops = invert{"not", "-", "#"}
function nodes.new_unop(
  stat_elem,
  op,
  ex,
  op_token,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("unop"), stat_elem, force_single_result, src_paren_wrappers)
  assert(unop_ops[op], "invalid unop op '"..op.."'")
  node.op = op
  node.ex = assert(ex)
  node.op_token = op_token
  return node
end

local binop_ops = invert{"^", "*", "/", "%", "+", "-", "==", "<", "<=", "~=", ">", ">=", "and", "or"}
function nodes.new_binop(
  stat_elem,
  op,
  left,
  right,
  op_token,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("binop"), stat_elem, force_single_result, src_paren_wrappers)
  assert(binop_ops[op], "invalid binop op '"..op.."'")
  node.op = op
  node.left = assert(left)
  node.right = assert(right)
  node.op_token = op_token
  return node
end

function nodes.new_concat(
  stat_elem,
  exp_list,
  op_tokens,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("concat"), stat_elem, force_single_result, src_paren_wrappers)
  assert(exp_list and exp_list[1], "'concat' nodes without any expressions are invalid")
  node.exp_list = exp_list
  node.op_tokens = op_tokens
  return node
end

function nodes.new_number(
  stat_elem,
  value,
  src_value,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("number"), stat_elem, force_single_result, src_paren_wrappers)
  node.value = assert(value)
  node.src_value = src_value
  return node
end

function nodes.new_string(
  stat_elem,
  value,
  src_is_ident,
  src_is_block_str,
  src_quote,
  src_value,
  src_has_leading_newline,
  src_pad,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("string"), stat_elem, force_single_result, src_paren_wrappers)
  node.value = assert(value, "null strings might be valid, but they truly are useless and annoying, so no")
  node.src_is_ident = src_is_ident
  node.src_is_block_str = src_is_block_str
  node.src_quote = src_quote
  node.src_value = src_value
  node.src_has_leading_newline = src_has_leading_newline
  node.src_pad = src_pad
  return node
end

function nodes.new_nil(
  stat_elem,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("nil"), stat_elem, force_single_result, src_paren_wrappers)
  return node
end

function nodes.new_boolean(
  stat_elem,
  value,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("boolean"), stat_elem, force_single_result, src_paren_wrappers)
  assert(value == true or value == false, "'boolean' nodes need a boolean value")
  node.value = value
  return node
end

function nodes.new_vararg(
  stat_elem,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("vararg"), stat_elem, force_single_result, src_paren_wrappers)
  return node
end

function nodes.new_func_proto(
  stat_elem,
  func_def,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("func_proto"), stat_elem, force_single_result, src_paren_wrappers)
  func_base_base(node, func_def)
  return node
end

function nodes.new_constructor(
  stat_elem,
  fields,
  open_token,
  comma_tokens,
  close_token,
  force_single_result,
  src_paren_wrappers
)
  local node = expr_base(new_node("constructor"), stat_elem, force_single_result, src_paren_wrappers)
  node.fields = fields or {}
  node.open_token = open_token
  node.comma_tokens = comma_tokens
  node.close_token = close_token
  return node
end

-- optimizer expressions

function nodes.new_inline_iife()
  error("-- TODO: refactor inline iife")
end

-- util

function nodes.set_position(node, token)
  node.line = token.line
  node.column = token.column
  node.leading = token.leading
end

return nodes
