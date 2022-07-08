
-- NOTE: this is not written with incomplete nodes in mind. It might work with most of them, but
-- for now consider that undefined behavior. _for now_.
-- I mean this entire file is not the most useful right now

---@param main AstMain
local function format(main)
  local out = {}

  local add_stat
  local add_scope

  local add_exp
  local add_exp_list

  local exprs
  local add_token
  local add_invalid

  local function add(part)
    out[#out+1] = part
  end

  local function add_node(node)
    if node.node_type == "token" then
      add_token(node)
    elseif node.node_type == "invalid" then
      add_invalid(node)
    elseif exprs[node.node_type] then
      add_exp(node)
    else
      add_stat(node)
    end
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
    for _, token in ipairs(node.leading) do
      if token.token_type == "blank" or token.token_type == "comment" then
        add_token(token)
      else
        error("Invalid leading token_type '"..token.token_type.."'.")
      end
    end
  end

  function add_token(token_node)
    if not token_node then
      return
    end
    if token_node.leading then
      add_leading(token_node)
    end
    if token_node.token_type == "blank" then
      add(token_node.value)
    elseif token_node.token_type == "comment" then
      add("--")
      if token_node.src_is_block_str then
        add_string(token_node)
      else
        add(token_node.value)
      end
    elseif token_node.token_type == "string" then
      add_string(token_node)
    elseif token_node.token_type == "number" then
      add(token_node.src_value)
    elseif token_node.token_type == "ident" then
      add(token_node.value)
    elseif token_node.token_type == "eof" then
      -- nothing
    elseif token_node.token_type == "invalid" then
      add(token_node.value)
    else
      add(token_node.token_type)
    end
  end

  function add_invalid(node)
    for _, consumed_node in ipairs(node.consumed_nodes) do
      add_node(consumed_node)
    end
  end

  ---@param node AstCall
  local function call(node)
    add_exp(node.ex)
    if node.is_selfcall then
      add_token(node.colon_token)
      add_exp(node.suffix)
    end
    if node.open_paren_token then
      add_token(node.open_paren_token)
    end
    add_exp_list(node.args, node.args_comma_tokens)
    if node.close_paren_token then
      add_token(node.close_paren_token)
    end
  end

  ---@param node AstFunctionDef|AstMain
  local function add_functiondef(node, add_name)
    if node.is_main then
      add_scope(node)
      add_leading(node.eof_token)
    else
      add_token(node.function_token)
      if add_name then
        add_name()
      end
      add_token(node.open_paren_token)
      add_exp_list(node.params, node.param_comma_tokens)
      if node.is_vararg then
        add_token(node.vararg_token)
      end
      add_token(node.close_paren_token)
      add_scope(node)
      add_token(node.end_token)
    end
  end

  exprs = {
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
        elseif node.suffix.node_type == "invalid" then
          if node.dot_token then add_token(node.dot_token) end
          if node.suffix_open_token then add_token(node.suffix_open_token) end
          add_invalid(node.suffix)
          if node.suffix_close_token then add_token(node.suffix_close_token) end
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
      add_exp_list(node.exp_list, node.op_tokens, node.concat_src_paren_wrappers)
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
      add_functiondef(node.func_def)
    end,
    ---@param node AstConstructor
    constructor = function(node)
      add_token(node.open_token)
      ---@type AstListField|AstRecordField
      for i, field in ipairs(node.fields) do
        if field.type == "list" then
          ---@cast field AstListField
          add_exp(field.value)
        else
          ---@cast field AstRecordField
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

    call = call,

    invalid = add_invalid,

    ---@param node AstInlineIIFE
    inline_iife = function(node)
      error("Cannot format 'inline_iife' nodes.")
    end,
  }

  ---@param node AstExpression
  function add_exp(node)
    if node.force_single_result and node.node_type ~= "concat" then
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
  function add_exp_list(list, separator_tokens, concat_src_paren_wrappers)
    ---cSpell:ignore cspw
    local cspw = concat_src_paren_wrappers
    for i, node in ipairs(list) do
      if cspw and cspw[i] then
        for j = #cspw[i], 1, -1 do
          add_token(cspw[i][j].open_paren_token)
        end
      end
      add_exp(node)
      if separator_tokens[i] then
        add_token(separator_tokens[i])
      end
    end
    if cspw then
      for i = #list - 1, 1, -1 do
        for j = 1, #cspw[i] do
          add_token(cspw[i][j].close_paren_token)
        end
      end
    end
  end

  ---@type table<AstStatement|AstTestBlock|AstElseBlock, fun(node: AstStatement|AstTestBlock|AstElseBlock)>
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
      add_scope(node)
    end,
    ---@param node AstElseBlock
    elseblock = function(node)
      add_token(node.else_token)
      add_scope(node)
    end,
    ---@param node AstWhileStat
    whilestat = function(node)
      add_token(node.while_token)
      add_exp(node.condition)
      add_token(node.do_token)
      add_scope(node)
      add_token(node.end_token)
    end,
    ---@param node AstDoStat
    dostat = function(node)
      add_token(node.do_token)
      add_scope(node)
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
      add_scope(node)
      add_token(node.end_token)
    end,
    ---@param node AstForList
    forlist = function(node)
      add_token(node.for_token)
      add_exp_list(node.name_list, node.comma_tokens)
      add_token(node.in_token)
      add_exp_list(node.exp_list, node.exp_list_comma_tokens)
      add_token(node.do_token)
      add_scope(node)
      add_token(node.end_token)
    end,
    ---@param node AstRepeatStat
    repeatstat = function(node)
      add_token(node.repeat_token)
      add_scope(node)
      add_token(node.until_token)
      add_exp(node.condition)
    end,
    ---@param node AstFuncStat
    funcstat = function(node)
      add_functiondef(node.func_def, function()
        if node.func_def.is_method then
          assert(node.name.node_type == "index")
          ---@diagnostic disable-next-line: undefined-field
          assert(node.name.dot_token.token_type == ":")
        end
        add_exp(node.name)
      end)
    end,
    ---@param node AstLocalFunc
    localfunc = function(node)
      add_token(node.local_token)
      add_functiondef(node.func_def, function()
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
      add(node.target_name)
    end,
    ---@param node AstAssignment
    assignment = function(node)
      add_exp_list(node.lhs, node.lhs_comma_tokens)
      add_token(node.eq_token)
      add_exp_list(node.rhs, node.rhs_comma_tokens)
    end,

    call = call,

    invalid = add_invalid,

    ---@param node AstInlineIIFERetstat
    inline_iife_retstat = function(node)
      error("Cannot format 'inline_iife_retstat' nodes.")
    end,
    ---@param node AstWhileStat
    loopstat = function(node)
      error("Cannot format 'loopstat' nodes.")
    end,
  }

  ---@param node AstStatement|AstTestBlock|AstElseBlock
  function add_stat(node)
    stats[node.node_type](node)
  end

  ---@param node AstScope
  function add_scope(node)
    local stat = node.body.first
    while stat do
      add_stat(stat--[[@as AstStatement]])
      stat = stat.next
    end
  end

  add_functiondef(main)

  -- dirty way of ensuring formatted code doesn't combine identifiers (or keywords or numbers)
  -- one line comments without a blank token afterwards with a newline in its value can still
  -- "break" formatted code in the sense that it changes the general AST structure, or most likely
  -- causes a syntax error when parsed again
  do
    local prev = out[1]
    local i = 2
    local c = #out
    while i <= c do
      local cur = out[i]
      if cur ~= "" then
        -- there is at least 1 case where this adds an extra space where it doesn't need to,
        -- which is for something like `0xk` where 0x is a malformed number and k is an identifier
        -- but yea, I only know of this one case where it's only with invalid nodes anyway...
        -- all in all this logic here shouldn't be needed at all, i just added it for fun
        -- to see if it would work
        if prev:find("[a-z_A-Z0-9]$") and cur:find("^[a-z_A-Z0-9]") then
          table.insert(out, i, " ")
          i = i + 1
          c = c + 1
        end
        prev = cur
      end
      i = i + 1
    end
  end

  return table.concat(out)
end

return format
