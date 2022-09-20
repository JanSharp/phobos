
local ill = require("indexed_linked_list")
local stack = require("stack")

local function dispatch(listeners, node, context, is_statement)
  if listeners and listeners[node.node_type] then
    listeners[node.node_type](node, context, is_statement)
  end
end

---@class AstWalkerContext
---called before walking a node
---@field on_open fun(node: AstNode, context: AstWalkerContext, is_statement: boolean)|nil
---called after walking a node
---@field on_close fun(node: AstNode, context: AstWalkerContext, is_statement: boolean)|nil
---@field node_stack AstNode[]
---@field stat_stack AstStatement[]
---@field scope_stack AstScope[]

local function new_context(on_open, on_close)
  return {
    on_open = on_open,
    on_close = on_close,
    node_stack = stack.new_stack(),
    stat_stack = stack.new_stack(),
    scope_stack = stack.new_stack(),
  }
end

local walk_stat
local walk_scope_internal

local walk_exp
local walk_exp_list

---@param node AstCall
local function walk_call(node, context)
  walk_exp(node.ex, context)
  walk_exp_list(node.args, context)
end

---@param node AstFuncBase
local function walk_func_base(node, context)
  walk_scope_internal(node.func_def, context)
end

-- all the empty functions could be removed from this
-- and probably should
-- but for now it's a nice validation that all the node_types are correct
-- ... unit tests where are you?!
local exprs = {
  ---@param node AstLocalReference
  local_ref = function(node, context)
  end,
  ---@param node AstUpvalReference
  upval_ref = function(node, context)
  end,
  ---@param node AstIndex
  index = function(node, context)
    walk_exp(node.ex, context)
    walk_exp(node.suffix, context)
  end,
  ---@param node AstString
  string = function(node, context)
  end,
  ---@param node AstUnOp
  unop = function(node, context)
    walk_exp(node.ex, context)
  end,
  ---@param node AstBinOp
  binop = function(node, context)
    walk_exp(node.left, context)
    walk_exp(node.right, context)
  end,
  ---@param node AstConcat
  concat = function(node, context)
    walk_exp_list(node.exp_list, context)
  end,
  ---@param node AstNumber
  number = function(node, context)
  end,
  ---@param node AstNil
  ["nil"] = function(node, context)
  end,
  ---@param node AstBoolean
  boolean = function(node, context)
  end,
  ---@param node AstVarArg
  vararg = function(node, context)
  end,
  ---@param node AstFuncProto
  func_proto = function(node, context)
    walk_func_base(node, context)
  end,
  ---@param node AstConstructor
  constructor = function(node, context)
    ---@type AstListField|AstRecordField
    for _, field in ipairs(node.fields) do
      if field.type == "list" then
        -- ---@narrow field AstListField
        walk_exp(field.value, context)
      else
        -- ---@narrow field AstRecordField
        walk_exp(field.key, context)
        walk_exp(field.value, context)
      end
    end
  end,

  call = walk_call,

  ---@param node AstInlineIIFE
  inline_iife = function(node, context)
    walk_scope_internal(node, context)
  end,
}

---@param node AstExpression
---@param context AstWalkerContext
function walk_exp(node, context)
  stack.push(context.node_stack, node)
  dispatch(context.on_open, node, context, false)
  exprs[node.node_type](node, context)
  dispatch(context.on_close, node, context, false)
  stack.pop(context.node_stack)
end

---@param list AstExpression[]
---@param context AstWalkerContext
function walk_exp_list(list, context)
  for _, expr in ipairs(list) do
    walk_exp(expr, context)
  end
end

---@param testblock AstTestBlock
---@param context AstWalkerContext
local function walk_testblock(testblock, context)
  stack.push(context.node_stack, testblock)
  walk_exp(testblock.condition, context)
  walk_scope_internal(testblock, context)
  stack.pop(context.node_stack)
end

---@param elseblock AstElseBlock
---@param context AstWalkerContext
local function walk_elseblock(elseblock, context)
  stack.push(context.node_stack, elseblock)
  walk_scope_internal(elseblock, context)
  stack.pop(context.node_stack)
