
---@param main AstMain
local function format(main)
  local out = {}

  local add_stat
  local add_body

  local add_exp
  local add_exp_list

  local function add(part)
    out[#out+1] = part
  end

  local function add_string(str)
    if str.src_is_ident then
      add(str.value)
    elseif str.src_is_block_str then
      add("[")
      add(str.src_pad)
      add("[")
      if str.src_has_leading_newline then
        add("\n")
      end
      add(str.value)
      add("]")
      add(str.src_pad)
      add("]")
    else -- regular string
      add(str.src_quote)
      add(str.src_value)
      add(str.src_quote)
    end
  end

  local function add_leading(node)
    ---@type Token
    for _, token in ipairs(node.leading) do
      if token.token_type == "blank" then
        add(token.value)
      elseif token.token_type == "comment" then
        add("--")
        if token.src_is_block_str then
          add_string(token)
        else
          add(token.value)
        end
      else
        error("Invalid token_type '"..token.token_type.."'.")
      end
    end
  end

  local function add_token(token_node)
    add_leading(token_node)
    add(token_node.value)
  end

  ---@param node AstSelfCall
  local function selfcall(node)
    add_exp(node.ex)
    add_token(node.colon_token)
    add_exp(node.suffix)
    if node.open_paren_token then
      add_token(node.open_paren_token)
    end
    add_exp_list(node.args, node.args_comma_tokens)
    if node.close_paren_token then
      add_token(node.close_paren_token)
    end
  end

  ---@param node AstCall
  local function call(node)
    add_exp(node.ex)
    if node.open_paren_token then
      add_token(node.open_paren_token)
    end
    add_exp_list(node.args, node.args_comma_tokens)
    if node.close_paren_token then
      add_token(node.close_paren_token)
    end
  end

  ---@param node AstFuncBase|AstMain
  local function add_func_base(node, add_name)
    if not node.is_main then
      add_token(node.func_def.function_token)
      if add_name then
        add_name()
      end
      add_token(node.func_def.open_paren_token)
      add_exp_list(node.func_def.params, node.func_def.param_comma_tokens)
      if node.func_def.is_vararg then
        add_token(node.func_def.vararg_token)
      end
      add_token(node.func_def.close_paren_token)
      add_body(node.func_def)
      add_token(node.func_def.end_token)
    else
      add_body(node.func_def)
    end
  end

  local exprs = {
    ---@param node AstLocalReference
    local_ref = function(node)
      add_leading(node)
      add(node.name)
    end,
    ---@param node AstUpvalReference
    upval_ref = function(node)
      add_leading(node)
      add(node.name)
    end,
    ---@param node AstIndex
    index = function(node)
      if node.src_ex_did_not_exist then
        add_exp(node.suffix)
      else
        add_exp(node.ex)
        ---@diagnostic disable-next-line: undefined-field
        if node.suffix.node_type == "string" and node.suffix.src_is_ident then
          add_token(node.dot_token)
          add_exp(node.suffix)
        else
          add_token(node.suffix_open_token)
          add_exp(node.suffix)
          add_token(node.suffix_close_token)
        end
      end
    end,
    ---@param node AstString
    string = function(node)
      add_leading(node)
      add_string(node)
    end,
    ---@param node AstIdent
    ident = function(node)
      add_leading(node)
      add(node.value)
    end,
    ---@param node AstUnOp
    unop = function(node)
      add_token(node.op_token)
      add_exp(node.ex)
    end,
    ---@param node AstBinOp
    binop = function(node)
      add_exp(node.left)
      add_token(node.op_token)
      add_exp(node.right)
    end,
    ---@param node AstConcat
    concat = function(node)
      add_exp_list(node.exp_list, node.op_tokens)
    end,
    ---@param node AstNumber
    number = function(node)
      add_leading(node)
      add(node.src_value)
    end,
    ---@param node AstNil
    ["nil"] = function(node)
      add_leading(node)
      add("nil")
    end,
    ---@param node AstBoolean
    boolean = function(node)
      add_leading(node)
      add(tostring(node.value))
    end,
    ---@param node AstVarArg
    vararg = function(node)
      add_leading(node)
      add("...")
    end,
    ---@param node AstFuncProto
    func_proto = function(node)
      add_func_base(node)
    end,
    ---@param node AstConstructor
    constructor = function(node)
      add_token(node.open_token)
      for i, field in ipairs(node.fields) do
        if field.type == "list" then
          ---@narrow field AstListField
          add_exp(field.value)
        else
          ---@narrow field AstRecordField
          ---@diagnostic disable-next-line: undefined-field
          if field.key.node_type == "string" and field.key.src_is_ident then
            add_exp(field.key)
          else
            add_token(field.key_open_token)
            add_exp(field.key)
            add_token(field.key_close_token)
          end
          add_token(field.eq_token)
          add_exp(field.value)
        end
        if node.comma_tokens[i] then
          add_token(node.comma_tokens[i])
        end
      end
      add_token(node.close_token)
    end,

    selfcall = selfcall,
    call = call,

    ---@param node AstInlineIIFE
    inline_iife = function(node)
      error("Cannot format 'inline_iife' nodes.")
    end,
  }

  ---@param node AstExpression
  function add_exp(node)
    if node.force_single_result then
      for i = #node.src_paren_wrappers, 1, -1 do
        add_token(node.src_paren_wrappers[i].open_paren_token)
      end
      exprs[node.node_type](node)
      for i = 1, #node.src_paren_wrappers do
        add_token(node.src_paren_wrappers[i].close_paren_token)
      end
    else
      exprs[node.node_type](node)
    end
  end

  ---@param list AstExpression[]
  function add_exp_list(list, separator_tokens)
    for i, node in ipairs(list) do
      add_exp(node)
      if separator_tokens[i] then
        add_token(separator_tokens[i])
      end
    end
  end

  local stats = {
    ---@param node AstEmpty
    empty = function(node)
      add_token(node.semi_colon_token)
    end,
    ---@param node AstIfStat
    ifstat = function(node)
      for _, test_block in ipairs(node.ifs) do
        add_stat(test_block)
      end
      if node.elseblock then
        add_stat(node.elseblock)
      end
      add_token(node.end_token)
    end,
    ---@param node AstTestBlock
    testblock = function(node)
      add_token(node.if_token)
      add_exp(node.condition)
      add_token(node.then_token)
      add_body(node)
    end,
    ---@param node AstElseBlock
    elseblock = function(node)
      add_token(node.else_token)
      add_body(node)
    end,
    ---@param node AstWhileStat
    whilestat = function(node)
      add_token(node.while_token)
      add_exp(node.condition)
      add_token(node.do_token)
      add_body(node)
      add_token(node.end_token)
    end,
    ---@param node AstDoStat
    dostat = function(node)
      add_token(node.do_token)
      add_body(node)
      add_token(node.end_token)
    end,
    ---@param node AstForNum
    fornum = function(node)
      add_token(node.for_token)
      add_exp(node.var)
      add_token(node.eq_token)
      add_exp(node.start)
      add_token(node.first_comma_token)
      add_exp(node.stop)
      if node.step then
        add_token(node.second_comma_token)
        add_exp(node.step)
      end
      add_token(node.do_token)
      add_body(node)
      add_token(node.end_token)
    end,
    ---@param node AstForList
    forlist = function(node)
      add_token(node.for_token)
      add_exp_list(node.name_list, node.comma_tokens)
      add_token(node.in_token)
      add_exp_list(node.exp_list, node.exp_list_comma_tokens)
      add_token(node.do_token)
      add_body(node)
      add_token(node.end_token)
    end,
    ---@param node AstRepeatStat
    repeatstat = function(node)
      add_token(node.repeat_token)
      add_body(node)
      add_token(node.until_token)
      add_exp(node.condition)
    end,
    ---@param node AstFuncStat
    funcstat = function(node)
      add_func_base(node, function()
        if node.func_def.is_method then
          assert(node.name.node_type == "index")
          ---@diagnostic disable-next-line: undefined-field
          assert(node.name.dot_token.value == ":")
        end
        add_exp(node.name)
      end)
    end,
    ---@param node AstLocalFunc
    localfunc = function(node)
      add_token(node.local_token)
      add_func_base(node, function()
        add_exp(node.name)
      end)
    end,
    ---@param node AstLocalStat
    localstat = function(node)
      add_token(node.local_token)
      add_exp_list(node.lhs, node.lhs_comma_tokens)
      if node.rhs then
        add_token(node.eq_token)
        add_exp_list(node.rhs, node.rhs_comma_tokens)
      end
    end,
    ---@param node AstLabel
    label = function(node)
      add_token(node.open_token)
      add_leading(node.name_token) -- value is nil
      add(node.name)
      add_token(node.close_token)
    end,
    ---@param node AstRetStat
    retstat = function(node)
      add_token(node.return_token)
      if node.exp_list then
        add_exp_list(node.exp_list, node.exp_list_comma_tokens)
      end
      if node.semi_colon_token then
        add_token(node.semi_colon_token)
      end
    end,
    ---@param node AstBreakStat
    breakstat = function(node)
      add_token(node.break_token)
    end,
    ---@param node AstGotoStat
    gotostat = function(node)
      add_token(node.goto_token)
      add_leading(node.target_token) -- value is nil
      add(node.target)
    end,
    ---@param node AstAssignment
    assignment = function(node)
      add_exp_list(node.lhs, node.lhs_comma_tokens)
      add_token(node.eq_token)
      add_exp_list(node.rhs, node.rhs_comma_tokens)
    end,

    selfcall = selfcall,
    call = call,

    ---@param node AstInlineIIFERetstat
    inline_iife_retstat = function(node)
      error("Cannot format 'inline_iife_retstat' nodes.")
    end,
  }

  ---@param node AstStatement
  function add_stat(node)
    stats[node.node_type](node)
  end

  ---@param node AstBody[]
  function add_body(node)
    for _, sub_node in ipairs(node.body) do
      add_stat(sub_node)
    end
  end

  add_body(main)
  add_leading(main.eof_token)
  return table.concat(out)
end

return format