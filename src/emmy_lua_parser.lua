
local util = require("util")
local error_code_util = require("error_code_util")
local error_codes = error_code_util.codes

local function parse_sequence(sequence, source, positions)
  local line_index = 0
  local line
  local position
  local i
  local function next_line()
    line_index = line_index + 1
    line = sequence[line_index]
    position = positions[line_index]
    i = 1
  end

  local error_code_inst

  local function get_position(column_offset)
    -- position is nil if we are past the last line of the sequence
    return {
      -- positions will always contain 1 entry because empty sequences do not exist
      line = position and position.line or (positions[#positions].line + 1),
      column = position and (position.column + i - 1 + (column_offset or 0)) or 0,
    }
  end

  local function get_location_str()
    local pos = get_position()
    return " at "..pos.line..":"..pos.column
  end

  local function emmy_lua_abort(error_code, message_args)
    error_code_inst = error_code_util.new_error_code{
      error_code = error_code,
      position = get_position(),
      location_str = get_location_str(),
      source = source,
      message_args = message_args,
    }
    error() -- return to pcall
  end

  local function emmy_lua_assert(value, error_code, message_args)
    if value then
      return value
    end
    emmy_lua_abort(error_code, message_args)
  end

  local function parse_pattern(pattern)
    local _, stop, result = line:find("^"..pattern, i)
    if not stop then return end
    i = stop + 1
    return result or true
  end

  local function assert_parse_pattern(pattern)
    if not parse_pattern(pattern) then
      emmy_lua_abort(error_codes.el_expected_pattern, {pattern})
    end
  end

  local function is_line_end()
    return i > #line
  end

  local function assert_is_line_end()
    if not is_line_end() then
      emmy_lua_abort(error_codes.el_expected_eol)
    end
  end

  local function is_special()
    return line:find("^ ?@")
  end

  local function parse_special(tag)
    return parse_pattern(" ?@"..tag)
  end

  local function assert_parse_special(tag)
    if not parse_special(tag) then
      emmy_lua_abort(error_codes.el_expected_special_tag, {tag})
    end
  end

  local function parse_blank()
    return parse_pattern("%s+")
  end

  local function assert_parse_blank()
    if not parse_blank() then
      emmy_lua_abort(error_codes.el_expected_blank)
    end
  end

  local function parse_identifier()
    return parse_pattern("([_%a][_%w]*)")
  end

  local function assert_parse_identifier()
    return emmy_lua_assert(parse_identifier(), error_codes.el_expected_ident)
  end

  local assert_parse_type

  local function parse_type(union)
    -- literal type (quoted)
    -- or table
    -- or fun
    -- or any identifier
    --
    -- plus optional [] (multiple)
    -- plus optional | followed by another type

    local start_i = i
    local current_type = {}
    current_type.start_position = get_position()

    local char = parse_pattern("([\"'`])")
    if char then -- literal
      local value = parse_pattern("([^"..char.."]*)"..char)
      if not value then i = start_i return end
      current_type.type_type = "literal"
      current_type.value = value
    else
      local ident = parse_identifier()
      if not ident then return end -- i is not modified yet, just return
      if ident == "table" then -- table!
        -- < %s type %s , %s type %s >
        if parse_pattern("<") then
          current_type.type_type = "dictionary"
          parse_blank()
          current_type.key_type = parse_type()
          if not current_type.key_type then i = start_i return end
          parse_blank()
          if not parse_pattern(",") then i = start_i return end
          parse_blank()
          current_type.value_type = parse_type()
          if not current_type.value_type then i = start_i return end
          parse_blank()
          if not parse_pattern(">") then i = start_i return end
        else
          current_type.type_type = "reference"
          current_type.type_name = "table"
        end
      elseif ident == "fun" then -- function
        current_type.type_type = "function"
        current_type.description = {}
        assert_parse_pattern("%(")
        parse_blank()
        current_type.params = {}
        if not parse_pattern("%)") then
          repeat -- params
            local param = {}
            parse_blank()
            param.name = assert_parse_identifier()
            parse_blank()
            if parse_pattern("%?") then
              param.optional = true
              parse_blank()
            end
            assert_parse_pattern(":")
            parse_blank()
            param.param_type = assert_parse_type()
            parse_blank()
            current_type.params[#current_type.params+1] = param
          until not parse_pattern(",")
          assert_parse_pattern("%)")
        end
        local reset_i_to_here = i
        parse_blank()
        current_type.returns = {}
        if parse_pattern(":") then
          repeat -- returns
            parse_blank()
            local ret = {}
            ret.description = {}
            ret.return_type = assert_parse_type()
            reset_i_to_here = i
            parse_blank()
            if parse_pattern("%?") then
              ret.optional = true
              reset_i_to_here = i
              parse_blank()
            end
            current_type.returns[#current_type.returns+1] = ret
          until not parse_pattern(",")
        end
        i = reset_i_to_here
      else -- any other type
        current_type.type_type = "reference"
        current_type.type_name = ident
      end
    end

    -- stops at previous character of current i
    current_type.stop_position = get_position(-1)

    while parse_pattern("%[%]") do
      current_type = {
        type_type = "array",
        value_type = current_type,
        start_position = util.shallow_copy(current_type.start_position),
        stop_position = get_position(-1),
      }
    end

    if union then
      union.union_types[#union.union_types+1] = current_type
    end

    if parse_pattern("|") then
      union = union or {
        type_type = "union",
        union_types = {current_type},
        start_position = util.shallow_copy(current_type.start_position),
      }
      if not parse_type(union) then i = start_i return end
      union.stop_position = get_position(-1)
      return union
    else
      return current_type
    end
  end

  function assert_parse_type()
    return emmy_lua_assert(parse_type(), error_codes.el_expected_type)
  end

  local function read_block()
    local block = {}
    while line do
      if is_special() then
        if not parse_special("diagnostic") then
          break
        end
      else
        block[#block+1] = line
      end
      next_line()
    end
    return block
  end

  local function get_rest_of_line()
    return line:sub(i)
  end

  local function read_block_starting_at_i()
    local description = {get_rest_of_line()}
    next_line()
    for j, block_line in ipairs(read_block()) do
      description[j + 1] = block_line
    end
    return description
  end

  local function read_class(description)
    if not description then
      local start_line_index = line_index
      local start_i = i
      description = read_block()
      if not parse_pattern("class") then
        line_index = start_line_index - 1
        next_line()
        i = start_i
        return
      end
    end
    assert_parse_blank()
    local result = {}
    result.sequence_type = "class"
    result.node = sequence.associated_node
    result.description = description
    result.type_name_start_position = get_position()
    result.type_name = assert_parse_identifier()
    result.type_name_stop_position = get_position(-1)
    parse_blank()
    result.base_classes = {}
    if not is_line_end() then
      assert_parse_pattern(":")
      parse_blank()
      result.base_classes[1] = {
        type_type = "reference",
        start_position = get_position(),
        type_name = assert_parse_identifier(),
        stop_position = get_position(-1),
      }
      parse_blank()
      while not is_line_end() do
        assert_parse_pattern(",")
        parse_blank()
        result.base_classes[#result.base_classes+1] = {
          type_type = "reference",
          start_position = get_position(),
          type_name = assert_parse_identifier(),
          stop_position = get_position(-1),
        }
        parse_blank()
      end
    end
    next_line()
    result.fields = {}
    while line do
      description = read_block()
      assert_parse_special("field")
      assert_parse_blank()
      local field = {}
      field.description = description
      field.name = assert_parse_identifier()
      local did_parse_blank = parse_blank()
      if parse_pattern("%?") then
        field.optional = true
        parse_blank()
      elseif not did_parse_blank then
        assert_parse_blank() -- error
      end
      field.field_type = assert_parse_type()
      if field.field_type.type_type == "function" then
        field.field_type.description = description
      end
      parse_blank()
      if description[1] then
        assert_is_line_end()
      elseif not is_line_end() then
        assert_parse_pattern("@")
        parse_blank()
        description[1] = get_rest_of_line()
      end
      result.fields[#result.fields+1] = field
      next_line()
    end
    return result
  end

  local function read_alias(description)
    if not description then
      local start_line_index = line_index
      local start_i = i
      description = read_block()
      if not parse_pattern("alias") then
        line_index = start_line_index - 1
        next_line()
        i = start_i
        return
      end
    end
    assert_parse_blank()
    local result = {}
    result.sequence_type = "alias"
    result.node = sequence.associated_node
    result.description = description
    result.type_name_start_position = get_position()
    result.type_name = assert_parse_identifier()
    result.type_name_stop_position = get_position(-1)
    assert_parse_blank()
    result.aliased_type = assert_parse_type()
    parse_blank()
    assert_is_line_end()
    next_line()
    return result
  end

  local function read_class_or_alias_or_none(allow_alias)
    local description = read_block()
    if line then
      if parse_special("class") then
        return read_class(description)
      elseif allow_alias and parse_special("alias") then
        return read_alias(description)
      elseif is_special() then
        parse_special("")
        emmy_lua_abort(error_codes.el_unexpected_special_tag, {parse_identifier()})
      end
      util.debug_abort("Impossible because read_block only leaves on special tags and the last \z
        elseif above checks for special tags, making this unreachable."
      )
    end
    return {
      sequence_type = "none",
      description = description,
      node = sequence.associated_node,
    }
  end

  local function try_read_param()
    if not parse_special("param") then return end
    assert_parse_blank()
    local result = {}
    result.name = assert_parse_identifier()
    -- the '' can follow directly after the name in sumneko.lua
    -- so we don't have to assert, but I do it anyway
    assert_parse_blank()
    if parse_pattern("%?") then
      result.optional = true
      parse_blank()
    end
    result.param_type = assert_parse_type()
    parse_blank()
    if not is_line_end() then
      assert_parse_pattern("@")
      parse_blank()
      result.description = read_block_starting_at_i()
    else
      result.description = {}
      next_line()
    end
    return result
  end

  local function try_read_return()
    if not parse_special("return") then return end
    assert_parse_blank()
    local result = {}
    result.return_type = assert_parse_type()
    local name_would_be_valid = parse_blank()
    if parse_pattern("%?") then
      result.optional = true
      parse_blank()
      name_would_be_valid = true
    end
    if name_would_be_valid then
      result.name = parse_identifier()
      parse_blank()
    end
    if not is_line_end() then
      assert_parse_pattern("@")
      parse_blank()
      result.description = read_block_starting_at_i()
    else
      result.description = {}
      next_line()
    end
    return result
  end

  local function read_function_sequence()
    local result = {}
    result.sequence_type = "function"
    result.type_type = "function"
    result.node = sequence.associated_node
    result.description = read_block()
    result.params = {}
    result.returns = {}
    while line do
      local param = try_read_param()
      if not param then
        break
      end
      result.params[#result.params+1] = param
    end
    -- NOTE: I don't support @vararg for now, because I basically never use it
    while line do
      local ret = try_read_return()
      if not ret then
        break
      end
      result.returns[#result.returns+1] = ret
    end
    return result
  end

  next_line()
  local node = sequence.associated_node
  local result
  local err
  local success = xpcall(function()
    if node then
      if node.node_type == "localstat" then
        -- allow classes or none
        result = read_class_or_alias_or_none(false)
      elseif node.node_type == "localfunc" then
        -- allow function sequences
        result = read_function_sequence()
      elseif node.node_type == "funcstat" then
        -- allow function sequences
        result = read_function_sequence()
      else
        util.abort("Unhandled associated_node '"..node.node_type.."'.")
      end
    else
      -- allow classes or aliases or none
      result = read_class_or_alias_or_none(true)
    end
    util.debug_assert(not line, "Did not finish parsing comment sequence "..get_location_str()..".")
  end, function(msg)
    err = debug.traceback(msg, 2)
  end)
  if not success then
    if error_code_inst then
      return nil, error_code_inst
    end
    util.debug_abort(err)
  end
  result.source = source
  -- have to copy at least one of them because there might just be a single line
  result.start_position = util.shallow_copy(positions[1])
  -- include the `---`
  result.start_position.column = result.start_position.column - 3
  result.stop_position = positions[#positions]
  -- include the entire line
  result.stop_position.column = result.stop_position.column + #sequence[#sequence] - 1
  return result
end

---This parse function is literally just copy paste of the formatter with very few modifications.
---The only changes are that there is no string output and there is sequence tracking of comments
---with 3 starting dashes: `---`. This does mean that there are several redundant function calls
---and associated logic that could be removed, but I'm keeping this as low effort as possible
---because I'm fairly certain the way ast can be walked through is going to change which should
---make this easier. And if it doesn't, this can be cleaned up at that point.
---@param ast AstMain
local function parse(ast)
  -- local out = {}

  local add_stat
  local add_scope

  local add_exp
  local add_exp_list

  local exprs
  local add_token
  local add_invalid

  local function add(part)
    -- out[#out+1] = part
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

  local finished_sequences = {}
  local finished_positions = {}

  local current_sequence = {}
  local current_positions = {}
  local had_newline_since_prev_comment = false
  local prev_blank_end_column = 0

  local function finish()
    if not current_sequence[1] then return end
    local sequence = current_sequence
    finished_sequences[#finished_sequences+1] = sequence
    finished_positions[#finished_positions+1] = current_positions
    current_sequence = {}
    current_positions = {}
    return sequence
  end

  local function finish_associated(node)
    local sequence = finish()
    if sequence then
      sequence.associated_node = node
    end
  end

  ---if there was anything that wasn't a blank token since the prev blank token, finish.
  ---(don't need to check for a newline because there is always a newline after a non block comment)
  ---@return boolean did_finish
  local function finish_if_there_was_some_token_since_prev_blank(current_token)
    if prev_blank_end_column ~= current_token.column - 1 then
      finish()
      return true
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
      -- add(token_node.value)
      if had_newline_since_prev_comment then
        if token_node.value:sub(-1) == "\n" then
          finish()
        else
          if not finish_if_there_was_some_token_since_prev_blank(token_node) then
            prev_blank_end_column = token_node.column + #token_node.value - 1
          end
        end
      else
        -- don't actually need to check for a newline because every non block
        -- comment will be followed by a blank token that is just a newline
        -- (unless it is right before eof).
        prev_blank_end_column = 0
        had_newline_since_prev_comment = true
      end
    elseif token_node.token_type == "comment" then
      finish_if_there_was_some_token_since_prev_blank(token_node)
      if not token_node.src_is_block_str and token_node.value:sub(1, 1) == "-" then
        current_sequence[#current_sequence+1] = token_node.value:sub(2)
        -- +3 to column because of the `---`
        current_positions[#current_positions+1] = {line = token_node.line, column = token_node.column + 3}
        had_newline_since_prev_comment = false
      end
      -- add("--")
      -- if token_node.src_is_block_str then
      --   add_string(token_node)
      -- else
      --   add(token_node.value)
      -- end
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
          -- ---@narrow field AstListField
          add_exp(field.value)
        else
          -- ---@narrow field AstRecordField
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
        if not finish_if_there_was_some_token_since_prev_blank(node.func_def.function_token) then
          finish_associated(node)
        end
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
      if not finish_if_there_was_some_token_since_prev_blank(node.local_token) then
        finish_associated(node)
      end
      add_functiondef(node.func_def, function()
        add_exp(node.name)
      end)
    end,
    ---@param node AstLocalStat
    localstat = function(node)
      add_token(node.local_token)
      if not finish_if_there_was_some_token_since_prev_blank(node.local_token) then
        finish_associated(node)
      end
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

  ---@param node AstStatement
  function add_stat(node)
    stats[node.node_type](node)
  end

  ---@param node AstScope
  function add_scope(node)
    local elem = node.body.first
    while elem do
      add_stat(elem.value)
      elem = elem.next
    end
  end

  add_functiondef(ast)

  -- -- dirty way of ensuring formatted code doesn't combine identifiers (or keywords or numbers)
  -- -- one line comments without a blank token afterwards with a newline in its value can still
  -- -- "break" formatted code in the sense that it changes the general AST structure, or most likely
  -- -- causes a syntax error when parsed again
  -- do
  --   local prev = out[1]
  --   local i = 2
  --   local c = #out
  --   while i <= c do
  --     local cur = out[i]
  --     if cur ~= "" then
  --       -- there is at least 1 case where this adds an extra space where it doesn't need to,
  --       -- which is for something like `0xk` where 0x is a malformed number and k is an identifier
  --       -- but yea, I only know of this one case where it's only with invalid nodes anyway...
  --       -- all in all this logic here shouldn't be needed at all, i just added it for fun
  --       -- to see if it would work
  --       if prev:find("[a-z_A-Z0-9]$") and cur:find("^[a-z_A-Z0-9]") then
  --         table.insert(out, i, " ")
  --         i = i + 1
  --         c = c + 1
  --       end
  --       prev = cur
  --     end
  --     i = i + 1
  --   end
  -- end

  -- return table.concat(out)

  finish()

  local result = {}
  local error_code_insts = {}
  for i, sequence in ipairs(finished_sequences) do
    local error_code_inst
    sequence, error_code_inst = parse_sequence(sequence, ast.source, finished_positions[i])
    if sequence then
      result[#result+1] = sequence
    else
      error_code_insts[#error_code_insts+1] = error_code_inst
    end
  end
  return result, error_code_insts
end

return parse
