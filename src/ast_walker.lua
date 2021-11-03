
local ill = require("indexed_linked_list")

local function dispatch(listeners, node, is_statement, context, list_elem)
  if listeners and listeners[node.node_type] then
    listeners[node.node_type](node, context, is_statement, list_elem)
  end
end

local walk_stat
local walk_scope

local walk_exp
local walk_exp_list

---@param node AstSelfCall
local function selfcall(node, context)
  walk_exp(node.ex, context)
  walk_exp_list(node.args, context)
end

---@param node AstCall
local function call(node, context)
  walk_exp(node.ex, context)
  walk_exp_list(node.args, context)
end

---@param node AstFuncBase
local function walk_func_base(node, context)
  walk_scope(node.func_def, context)
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
  ---@param node AstIdent
  ident = function(node, context)
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

  selfcall = selfcall,
  call = call,

  ---@param node AstInlineIIFE
  inline_iife = function(node, context)
    walk_scope(node, context)
  end,
}

---@param node AstExpression
---@param context AstWalkerContext
function walk_exp(node, context)
  dispatch(context.on_open, node, false, context)
  exprs[node.node_type](node, context)
  dispatch(context.on_close, node, false, context)
end

---@param list AstExpression[]
function walk_exp_list(list, context)
  for _, expr in ipairs(list) do
    walk_exp(expr, context)
  end
end

-- same here, empty functions could and should be removed
local stats = {
  ---@param node AstEmpty
  empty = function(node, context)
  end,
  ---@param node AstIfStat
  ifstat = function(node, context)
    for _, ifstat in ipairs(node.ifs) do
      walk_stat(ifstat, context)
    end
    if node.elseblock then
      walk_stat(node.elseblock, context)
    end
  end,
  ---@param node AstTestBlock
  testblock = function(node, context)
    walk_exp(node.condition, context)
    walk_scope(node, context)
  end,
  ---@param node AstElseBlock
  elseblock = function(node, context)
    walk_scope(node, context)
  end,
  ---@param node AstWhileStat
  whilestat = function(node, context)
    walk_exp(node.condition, context)
    walk_scope(node, context)
  end,
  ---@param node AstDoStat
  dostat = function(node, context)
    walk_scope(node, context)
  end,
  ---@param node AstForNum
  fornum = function(node, context)
    walk_exp(node.var, context)
    walk_exp(node.start, context)
    walk_exp(node.stop, context)
    if node.step then
      walk_exp(node.step, context)
    end
    walk_scope(node, context)
  end,
  ---@param node AstForList
  forlist = function(node, context)
    walk_exp_list(node.name_list, context)
    walk_exp_list(node.exp_list, context)
    walk_scope(node, context)
  end,
  ---@param node AstRepeatStat
  repeatstat = function(node, context)
    walk_scope(node, context)
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

  selfcall = selfcall,
  call = call,

  ---@param node AstInlineIIFERetstat
  inline_iife_retstat = function(node, context)
    if node.exp_list then
      walk_exp_list(node.exp_list, context)
    end
  end,
  ---@param node AstDoStat
  loopstat = function(node, context)
    walk_scope(node, context)
  end,
}

---@param stat AstStatement
---@param context AstWalkerContext
---@param stat_elem ILLNode<nil,AstStatement>|nil
function walk_stat(stat, context, stat_elem)
  dispatch(context.on_open, stat, true, context, stat_elem)
  if not stat_elem or ill.is_alive(stat_elem) then
    stats[stat.node_type](stat, context)
  end
  dispatch(context.on_close, stat, true, context, stat_elem)
  -- if stat_elem has been removed from the list, we must trust that
  -- its `next` is still correctly pointing to the next element
  -- this is ensured if the removal was the last operation on the statement list
end

---@param node AstScope
---@param context AstWalkerContext
function walk_scope(node, context)
  local prev_scope = context.scope
  context.scope = node
  local elem = node.body.first
  while elem do
    walk_stat(elem.value, context, elem)
    elem = elem.next
  end
  context.scope = prev_scope
end

---@class AstWalkerContext
---the scope the statement or expression is in.\
---should only be `nil` when passing it to walk_scope, since that will then set the scope
---@field scope AstScope|nil
---called before walking a node
---`stat_elem` is `nil` for `testblock` and `elseblock` because those are not directly in a statement list
---@field on_open fun(node: AstNode, scope: AstScope, is_statement: boolean, stat_elem: ILLNode<nil,AstStatement>)|nil
---called after walking a node
---`stat_elem` is `nil` for `testblock` and `elseblock` because those are not directly in a statement list
---@field on_close fun(node: AstNode, scope: AstScope, is_statement: boolean, stat_elem: ILLNode<nil,AstStatement>)|nil

return {
  walk_scope = walk_scope,
  walk_stat = walk_stat,
  walk_exp = walk_exp,
}