end

-- same here, empty functions could and should be removed
local stats = {
  ---@param node AstEmpty
  empty = function(node, context)
  end,
  ---@param node AstIfStat
  ifstat = function(node, context)
    for _, testblock in ipairs(node.ifs) do
      walk_testblock(testblock, context)
    end
    if node.elseblock then
      walk_elseblock(node.elseblock, context)
    end
  end,
  ---@param node AstWhileStat
  whilestat = function(node, context)
    walk_exp(node.condition, context)
    walk_scope_internal(node, context)
  end,
  ---@param node AstDoStat
  dostat = function(node, context)
    walk_scope_internal(node, context)
  end,
  ---@param node AstForNum
  fornum = function(node, context)
    walk_exp(node.var, context)
    walk_exp(node.start, context)
    walk_exp(node.stop, context)
    if node.step then
      walk_exp(node.step, context)
    end
    walk_scope_internal(node, context)
  end,
  ---@param node AstForList
  forlist = function(node, context)
    walk_exp_list(node.name_list, context)
    walk_exp_list(node.exp_list, context)
    walk_scope_internal(node, context)
  end,
  ---@param node AstRepeatStat
  repeatstat = function(node, context)
    walk_scope_internal(node, context)
    walk_exp(node.condition, context)
  end,
  ---@param node AstFuncStat
  funcstat = function(node, context)
    walk_exp(node.name, context)
    walk_func_base(node, context)
  end,
  ---@param node AstLocalFunc
  localfunc = function(node, context)
    walk_exp(node.name, context)
    walk_func_base(node, context)
  end,
  ---@param node AstLocalStat
  localstat = function(node, context)
    walk_exp_list(node.lhs, context)
    if node.rhs then
      walk_exp_list(node.rhs, context)
    end
  end,
  ---@param node AstLabel
  label = function(node, context)
  end,
  ---@param node AstRetStat
  retstat = function(node, context)
    if node.exp_list then
      walk_exp_list(node.exp_list, context)
    end
  end,
  ---@param node AstBreakStat
  breakstat = function(node, context)
  end,
  ---@param node AstGotoStat
  gotostat = function(node, context)
  end,
  ---@param node AstAssignment
  assignment = function(node, context)
    walk_exp_list(node.lhs, context)
    walk_exp_list(node.rhs, context)
  end,

  call = walk_call,

  ---@param node AstInlineIIFERetstat
  inline_iife_retstat = function(node, context)
    if node.exp_list then
      walk_exp_list(node.exp_list, context)
    end
  end,
  ---@param node AstDoStat
  loopstat = function(node, context)
    walk_scope_internal(node, context)
  end,
}

---@param stat AstStatement
---@param context AstWalkerContext
function walk_stat(stat, context)
  stack.push(context.node_stack, stat)
  stack.push(context.stat_stack, stat)
  dispatch(context.on_open, stat, context, true)
  if ill.is_alive(stat) then
    stats[stat.node_type](stat, context)
  end
  dispatch(context.on_close, stat, context, true)
  stack.pop(context.stat_stack)
  stack.pop(context.node_stack)
  -- If stat has been removed from the list we must trust that
  -- its `next` is still correctly pointing to the next statement.
  -- This is ensured if the removal was the last operation on the statement list.
end

function walk_scope_internal(node, context)
  stack.push(context.scope_stack, node)
  local stat = node.body.first
  while stat do
    walk_stat(stat, context)
    stat = stat.next
  end
  stack.pop(context.scope_stack)
end

---@param node AstScope
---@param context AstWalkerContext
local function walk_scope(node, context)
  stack.push(context.node_stack, node)
  walk_scope_internal(node, context)
  stack.pop(context.node_stack)
end

return {
  new_context = new_context,
  walk_scope = walk_scope,
  walk_testblock = walk_testblock,
  walk_elseblock = walk_elseblock,
  walk_stat = walk_stat,
  walk_exp = walk_exp,
  walk_exp_list = walk_exp_list,
}
