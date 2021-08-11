
local walk_stat
local walk_body

local walk_exp
local walk_exp_list

---@param node AstSelfCall
local function selfcall(node)
  walk_exp_list(node.args)
  walk_exp(node.ex)
end

---@param node AstCall
local function call(node)
  walk_exp_list(node.args)
  walk_exp(node.ex)
end

---@param node AstFuncBase
local function walk_func_base(node)
  for i = 1, node.ref.nparams do
    walk_exp(node.ref.locals[i])
  end
  walk_body(node.ref)
end

local exprs = {
  ---@param node AstLocal
  ["local"] = function(node)
  end,
  ---@param node AstUpVal
  upval = function(node)
  end,
  ---@param node AstIndex
  index = function(node)
    walk_exp(node.ex)
    walk_exp(node.suffix)
  end,
  ---@param node AstString
  string = function(node)
  end,
  ---@param node AstIdent
  ident = function(node)
  end,
  ---@param node Ast_ENV
  _ENV = function(node)
  end,
  ---@param node AstUnOp
  unop = function(node)
    walk_exp(node.ex)
  end,
  ---@param node AstBinOp
  binop = function(node)
    walk_exp(node.left)
    walk_exp(node.right)
  end,
  ---@param node AstConcat
  concat = function(node)
    walk_exp_list(node.explist)
  end,
  ---@param node AstNumber
  number = function(node)
  end,
  ---@param node AstNil
  ["nil"] = function(node)
  end,
  ---@param node AstTrue
  ["true"] = function(node)
  end,
  ---@param node AstFalse
  ["false"] = function(node)
  end,
  ---@param node AstVarArg
  ["..."] = function(node)
  end,
  ---@param node AstFuncProto
  funcproto = function(node)
    walk_func_base(node)
  end,
  ---@param node AstConstructor
  constructor = function(node)
    for _, field in ipairs(node.fields) do
      if field.type == "list" then
        ---@narrow field AstListField
        walk_exp(field.value)
      else
        ---@narrow field AstRecordField
        walk_exp(field.key)
        walk_exp(field.value)
      end
    end
  end,

  selfcall = selfcall,
  call = call,
}

---@param node AstExpression
function walk_exp(node)
  exprs[node.token](node)
end

---@param list AstExpression[]
function walk_exp_list(list)
  for _, node in ipairs(list) do
    walk_exp(node)
  end
end

local stats = {
  ---@param node AstEmpty
  empty = function(node)
  end,
  ---@param node AstIfStat
  ifstat = function(node)
    for _, test_block in ipairs(node.ifs) do
      walk_stat(test_block)
    end
    if node.elseblock then
      walk_stat(node.elseblock)
    end
  end,
  ---@param node AstTestBlock
  testblock = function(node)
    walk_exp(node.cond)
    walk_body(node)
  end,
  ---@param node AstElseBlock
  elseblock = function(node)
    walk_body(node)
  end,
  ---@param node AstWhileStat
  whilestat = function(node)
    walk_exp(node.cond)
    walk_body(node)
  end,
  ---@param node AstDoStat
  dostat = function(node)
    walk_body(node)
  end,
  ---@param node AstForNum
  fornum = function(node)
    walk_exp(node.var)
    walk_exp(node.start)
    walk_exp(node.stop)
    if node.step then
      walk_exp(node.step)
    end
    walk_body(node)
  end,
  ---@param node AstForList
  forlist = function(node)
    walk_exp_list(node.namelist)
    walk_exp_list(node.explist)
    walk_body(node)
  end,
  ---@param node AstRepeatStat
  repeatstat = function(node)
    walk_body(node)
    walk_exp(node.cond)
  end,
  ---@param node AstFuncStat
  funcstat = function(node)
    walk_exp_list(node.names)
    walk_func_base(node)
  end,
  ---@param node AstLocalFunc
  localfunc = function(node)
    walk_exp(node.name)
    walk_func_base(node)
  end,
  ---@param node AstLocalStat
  localstat = function(node)
    walk_exp_list(node.lhs)
    walk_exp_list(node.rhs)
  end,
  ---@param node AstLabel
  label = function(node)
    walk_exp(node.value)
  end,
  ---@param node AstRetStat
  retstat = function(node)
    if node.explist then
      walk_exp_list(node.explist)
    end
  end,
  ---@param node AstBreakStat
  breakstat = function(node)
  end,
  ---@param node AstGotoStat
  gotostat = function(node)
    walk_exp(node.target)
  end,
  ---@param node AstAssignment
  assignment = function(node)
    walk_exp_list(node.lhs)
    walk_exp_list(node.rhs)
  end,

  selfcall = selfcall,
  call = call,
}

---@param node AstStatement
function walk_stat(node)
  stats[node.token](node)
end

---@param node AstBody[]
function walk_body(node)
  for _, sub_node in ipairs(node.body) do
    walk_stat(sub_node)
  end
end

---@param main AstMain
local function format(main)
  walk_body(main)
end

return format