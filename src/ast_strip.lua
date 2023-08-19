
local ast_walker = require("ast_walker")

-- This file strips all token nodes, lines, columns, leading and source from all ast nodes.

---@param func_def AstFunctionDef
local function strip_func_def(func_def)
  func_def.source = nil
  if func_def.is_main then
    func_def.eof_token = nil
    return
  end
  func_def.function_token = nil
  func_def.open_paren_token = nil
  func_def.param_comma_tokens = nil
  func_def.vararg_token = nil
  func_def.close_paren_token = nil
  func_def.end_token = nil
end

---@param node AstExpression
local function strip_expr_internal(node)
  node.src_paren_wrappers = nil
end

---@param node AstExpression
local function strip_line_column_leading(node)
  node.line = nil
  node.column = nil
  node.leading = nil
end

local walker_context = ast_walker.new_context{
  -- Special:
  ---@param node AstFunctionDef
  ["functiondef"] = function(node) -- For AstMain.
    strip_func_def(node)
  end,
  -- Statements:
  ---@param node AstEmpty
  ["empty"] = function(node)
    node.semi_colon_token = nil
  end,
  ---@param node AstIfStat
  ["ifstat"] = function(node)
    node.end_token = nil
  end,
  ---@param node AstTestBlock
  ["testblock"] = function(node)
    node.if_token = nil
    node.then_token = nil
  end,
  ---@param node AstElseBlock
  ["elseblock"] = function(node)
    node.else_token = nil
  end,
  ---@param node AstWhileStat
  ["whilestat"] = function(node)
    node.while_token = nil
    node.do_token = nil
    node.end_token = nil
  end,
  ---@param node AstDoStat
  ["dostat"] = function(node)
    node.do_token = nil
    node.end_token = nil
  end,
  ---@param node AstForNum
  ["fornum"] = function(node)
    node.for_token = nil
    node.eq_token = nil
    node.first_comma_token = nil
    node.second_comma_token = nil
    node.do_token = nil
    node.end_token = nil
  end,
  ---@param node AstForList
  ["forlist"] = function(node)
    node.for_token = nil
    node.comma_tokens = nil
    node.in_token = nil
    node.exp_list_comma_tokens = nil
    node.do_token = nil
    node.end_token = nil
  end,
  ---@param node AstRepeatStat
  ["repeatstat"] = function(node)
    node.repeat_token = nil
    node.until_token = nil
  end,
  ---@param node AstFuncStat
  ["funcstat"] = function(node)
    strip_func_def(node.func_def)
  end,
  ---@param node AstLocalStat
  ["localstat"] = function(node)
    node.local_token = nil
    node.lhs_comma_tokens = nil
    node.eq_token = nil
    node.rhs_comma_tokens = nil
  end,
  ---@param node AstLocalFunc
  ["localfunc"] = function(node)
    node.local_token = nil
    strip_func_def(node.func_def)
  end,
  ---@param node AstLabel
  ["label"] = function(node)
    node.open_token = nil
    node.name_token = nil
    node.close_token = nil
  end,
  ---@param node AstRetStat
  ["retstat"] = function(node)
    node.return_token = nil
    node.exp_list_comma_tokens = nil
    node.semi_colon_token = nil
  end,
  ---@param node AstBreakStat
  ["breakstat"] = function(node)
    node.break_token = nil
  end,
  ---@param node AstGotoStat
  ["gotostat"] = function(node)
    node.goto_token = nil
    node.target_token = nil
  end,
  ---@param node AstCall
  ["call"] = function(node, _, is_statement)
    node.colon_token = nil
    node.open_paren_token = nil
    node.args_comma_tokens = nil
    node.close_paren_token = nil
  end,
  ---@param node AstAssignment
  ["assignment"] = function(node)
    node.lhs_comma_tokens = nil
    node.eq_token = nil
    node.rhs_comma_tokens = nil
  end,
  -- Expressions:
  ---@param node AstLocalReference
  ["local_ref"] = function(node)
    strip_expr_internal(node)
    strip_line_column_leading(node)
  end,
  ---@param node AstUpvalReference
  ["upval_ref"] = function(node)
    strip_expr_internal(node)
    strip_line_column_leading(node)
  end,
  ---@param node AstIndex
  ["index"] = function(node)
    strip_expr_internal(node)
    node.dot_token = nil
    node.suffix_open_token = nil
    node.suffix_close_token = nil
  end,
  ---@param node AstUnOp
  ["unop"] = function(node)
    strip_expr_internal(node)
    node.op_token = nil
  end,
  ---@param node AstBinOp
  ["binop"] = function(node)
    strip_expr_internal(node)
    node.op_token = nil
  end,
  ---@param node AstConcat
  ["concat"] = function(node)
    strip_expr_internal(node)
    node.op_tokens = nil
  end,
  ---@param node AstNumber
  ["number"] = function(node)
    strip_expr_internal(node)
    strip_line_column_leading(node)
  end,
  ---@param node AstString
  ["string"] = function(node)
    strip_expr_internal(node)
    strip_line_column_leading(node)
  end,
  ---@param node AstNil
  ["nil"] = function(node)
    strip_expr_internal(node)
    strip_line_column_leading(node)
  end,
  ---@param node AstBoolean
  ["boolean"] = function(node)
    strip_expr_internal(node)
    strip_line_column_leading(node)
  end,
  ---@param node AstVarArg
  ["vararg"] = function(node)
    strip_expr_internal(node)
    strip_line_column_leading(node)
  end,
  ---@param node AstFuncProto
  ["func_proto"] = function(node)
    strip_expr_internal(node)
    strip_func_def(node.func_def)
  end,
  ---@param node AstConstructor
  ["constructor"] = function(node)
    strip_expr_internal(node)
    node.open_token = nil
    node.comma_tokens = nil
    node.close_token = nil
    for _, field in ipairs(node.fields) do
      if field.type == "rec" then
        ---@cast field AstRecordField
        field.key_open_token = nil
        field.key_close_token = nil
        field.eq_token = nil
      end
    end
  end,
}

---@param scope AstScope
local function strip_scope(scope)
  ast_walker.walk_scope(scope, walker_context)
  ast_walker.clean_context(walker_context)
end

---@param testblock AstTestBlock
local function strip_testblock(testblock)
  ast_walker.walk_testblock(testblock, walker_context)
  ast_walker.clean_context(walker_context)
end

---@param elseblock AstElseBlock
local function strip_elseblock(elseblock)
  ast_walker.walk_elseblock(elseblock, walker_context)
  ast_walker.clean_context(walker_context)
end

---@param stat AstStatement
local function strip_stat(stat)
  ast_walker.walk_stat(stat, walker_context)
  ast_walker.clean_context(walker_context)
end

---@param expr AstExpression
local function strip_exp(expr)
  ast_walker.walk_exp(expr, walker_context)
  ast_walker.clean_context(walker_context)
end

---@param list AstExpression[]
local function strip_exp_list(list)
  ast_walker.walk_exp_list(list, walker_context)
  ast_walker.clean_context(walker_context)
end

return {
  strip_scope = strip_scope,
  strip_testblock = strip_testblock,
  strip_elseblock = strip_elseblock,
  strip_stat = strip_stat,
  strip_exp = strip_exp,
  strip_exp_list = strip_exp_list,
}
