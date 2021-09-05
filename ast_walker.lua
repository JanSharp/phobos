
---@param main AstMain
local function walk(main, on_open, on_close)
  local current_scope

  local function dispatch(listeners, node, is_statement)
    if listeners and listeners[node.node_type] then
      listeners[node.node_type](node, current_scope, is_statement)
    end
  end

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
    walk_body(node.func_def)
  end

  -- all the empty functions could be removed from this
  -- and probably should
  -- but for now it's a nice validation that all the node_types are correct
  -- ... unit tests where are you?!
  local exprs = {
    ---@param node AstLocalReference
    local_ref = function(node)
    end,
    ---@param node AstUpvalReference
    upval_ref = function(node)
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
      walk_exp_list(node.exp_list)
    end,
    ---@param node AstNumber
    number = function(node)
    end,
    ---@param node AstNil
    ["nil"] = function(node)
    end,
    ---@param node AstBoolean
    boolean = function(node)
    end,
    ---@param node AstVarArg
    vararg = function(node)
    end,
    ---@param node AstFuncProto
    func_proto = function(node)
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

    ---@param node AstInlineIIFE
    inline_iife = function(node)
      walk_body(node)
    end,
  }

  ---@param node AstExpression
  function walk_exp(node, allow_deletion)
    dispatch(on_open, node, false)
    exprs[node.node_type](node)
    dispatch(on_close, node, false)
    ---@diagnostic disable-next-line: undefined-field
    if node.to_delete and (not allow_deletion) then
      error("Attempt to delete node '"..node.node_type.."' when it wasn't in an expression list.")
    end
  end

  ---@param list AstExpression[]
  function walk_exp_list(list)
    local i = 1
    local c = #list
    while i <= c do
      walk_exp(list[i], true)
      ---@diagnostic disable-next-line: undefined-field
      if list[i].to_delete then
        table.remove(list, i)
        i = i - 1
        c = c - 1
      end
      i = i + 1
    end
  end

  -- same here, empty functions could and should be removed
  local stats = {
    ---@param node AstEmpty
    empty = function(node)
    end,
    ---@param node AstIfStat
    ifstat = function(node)
      local i = 1
      local c = #node.ifs
      while i <= c do
        walk_stat(node.ifs[i])
        ---@diagnostic disable-next-line: undefined-field
        if node.ifs[i].to_delete then
          table.remove(node.ifs, i)
          i = i - 1
          c = c - 1
        end
        i = i + 1
      end
      if node.elseblock then
        walk_stat(node.elseblock)
        ---@diagnostic disable-next-line: undefined-field
        if node.elseblock.to_delete then
          node.elseblock = nil
        end
      end
    end,
    ---@param node AstTestBlock
    testblock = function(node)
      walk_exp(node.condition)
      walk_body(node)
    end,
    ---@param node AstElseBlock
    elseblock = function(node)
      walk_body(node)
    end,
    ---@param node AstWhileStat
    whilestat = function(node)
      walk_exp(node.condition)
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
      walk_exp_list(node.name_list)
      walk_exp_list(node.exp_list)
      walk_body(node)
    end,
    ---@param node AstRepeatStat
    repeatstat = function(node)
      walk_body(node)
      walk_exp(node.condition)
    end,
    ---@param node AstFuncStat
    funcstat = function(node)
      walk_exp(node.name)
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
      if node.rhs then
        walk_exp_list(node.rhs)
      end
    end,
    ---@param node AstLabel
    label = function(node)
    end,
    ---@param node AstRetStat
    retstat = function(node)
      if node.exp_list then
        walk_exp_list(node.exp_list)
      end
    end,
    ---@param node AstBreakStat
    breakstat = function(node)
    end,
    ---@param node AstGotoStat
    gotostat = function(node)
    end,
    ---@param node AstAssignment
    assignment = function(node)
      walk_exp_list(node.lhs)
      walk_exp_list(node.rhs)
    end,

    selfcall = selfcall,
    call = call,

    ---@param node AstInlineIIFERetstat
    inline_iife_retstat = function(node)
      if node.exp_list then
        walk_exp_list(node.exp_list)
      end
    end,
  }

  ---@param node AstStatement
  function walk_stat(node)
    dispatch(on_open, node, true)
    stats[node.node_type](node)
    dispatch(on_close, node, true)
  end

  ---@param node AstBody[]
  function walk_body(node)
    local prev_scope = current_scope
    current_scope = node
    local i = 1
    local c = #node.body
    while i <= c do
      walk_stat(node.body[i])
      ---@diagnostic disable-next-line: undefined-field
      if node.body[i].to_delete then
        table.remove(node.body, i)
        i = i - 1
        c = c - 1
      end
      i = i + 1
    end
    current_scope = prev_scope
  end

  walk_body(main)
end

return walk