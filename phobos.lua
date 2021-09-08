
local invert = require("invert")
local phobos_consts = require("constants")
local util = require("util")
----------------------------------------------------------------------
local generate_code
do
  local opcodes = require("opcodes")

  local function get_last_used_line(func)
    return (#func.instructions > 0)
      and func.instructions[#func.instructions].line
      or nil
  end

  local function get_last_used_column(func)
    return (#func.instructions > 0)
      and func.instructions[#func.instructions].column
      or nil
  end

  local function get_position_for_index(index_node)
    if index_node.suffix.node_type == "string" and index_node.suffix.src_is_ident then
      if index_node.scr_ex_did_not_exist then
        return index_node.suffix
      else
        return index_node.dot_token
      end
    else
      return index_node.suffix_open_token
    end
  end

  ---get the next available register in the given function\
  ---**without** increasing `max_stack_size`
  local function peek_next_reg(func)
    return func.next_reg
  end

  ---mark the given reg as used and adjust `max_stack_size`\
  ---only really meant to be used if the given `reg` is current or 1 past top
  local function use_reg(func, reg)
    local next_n = reg + 1
    func.next_reg = next_n
    if next_n > func.max_stack_size then
      -- next_n is 0 based, max_stack_size 1 based, so it "just works"
      func.max_stack_size = next_n
    end
  end

  ---get the next available register in the given function
  ---@param func Function
  ---@return number regnum
  local function next_reg(func)
    local reg = peek_next_reg(func)
    use_reg(func, reg)
    return reg
  end

  local function get_top(func)
    return func.next_reg - 1
  end

  local function reg_is_top(func, reg)
    return reg >= get_top(func)
  end

  local function ensure_used_reg(func, reg)
    if reg > get_top(func) then
      use_reg(func, reg)
    end
  end

  local function release_reg(reg, func)
    if reg ~= get_top(func) then
      error("Attempted to release register "..reg.." when top was "..get_top(func))
    end
    -- if it had a live local in it, end it here
    local live_regs = func.live_regs
    local last_pc = #func.instructions
    for i = #live_regs,1,-1 do
      local lr = live_regs[i]
      if not lr.stop_at and lr.reg == reg then
        lr.stop_at = last_pc
      end
    end
    func.next_reg = reg
  end

  ---releases all regs down to `reg` but keeps `reg` live
  local function release_down_to(reg, func)
    if reg == get_top(func) then
      return
    end

    if reg > get_top(func) then
      error("Attempted to release registers down to "..reg.." when top was "..get_top(func))
    end
    -- if any had live locals, end them here
    local live_regs = func.live_regs
    local last_pc = #func.instructions
    for i = #live_regs,1,-1 do
      local lr = live_regs[i]
      if not lr.stop_at and lr.reg > reg then
        lr.stop_at = last_pc
      end
    end
    func.next_reg = reg + 1
  end

  local function get_level(scope, func)
    return func.scope_levels[scope]
      or error("Trying to get the level for a scope that has not been reached yet")
  end
  local function get_current_level(func)
    -- technically this could just return `func.level`, but i wanted to follow
    -- the "convention" of always using the `get_level` function
    return get_level(func.current_scope, func)
  end

  local function create_live_reg(func, reg, name)
    local live = {
      reg = reg,
      name = name,
      level = get_current_level(func),
      scope = func.current_scope,
    }
    func.live_regs[#func.live_regs+1] = live
    return live
  end

  local vararg_node_types = invert{"vararg","call","selfcall"}
  local function is_vararg(node)
    return vararg_node_types[node.node_type] and (not node.force_single_result)
  end

  local generate_expr_code
  local function generate_expr(expr,in_reg,func,num_results)
    generate_expr_code[expr.node_type](expr,in_reg,func,num_results)
    if num_results > 1 and not (is_vararg(expr) or expr.node_type == "nil") then
      generate_expr({
        node_type = "nil",
        line = expr.line,
        column = expr.column,
      }, in_reg + 1, func, num_results - 1)
    end
  end

  local function generate_exp_list(exp_list,in_reg,func,num_results)
    if num_results > 0 and (#exp_list) == 0 then
      -- it wants results but there are no expressions to generate, so just generate nil
      generate_expr({
        node_type = "nil",
        line = get_last_used_line(func),
        column = get_last_used_column(func),
      }, in_reg, func, num_results)
      return
    end

    local num_exp = #exp_list
    local used_temp
    local original_top = get_top(func)
    do
      if not reg_is_top(func, in_reg + (num_results == -1 and 0 or (num_results - 1))) then
        if num_results == -1 then
          error("Cannot generate variable-length exp_list except at top")
        end
        used_temp = true
      end
    end
    for i,expr in ipairs(exp_list) do
      local function get_expr_in_reg()
        if used_temp then
          return next_reg(func)
        else
          local reg = in_reg + i - 1
          if reg == get_top(func) + 1 then
            -- reg is never supposed to be able to be above top by more than 1
            -- that's why it's explicitly checking for equality with top + 1
            -- in order to not hide other bugs
            use_reg(func, reg)
          end
          return reg
        end
      end
      if i == num_exp then
        local expr_num_results = -1
        if num_results ~= -1 then
          expr_num_results = (num_results - num_exp) + 1
        elseif not is_vararg(expr) then
          expr_num_results = 1
        end
        generate_expr(expr, get_expr_in_reg(), func, expr_num_results)
      elseif i > num_exp then
        -- TODO: still evaluate the rest of the expressions with 0 results, [...]
        -- because things like function calls can still have an effect, even if their result is unused
        break
      else
        generate_expr(expr, get_expr_in_reg(), func, 1)
      end
    end
    if used_temp then
      -- move from base+i to in_reg+i-1
      for i = 1, num_results do
        func.instructions[#func.instructions+1] = {
          -- since original_top is the original top live reg, the temporary regs
          -- are actually starting 1 past it, meaning it must not have the -1
          -- unlike in_reg
          op = opcodes.move, a = in_reg + i - 1, b = original_top + i,
          line = get_last_used_line(func),
          column = get_last_used_column(func),
        }
      end
      release_down_to(original_top, func)
    end
  end

  local generate_statement_code
  local function generate_statement(stat, func)
    generate_statement_code[stat.node_type](stat, func)
  end

  local function generate_scope(scope, func, pre_block, post_block)
    func.level = func.level + 1
    func.scope_levels[scope] = func.level
    local previous_scope = func.current_scope
    func.current_scope = scope

    local original_top = get_top(func)

    if pre_block then
      pre_block()
    end
    for _,stat in ipairs(scope.body) do
      generate_statement(stat,func)
    end
    if post_block then
      post_block()
    end

    if func.level ~= 1 then -- no need to do anything in the root scope
      -- TODO: this condition can be improved once the compiler knows that [...]
      -- the given location (the end of the scope) is unreachable
      -- note that the root scope might still be an exception at that point
      local lowest_captured_reg
      for _, live in ipairs(func.live_regs) do
        if live.scope == scope and live.upval_capture_pc then
          if (not lowest_captured_reg) or live.reg < lowest_captured_reg then
            lowest_captured_reg = live.reg
          end
        end
      end
      if lowest_captured_reg then
        func.instructions[#func.instructions+1] = {
          op = opcodes.jmp, a = lowest_captured_reg + 1, sbx = 0,
          line = scope.end_token and scope.end_token.line or get_last_used_line(func),
          column = scope.end_token and scope.end_token.column or get_last_used_column(func),
        }
      end
    end

    release_down_to(original_top, func)

    func.current_scope = previous_scope
    func.level = func.level - 1
  end


  local function add_constant(new_constant,func)
    for i,constant in ipairs(func.constants) do
      if new_constant.value == constant.value then
        return i - 1
      end
    end
    local i = #func.constants
    func.constants[i+1] = {
      node_type = new_constant.node_type,
      value = new_constant.value,
    }
    return i
  end

  local function generate_const_code(expr,in_reg,func)
    local k = add_constant(expr, func)
    if k <= 0x3ffff then
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadk, a = in_reg, bx = k,
        line = expr.line, column = expr.column,
      }
    else
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadkx, a = in_reg,
        line = expr.line, column = expr.column,
      }
      func.instructions[#func.instructions+1] = {
        op = opcodes.extraarg, ax = k,
        line = expr.line, column = expr.column,
      }
    end
  end

  local bin_opcode_lut = {
    ["+"] = opcodes.add,
    ["-"] = opcodes.sub,
    ["*"] = opcodes.mul,
    ["/"] = opcodes.div,
    ["%"] = opcodes.mod,
    ["^"] = opcodes.pow,
  }
  local logical_binop_lut = {
    ["=="] = opcodes.eq,
    ["<"] = opcodes.lt,
    ["<="] = opcodes.le,
    ["~="] = opcodes.eq, -- inverted
    [">="] = opcodes.lt, -- inverted
    [">"] = opcodes.le, -- inverted
  }
  local logical_invert_lut = {
    ["=="] = false,
    ["<"] = false,
    ["<="] = false,
    ["~="] = true,
    [">="] = true,
    [">"] = true,
  }
  local un_opcodes = {
    ["-"] = opcodes.unm,
    ["#"] = opcodes.len,
    ["not"] = opcodes["not"],
  }
  local function find_local(local_name,func)
    -- find it in live_regs and use that...
    local live_regs = func.live_regs
    for i = #live_regs,1,-1 do
      local lr = live_regs[i]
      if lr.name == local_name
        and (not lr.stop_at)
        and (lr.start_at and lr.start_at <= #func.instructions + 1)
      then
        return lr.reg, lr
      end
    end
  end

  ---@param upval_name string
  ---@param func CompiledFunc
  local function find_upval(upval_name,func)
    for i = 1, #func.upvals do
      if func.upvals[i].name == upval_name then
        return func.upvals[i].index
      end
    end
    error("Unable to find upval with name "..upval_name..".")
  end

  local function local_or_fetch(expr,in_reg,func)
    if expr.node_type == "local_ref" then
      return find_local(expr.name,func)
    else
      use_reg(func, in_reg)
      generate_expr(expr,in_reg,func,1)
      return in_reg
    end
  end

  local function is_falsy(node)
    return node.node_type == "nil" or (node.node_type == "boolean" and node.value == false)
  end

  local const_node_types = invert{"boolean","nil","string","number"}
  local function const_or_local_or_fetch(expr,in_reg,func)
    if const_node_types[expr.node_type] then
      return bit32.bor(add_constant(expr,func),0x100)
    else
      return local_or_fetch(expr,in_reg,func)
    end
  end

  local function upval_or_local_or_fetch(expr,in_reg,func)
    if expr.node_type == "upval_ref" then
      return expr.reference_def.index,true
    else
      return local_or_fetch(expr,in_reg,func),false
    end
  end

  local function eval_upval_indexes(target_func_proto, func)
    for _, upval in ipairs(target_func_proto.func_def.upvals) do
      upval.in_stack = util.upval_is_in_stack(upval)
      if upval.in_stack then
        local live_reg
        upval.local_idx, live_reg = find_local(upval.name, func)
        assert(live_reg)
        if not live_reg.upval_capture_pc then
          live_reg.upval_capture_pc = #func.instructions
        end
      else
        upval.upval_idx = upval.parent_def.index
      end
    end
  end

  generate_expr_code = {
    local_ref = function(expr,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.move, a = in_reg, b = find_local(expr.name,func),
        line = expr.line, column = expr.column,
      }
    end,
    ---@param expr AstUpvalReference
    ---@param in_reg integer
    ---@param func CompiledFunc
    upval_ref = function(expr,in_reg,func)
      -- getupval
      func.instructions[#func.instructions+1] = {
        op = opcodes.getupval, a = in_reg, b = find_upval(expr.name,func),
        line = expr.line, column = expr.column,
      }
    end,
    ---@param expr AstBinOp
    binop = function(expr,in_reg,func)
      -- if expr.left and .right are locals, use them in place
      -- if they're constants, add to const table and use in place from there
      --   unless const table is too big, then fetch into temporary (and emit warning: const table too large)
      -- else fetch them into temporaries
      --   first temporary is in_reg, second is next_reg()

      -- TODO: this ends up using way too many registers and instructions [...]
      -- bin_opcode_lut is fine, logical_binop_lut on it's own as well.
      -- but "and" and "or" are horrible, and combining them with logical binops is also bad

      -- TODO: some of the instructions should probably use a different token for their line/column
      local line = expr.op_token and expr.op_token.line
      local column = expr.op_token and expr.op_token.column

      if expr.op == "and" or expr.op == "or" then

        -- in_reg can be the register of a local in which case we are not allowed
        -- to set a value to it yet, so to be safe just always use a temporary reg
        local temp_reg = peek_next_reg(func)
        local left_reg = local_or_fetch(expr.left, temp_reg, func)
        func.instructions[#func.instructions+1] = {
          op = opcodes.testset, a = in_reg, b = left_reg, c = expr.op == "or" and 1 or 0,
          line = line, column = column,
        }
        local jump = {
          op = opcodes.jmp, a = 0, sbx = nil,
          line = line, column = column,
        }
        func.instructions[#func.instructions+1] = jump
        local jump_pc = #func.instructions

        if left_reg == temp_reg then
          release_reg(temp_reg, func)
        end
        local right_reg = local_or_fetch(expr.right,in_reg,func)
        if right_reg ~= in_reg then
          func.instructions[#func.instructions+1] = {
            op = opcodes.move, a = in_reg, b = right_reg,
            line = line, column = column,
          }
        end
        jump.sbx = #func.instructions - jump_pc
      else
        local left_reg = const_or_local_or_fetch(expr.left,in_reg,func)
        -- if left_reg used in_reg, eval next expression into next_reg if needed
        local temp_reg = left_reg == in_reg and peek_next_reg(func) or in_reg
        local right_reg = const_or_local_or_fetch(expr.right,temp_reg,func)

        if bin_opcode_lut[expr.op] then
          func.instructions[#func.instructions+1] = {
            op = bin_opcode_lut[expr.op], a = in_reg, b = left_reg, c = right_reg,
            line = line, column = column,
          }
        elseif logical_binop_lut[expr.op] then
          func.instructions[#func.instructions+1] = {
            op = logical_binop_lut[expr.op], a = logical_invert_lut[expr.op] and 1 or 0,
            b = left_reg, c = right_reg,
            line = line, column = column,
          }
          func.instructions[#func.instructions+1] = {
            op = opcodes.jmp, a = 0, sbx = 1,
            line = line, column = column,
          }
          func.instructions[#func.instructions+1] = {
            op = opcodes.loadbool, a = in_reg, b = 1, c = 1,
            line = line, column = column,
          }
          func.instructions[#func.instructions+1] = {
            op = opcodes.loadbool, a = in_reg, b = 0, c = 0,
            line = line, column = column,
          }
        else
          error("Invalid binop operator '"..expr.op.."'.")
        end
      end
      -- release temporaries if they were used
      release_down_to(in_reg, func)
    end,
    unop = function(expr,in_reg,func)
      -- if expr.ex is a local use that directly,
      -- else fetch into in_reg
      local scr_reg = local_or_fetch(expr.ex,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = un_opcodes[expr.op], a = in_reg, b = scr_reg,
        line = expr.op_token and expr.op_token.line,
        column = expr.op_token and expr.op_token.column,
      }
    end,
    concat = function(expr,in_reg,func)
      local original_top = get_top(func)
      local temp_reg = in_reg
      if not reg_is_top(func, temp_reg) then
        temp_reg = next_reg(func)
      end
      local num_exp = #expr.exp_list
      generate_exp_list(expr.exp_list,temp_reg,func,num_exp)
      local position = expr.op_tokens and expr.op_tokens[1]
      func.instructions[#func.instructions+1] = {
        op = opcodes.concat, a = in_reg, b = temp_reg, c = temp_reg + num_exp - 1,
        line = position and position.line,
        column = position and position.column,
      }
      release_down_to(original_top, func)
    end,
    number = generate_const_code,
    string = generate_const_code,
    boolean = function(expr,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadbool, a = in_reg, b = expr.value and 1 or 0, c = 0,
        line = expr.line, column = expr.column,
      }
    end,
    ["nil"] = function(expr,in_reg,func,num_results)
      -- TODO: check if the "combine loadnil" optimization is enabled
      local prev = func.instructions[#func.instructions]
      if prev and prev.op == opcodes.loadnil and (prev.a + prev.b + 1) == in_reg then
        -- only combine if prev was loadnil and stops loading nils just before in_reg
        prev.b = prev.b + num_results
      else
        func.instructions[#func.instructions+1] = {
          op = opcodes.loadnil, a = in_reg, b = num_results - 1, -- from a to a + b
          line = expr.line, column = expr.column,
        }
      end
      ensure_used_reg(func, in_reg + num_results - 1)
    end,
    ---@param expr AstConstructor
    constructor = function(expr,in_reg,func)
      local new_tab = {
        op = opcodes.newtable, a = in_reg, b = nil, c = nil, -- set later
        line = expr.open_token and expr.open_token.line,
        column = expr.open_token and expr.open_token.column,
      }
      func.instructions[#func.instructions+1] = new_tab
      local initial_top = get_top(func)
      local fields_count = #expr.fields
      local num_fields_to_flush = 0
      local flush_count = 0
      local total_list_field_count = 0
      local total_rec_field_count

      local function flush(count, field_index)
        flush_count = flush_count + 1
        total_list_field_count = total_list_field_count + num_fields_to_flush
        num_fields_to_flush = 0
        local position = (field_index == 0 and expr.close_token)
        -- if `field_index == 0` and `expr.close_token == nil`
        -- this will also be `nil` because there is no `0` field
          or expr.comma_tokens[field_index]
          or func.instructions[#func.instructions] -- fallback in both cases
        func.instructions[#func.instructions+1] = {
          op = opcodes.setlist, a = in_reg, b = count, c = flush_count,
          line = position.line,
          column = position.column,
        }
        release_down_to(initial_top, func)
      end

      for i,field in ipairs(expr.fields) do
        if field.type == "list" then
          ---@narrow field AstListField
          -- if list accumulate values
          local count = 1
          if i == fields_count and is_vararg(field.value) then
            count = -1
          end
          generate_expr(field.value,next_reg(func),func,count)
          num_fields_to_flush = num_fields_to_flush + 1
          if count == -1 then
            flush(0, i) -- 0 means up to top
            total_rec_field_count = fields_count - total_list_field_count
            total_list_field_count = total_list_field_count - 1 -- don't count the vararg field
          elseif num_fields_to_flush == phobos_consts.fields_per_flush then
            flush(num_fields_to_flush, i)
          end
        elseif field.type == "rec" then
          ---@narrow field AstRecordField
          -- if rec, set in table immediately
          local original_top = get_top(func)
          local key_reg = const_or_local_or_fetch(field.key,peek_next_reg(func),func)
          local value_reg = const_or_local_or_fetch(field.value,peek_next_reg(func),func)

          func.instructions[#func.instructions+1] = {
            op = opcodes.settable, a = in_reg, b = key_reg, c = value_reg,
            line = field.eq_token and field.eq_token.line,
            column = field.eq_token and field.eq_token.column,
          }

          release_down_to(original_top, func)
        else
          error("Invalid field type in table constructor")
        end
      end

      if num_fields_to_flush > 0 then
        flush(num_fields_to_flush, 0)
      end
      new_tab.b = util.number_to_floating_byte(total_list_field_count)
      new_tab.c = util.number_to_floating_byte(total_rec_field_count or (fields_count - total_list_field_count))
    end,
    func_proto = function(expr,in_reg,func)
      local func_token = expr.func_def.function_token
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = in_reg, bx = expr.func_def.index,
        line = func_token and func_token.line,
        column = func_token and func_token.column,
      }
      eval_upval_indexes(expr, func)
    end,
    vararg = function(expr,in_reg,func,num_results)
      if not func.is_vararg then
        -- the parser also validates this, but AST can be transformed incorrectly
        error("Cannot generate vararg expression ('...') outside a vararg function.")
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.vararg, a = in_reg, b = (num_results or 1)+1,
        line = expr.line, column = expr.column,
      }
      ensure_used_reg(func, in_reg + num_results - 1)
    end,
    call = function(expr,in_reg,func,num_results)
      num_results = num_results or 1
      local func_reg = in_reg
      local used_temp
      local original_top = get_top(func)
      if not reg_is_top(func, func_reg) then
        if num_results == -1 then
          error("Can't return variable results unless top of stack")
        end
        func_reg = next_reg(func)
        used_temp = true
      end
      generate_expr(expr.ex,func_reg,func,1)
      generate_exp_list(expr.args,peek_next_reg(func),func,-1)
      local num_args = #expr.args
      if num_args > 0 and is_vararg(expr.args[num_args]) then
        num_args = -1
      end
      local position = expr.open_paren_token
      if (not position) and #expr.args == 1 then
        if expr.args[1].node_type == "string" then
          position = expr.args[1]
        elseif expr.args[1].node_type == "constructor" then
          position = expr.args[1].open_token
        end
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.call, a = func_reg, b = num_args+1, c = num_results + 1,
        line = position and position.line,
        column = position and position.column,
      }
      if used_temp then
        -- copy from func_reg+n to in_reg+n
        position = expr.close_paren_token
        if (not position)
          and #expr.args == 1
          and expr.args[1].node_type == "constructor"
        then
          position = expr.args[1].close_token
        end
        for i = 1, num_results do
          func.instructions[#func.instructions+1] = {
            op = opcodes.move, a = in_reg + i - 1, b = func_reg + i - 1,
            line = position and position.line or get_last_used_line(func),
            column = position and position.column or get_last_used_column(func),
          }
        end
        release_down_to(original_top, func)
      else
        num_results = (num_results == -1) and 0 or num_results
        ensure_used_reg(func, in_reg + num_results - 1)
        release_down_to(math.max(original_top, in_reg + num_results - 1), func)
      end
    end,
    selfcall = function(expr,in_reg,func,num_results)
      num_results = num_results or 1
      local func_reg = in_reg
      local used_temp
      local original_top = get_top(func)
      if not reg_is_top(func, func_reg) then
        if num_results == -1 then
          error("Can't return variable results unless top of stack")
        end
        func_reg = next_reg(func)
        used_temp = true
      end
      local actual_func_reg = local_or_fetch(expr.ex,func_reg,func)
      local suffix_reg = const_or_local_or_fetch(expr.suffix,peek_next_reg(func),func)
      -- suffix is currently always an AstString, so always a constant,
      -- so never actually using the given register
      func.instructions[#func.instructions+1] = {
        op = opcodes.self, a = func_reg, b = actual_func_reg, c = suffix_reg,
        line = expr.colon_token and expr.colon_token.line,
        column = expr.colon_token and expr.colon_token.column,
      }
      use_reg(func, func_reg + 1)
      -- TODO: the rest is copy paste from call
      generate_exp_list(expr.args,peek_next_reg(func),func,-1)
      local num_args = #expr.args
      if num_args > 0 and is_vararg(expr.args[num_args]) then
        num_args = -1
      else
        num_args = num_args + 1 -- except this, because selfcall has 1 more arg, period
      end
      local position = expr.open_paren_token
      if (not position) and #expr.args == 1 then
        if expr.args[1].node_type == "string" then
          position = expr.args[1]
        elseif expr.args[1].node_type == "constructor" then
          position = expr.args[1].open_token
        end
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.call, a = func_reg, b = num_args + 1, c = num_results + 1,
        line = position and position.line,
        column = position and position.column,
      }
      if used_temp then
        -- copy from func_reg+n to in_reg+n
        position = expr.close_paren_token
        if (not position)
          and #expr.args == 1
          and expr.args[1].node_type == "constructor"
        then
          position = expr.args[1].close_token
        end
        for i = 1, num_results do
          func.instructions[#func.instructions+1] = {
            op = opcodes.move, a = in_reg + i - 1, b = func_reg + i - 1,
            line = position and position.line or get_last_used_line(func),
            column = position and position.column or get_last_used_column(func),
          }
        end
        release_down_to(original_top, func)
      else
        num_results = (num_results == -1) and 0 or num_results
        ensure_used_reg(func, in_reg + num_results - 1)
        release_down_to(math.max(original_top, in_reg + num_results - 1), func)
      end
    end,
    index = function(expr,in_reg,func)
      local original_top = get_top(func)
      local temp_reg = in_reg
      local ex_reg,is_upval = upval_or_local_or_fetch(expr.ex,temp_reg,func)
      if (not is_upval) and ex_reg == in_reg then
        temp_reg = next_reg(func)
      end

      local suffix_reg = const_or_local_or_fetch(expr.suffix,temp_reg,func)

      local position = get_position_for_index(expr)
      func.instructions[#func.instructions+1] = {
        op = is_upval and opcodes.gettabup or opcodes.gettable,
        a = in_reg, b = ex_reg, c = suffix_reg,
        line = position and position.line,
        column = position and position.column,
      }
      release_down_to(original_top, func)
    end,

    inline_iife = function(expr,in_reg,func,num_results)
      -- TODO: handle vararg num_results [...]
      -- currently inline_iife is not marked as a vararg expression, but it totally is
      -- considering it is the replacement/inline variant of a function call.
      -- that means if a vararg result is expected this expression has to "return"
      -- (and in the process set top) however many expressions the inline_iife_retstat "returned"
      expr.in_reg = in_reg
      expr.num_results = num_results
      generate_scope(expr, func)
    end,
  }

  local function generate_test_code(condition, func)
    --[[
      binop
        eq -> eq
        lt -> lt
        le -> le
        ne -> !eq
        gt -> !le
        ge -> !lt
        and -> [repeat]
        or -> [repeat]
      unop
        not -> !test
      * -> test
    ]]
    if condition.node_type == "binop" and logical_binop_lut[condition.op] then
      local original_top = get_top(func)
      local temp_reg = peek_next_reg(func)
      local left_reg = const_or_local_or_fetch(condition.left,temp_reg,func)
      -- if left_reg used in_reg, eval next expression into next_reg if needed
      temp_reg = left_reg == temp_reg and peek_next_reg(func) or temp_reg
      local right_reg = const_or_local_or_fetch(condition.right,temp_reg,func)

      func.instructions[#func.instructions+1] = {
        op = logical_binop_lut[condition.op], a = logical_invert_lut[condition.op] and 1 or 0,
        b = left_reg, c = right_reg,
        line = condition.op_token and condition.op_token.line,
        column = condition.op_token and condition.op_token.column,
      }
      release_down_to(original_top, func)
    -- TODO: impl "and" and "or" test code
    -- elseif condition.node_type == "binop" and (condition.op == "and" or condition.op == "or") then
    --   error()
    else
      local exp = condition
      local inverted = false
      if condition.node_type == "unop" and condition.op == "not" then
        exp = condition.ex
        inverted = true
      end
      local original_top = get_top(func)
      local temp_reg = peek_next_reg(func)
      local condition_reg = local_or_fetch(exp, temp_reg, func)

      func.instructions[#func.instructions+1] = {
        op = opcodes.test, a = condition_reg, c = inverted and 1 or 0,
        line = get_last_used_line(func),
        column = get_last_used_column(func),
      }
      release_down_to(original_top, func)
    end
  end

  ---go means goto
  local function get_a_for_jump(go, label_position, func)
    local is_backwards = label_position.pc < go.pc
    -- figure out if and how far it needs to close upvals
    local scopes_that_matter_lut = {}
    local scope = go.scope
    while true do
      scopes_that_matter_lut[scope] = true
      if scope == label_position.scope then
        break
      end
      scope = scope.parent_scope
    end
    -- TODO: this is heavily modified copy paste from `generate_scope`
    local lowest_captured_reg
    local function should_close(reg)
      if (not lowest_captured_reg) or reg < lowest_captured_reg then
        lowest_captured_reg = reg
      end
    end
    for _, live in ipairs(func.live_regs) do
      if scopes_that_matter_lut[live.scope] and live.upval_capture_pc and live.upval_capture_pc < go.pc then
        if is_backwards then
          if (live.in_scope_at or live.start_at) > label_position.pc then -- goes out of scope when jumping back
            should_close(live.reg)
          end
        else
          if live.stop_at and live.stop_at <= label_position.pc then -- goes out of scope when jumping forward
            should_close(live.reg)
          end
        end
      end
    end
    if lowest_captured_reg then
      return lowest_captured_reg + 1
    else
      return 0
    end
  end

  local function patch_breaks_to_jump_here(loop_stat, func)
    if loop_stat.linked_breaks then
      for _, break_stat in ipairs(loop_stat.linked_breaks) do
        break_stat.inst.sbx = #func.instructions - break_stat.pc
        break_stat.inst = nil
        break_stat.pc = nil
      end
    end
  end

  generate_statement_code = {
    localstat = function(stat,func)
      local first_reg = next_reg(func)
      if stat.rhs then
        generate_exp_list(stat.rhs, first_reg, func, #stat.lhs)
      else
        generate_expr({
          node_type = "nil",
          line = stat.lhs[1].line,
          column = stat.lhs[1].column,
        }, first_reg, func, #stat.lhs)
      end

      -- declare new registers to be "live" with locals after this
      for i, ref in ipairs(stat.lhs) do
        local live = create_live_reg(func, first_reg + i - 1, ref.name)
        live.in_scope_at = #func.instructions
        live.start_at = #func.instructions + 1
      end
    end,
    assignment = function(stat,func)
      -- evaluate all expressions (assignment parent/key, values) into temporaries, left to right
      -- last expr in value list is for enough values to fill the list
      -- emit warning and drop extra values with no targets
      -- move/settable/settabup from temporary to target, right to left
      local original_top = get_top(func)
      local lefts = {}
      for i,left in ipairs(stat.lhs) do
        if left.node_type == "local_ref" then
          lefts[i] = {
            type = "local",
            reg = find_local(left.name, func),
          }
        elseif left.node_type == "upval_ref" then
          lefts[i] = {
            type = "upval",
            upval_idx = find_upval(left.name, func),
          }
        elseif left.node_type == "index" then
          -- if index and parent not local/upval, fetch parent to temporary
          local new_left = {
            type = "index",
          }
          new_left.ex, new_left.ex_is_upval = upval_or_local_or_fetch(left.ex,peek_next_reg(func),func)
          new_left.suffix = const_or_local_or_fetch(left.suffix,peek_next_reg(func),func)
          lefts[i] = new_left
        else
          error("Attempted to assign to " .. left.node_type)
        end
      end
      local num_lefts = #lefts
      local first_right_reg = peek_next_reg(func)
      -- TODO: the last expression could _somehow_ directly assign to locals (if left is a local)
      generate_exp_list(stat.rhs,first_right_reg,func,num_lefts)
      -- copy rights to lefts
      for i = num_lefts,1,-1 do
        local right_reg = first_right_reg + i - 1
        local left = lefts[i]
        if left.type == "index" then
          local position = get_position_for_index(stat.lhs[i])
          func.instructions[#func.instructions+1] = {
            op = left.ex_is_upval and opcodes.settabup or opcodes.settable,
            a = left.ex, b = left.suffix, c = right_reg,
            line = position and position.line, column = position and position.column,
          }
        elseif left.type == "local" then
          func.instructions[#func.instructions+1] = {
            op = opcodes.move, a = left.reg, b = right_reg,
            line = stat.lhs[i].line, column = stat.lhs[i].column,
          }
        elseif left.type == "upval" then
          func.instructions[#func.instructions+1] = {
            op = opcodes.setupval, a = right_reg, b = left.upval_idx, -- up(b) := r(a)
            line = stat.lhs[i].line, column = stat.lhs[i].column,
          }
        else
          error("Impossible left type "..left.type)
        end
      end
      release_down_to(original_top, func)
    end,
    localfunc = function(stat,func)
      -- allocate register for stat.name
      local func_reg = next_reg(func)
      local func_token = stat.func_def.function_token
      -- CLOSURE into that register
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = func_reg, bx = stat.func_def.index,
        line = func_token and func_token.line, column = func_token and func_token.column,
      }
      local live_reg = create_live_reg(func, func_reg, stat.name.name)
      live_reg.start_at = #func.instructions
      eval_upval_indexes(stat, func)
    end,
    funcstat = function(stat,func)
      local original_top = get_top(func)
      local in_reg
      local left

      -- TODO: this is copy paste from assignment
      if stat.name.node_type == "local_ref" then
        in_reg = find_local(stat.name.name, func)
        left = {
          type = "local",
          reg = in_reg,
        }
      elseif stat.name.node_type == "upval_ref" then
        in_reg = next_reg(func)
        left = {
          type = "upval",
          upval_idx = find_upval(stat.name.name, func),
        }
      elseif stat.name.node_type == "index" then
        in_reg = next_reg(func)
        -- if index and parent not local/upval, fetch parent to temporary
        left = {
          type = "index",
        }
        left.ex, left.ex_is_upval = upval_or_local_or_fetch(stat.name.ex,peek_next_reg(func),func)
        left.suffix = const_or_local_or_fetch(stat.name.suffix,peek_next_reg(func),func)
      else
        error("Attempted to assign to " .. left.node_type)
      end

      local func_token = stat.func_def.function_token
      -- CLOSURE into that register
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = in_reg, bx = stat.func_def.index,
        line = func_token and func_token.line, column = func_token and func_token.column,
      }
      eval_upval_indexes(stat, func)

      -- TODO: this is copy paste from assignment
      if left.type == "index" then
        local position = get_position_for_index(stat.name)
        func.instructions[#func.instructions+1] = {
          op = left.ex_is_upval and opcodes.settabup or opcodes.settable,
          a = left.ex, b = left.suffix, c = in_reg,
          line = position and position.line, column = position and position.column,
        }
      elseif left.type == "local" then
        -- do nothing because the closure is directly put into the local
      elseif left.type == "upval" then
        func.instructions[#func.instructions+1] = {
          op = opcodes.setupval, a = in_reg, b = left.upval_idx, -- up(b) := r(a)
          line = stat.name.line, column = stat.name.column,
        }
      else
        error("Impossible left type "..left.type)
      end
      release_down_to(original_top, func)
    end,
    dostat = generate_scope,
    ifstat = function(stat,func)
      local prev_failure_jump
      local finish_jumps = {}
      local condition_is_always_truthy = false
      for i,if_block in ipairs(stat.ifs) do
        -- local original_top = get_top(func)
        local condition_node = if_block.condition
        local condition_node_type = condition_node.node_type

        if is_falsy(condition_node) then -- TODO: imo this should be moved out to be an optimization
          -- always false, skip this block
          goto continue
        elseif const_node_types[condition_node_type] then
          -- always true, stop after this block
          prev_failure_jump = nil
          condition_is_always_truthy = true

          -- TODO: include table constructors and closures here
          -- maybe function calls of known truthy return types too?
          -- but those still need to eval it if captured to a block local
        else
          -- generate a value and `test` it...
          generate_test_code(condition_node, func)
          prev_failure_jump = {
            op = opcodes.jmp, a = 0, sbx = nil,
            line = if_block.then_token and if_block.then_token.line or get_last_used_line(func),
            column = if_block.then_token and if_block.then_token.column or get_last_used_column(func),
          }
          func.instructions[#func.instructions+1] = prev_failure_jump
          prev_failure_jump.pc = #func.instructions
        end

        -- generate body
        generate_scope(if_block, func)

        local finish_jump = {
          op = opcodes.jmp, a = 0, sbx = nil,
          line = get_last_used_line(func),
          column = get_last_used_column(func),
        }
        finish_jumps[#finish_jumps+1] = finish_jump
        func.instructions[#func.instructions+1] = finish_jump
        finish_jump.pc = #func.instructions

        if prev_failure_jump then
          prev_failure_jump.sbx = #func.instructions - prev_failure_jump.pc
          prev_failure_jump.pc = nil
        end

        if condition_is_always_truthy then
          break
        end

        -- release_down_to(original_top, func)
        -- jump from end of body to end of blocks (not yet determined, build patch list)
        -- patch test failure to jump here for next test/else/next_block
        ::continue::
      end
      if (not condition_is_always_truthy) and stat.elseblock then
        generate_scope(stat.elseblock, func)
      else
        if finish_jumps[#finish_jumps] then
          func.instructions[#func.instructions] = nil
          finish_jumps[#finish_jumps] = nil
          if prev_failure_jump then
            prev_failure_jump.sbx = prev_failure_jump.sbx - 1
          end
        end
      end
      for _, finish_jump in ipairs(finish_jumps) do
        finish_jump.sbx = #func.instructions - finish_jump.pc
        finish_jump.pc = nil
      end
    end,
    call = function(stat,func)
      -- evaluate as a call expression for zero results
      local top = get_top(func)
      generate_expr(stat,next_reg(func),func,0)
      release_down_to(top, func)
    end,
    selfcall = function(stat,func)
      -- evaluate as a selfcall expression for zero results
      local top = get_top(func)
      generate_expr(stat,next_reg(func),func,0)
      release_down_to(top, func)
    end,
    forlist = function(stat,func)
      local generator_reg, control_reg
      local generator_live, state_live, control_live
      local jump, jump_pc

      local function pre_block()
        generator_reg = peek_next_reg(func)
        -- eval exp_list for three results starting at generator
        generate_exp_list(stat.exp_list, generator_reg, func, 3)

        -- allocate forlist internal vars
        generator_live = create_live_reg(func, generator_reg, "(for generator)")
        state_live = create_live_reg(func, generator_reg + 1, "(for state)")
        control_reg = generator_reg + 2
        control_live = create_live_reg(func, control_reg, "(for control)")

        -- jmp to tforcall
        jump = {
          op = opcodes.jmp, a = 0, sbx = nil,
          line = stat.do_token and stat.do_token.line,
          column = stat.do_token and stat.do_token.column,
        }
        func.instructions[#func.instructions+1] = jump
        jump_pc = #func.instructions

        -- go back and set internals live
        for _, live in ipairs{generator_live, state_live, control_live} do
          live.start_at = #func.instructions
        end
        -- allocate for locals, declare them live
        for _, local_ref in ipairs(stat.name_list) do
          local live = create_live_reg(func, next_reg(func), local_ref.name)
          live.start_at = #func.instructions
        end
      end

      generate_scope(stat, func, pre_block)

      jump.sbx = #func.instructions - jump_pc
      func.instructions[#func.instructions+1] = {
        op = opcodes.tforcall, a = generator_reg, c = #stat.name_list, -- a=func, c=num loop vars
        line = stat.for_token and stat.for_token.line,
        column = stat.for_token and stat.for_token.column,
      }
      func.instructions[#func.instructions+1] = {
        -- sbx: jump back to just start of body
        op = opcodes.tforloop, a = control_reg, sbx = jump_pc - (#func.instructions + 1),
        line = stat.for_token and stat.for_token.line,
        column = stat.for_token and stat.for_token.column,
      }

      patch_breaks_to_jump_here(stat, func)

      -- patch the stop_at for the for internals
      -- this is technically a hack that could be avoided by adding a fake scope
      -- just around the loop which includes these locals, but this approach is a lot easier
      for _, live in ipairs{generator_live, state_live, control_live} do
        live.stop_at = #func.instructions
      end
    end,
    fornum = function(stat,func)
      -- allocate fornum internal vars
      -- eval start/stop/step into internals
      -- allocate for local, declare it live
      -- generate body

      local index_reg, limit_reg, step_reg, var_reg
      local index_live, limit_live, step_live, var_live
      local forprep_inst, forprep_pc

      local function pre_block()
        index_reg = next_reg(func)
        index_live = create_live_reg(func, index_reg, "(for index)")
        generate_expr(stat.start, index_reg, func, 1)
        limit_reg = next_reg(func)
        limit_live = create_live_reg(func, limit_reg, "(for limit)")
        generate_expr(stat.stop, limit_reg, func, 1)
        step_reg = next_reg(func)
        step_live = create_live_reg(func, step_reg, "(for step)")
        generate_expr(stat.step or {
          node_type = "number",
          value = 1,
          line = get_last_used_line(func),
          column = get_last_used_column(func),
        }, step_reg, func, 1)

        var_reg = next_reg(func)
        var_live = create_live_reg(func, var_reg, stat.var.name)

        forprep_inst = {
          op = opcodes.forprep, a = index_reg, sbx = nil,
          line = stat.do_token and stat.do_token.line,
          column = stat.do_token and stat.do_token.column,
        }
        func.instructions[#func.instructions+1] = forprep_inst
        forprep_pc = #func.instructions

        for _, live in ipairs{index_live, limit_live, step_live, var_live} do
          live.start_at = #func.instructions
        end
      end

      generate_scope(stat, func, pre_block)
      -- loop

      forprep_inst.sbx = #func.instructions - forprep_pc
      func.instructions[#func.instructions+1] = {
        op = opcodes.forloop, a = index_reg, sbx = forprep_pc - (#func.instructions + 1),
        line = stat.for_token and stat.for_token.line,
        column = stat.for_token and stat.for_token.column,
      }

      -- patch the stop_at for the for internals
      -- same hack as in forlist
      for _, live in ipairs{index_live, limit_live, step_live} do
        live.stop_at = #func.instructions
      end

      patch_breaks_to_jump_here(stat, func)
    end,
    whilestat = function(stat,func)
      local start_pc = #func.instructions
      local failure_jump
      local failure_jump_pc
      -- TODO: this optimization should probably be moved out
      if is_falsy(stat.condition) then
        -- always false, no need to generate anything
        return
      elseif const_node_types[stat.condition.node_type] then
        -- always true, no need to check the condition
      else
        -- generate condition and test
        generate_test_code(stat.condition, func)
        -- jump over everything and leave
        failure_jump = {
          op = opcodes.jmp, a = 0, sbx = nil,
          line = stat.do_token and stat.do_token.line,
          column = stat.do_token and stat.do_token.column,
        }
        func.instructions[#func.instructions+1] = failure_jump
        failure_jump_pc = #func.instructions
      end
      -- generate body
      generate_scope(stat, func)
      -- jump back
      func.instructions[#func.instructions+1] = {
        op = opcodes.jmp, a = 0, sbx = start_pc - (#func.instructions + 1),
        line = stat.end_token and stat.end_token.line,
        column = stat.end_token and stat.end_token.column,
      }
      -- patch failure_jump to jump here
      if failure_jump then
        failure_jump.sbx = #func.instructions - failure_jump_pc
      end
      -- patch breaks to jump here as well
      patch_breaks_to_jump_here(stat, func)
    end,
    repeatstat = function(stat,func)
      local start_pc = #func.instructions
      -- generate body
      generate_scope(stat, func)

      local do_jump_back
      -- TODO: this optimization should probably be moved out
      if is_falsy(stat.condition) then
        -- always false, always jump
        do_jump_back = true
      elseif const_node_types[stat.condition.node_type] then
        -- always true, always leave
        do_jump_back = false
      else
        -- generate condition and test
        generate_test_code(stat.condition, func)
        -- jump back if it failed
        do_jump_back = true
      end
      if do_jump_back then
        func.instructions[#func.instructions+1] = {
          op = opcodes.jmp, a = 0, sbx = start_pc - (#func.instructions + 1),
          line = stat.until_token and stat.until_token.line,
          column = stat.until_token and stat.until_token.column,
        }
      end
      patch_breaks_to_jump_here(stat, func)
    end,

    ---@param stat AstRetStat
    retstat = function(stat,func)
      local temp_reg = 0
      local num_results = 0
      if stat.exp_list then
        num_results = #stat.exp_list
        if num_results > 0 and is_vararg(stat.exp_list[num_results]) then
          num_results = -1
        end
        temp_reg = peek_next_reg(func)
        generate_exp_list(stat.exp_list, temp_reg, func, num_results)
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes["return"], a = temp_reg, b = num_results + 1,
        line = stat.return_token and stat.return_token.line,
        column = stat.return_token and stat.return_token.column,
      }
    end,

    label = function(stat,func)
      local label_position = {
        scope = func.current_scope,
        pc = #func.instructions,
      }
      func.label_positions[stat] = label_position
      for _, go in ipairs(stat.linked_gotos) do
        if go.inst then
          -- forwards jump
          go.inst.sbx = #func.instructions - go.pc
          go.inst.a = get_a_for_jump(go, label_position, func)
          -- cleanup
          go.inst = nil
          go.pc = nil
          go.scope = nil
        end
      end
    end,
    gotostat = function(stat,func)
      local inst = {
        op = opcodes.jmp, a = nil, sbx = nil,
        line = stat.goto_token and stat.goto_token.line,
        column = stat.goto_token and stat.goto_token.column,
      }
      func.instructions[#func.instructions+1] = inst
      stat.pc = #func.instructions
      stat.scope = func.current_scope
      local label_position = func.label_positions[stat.linked_label]
      if label_position then
        -- backwards jump
        inst.sbx = label_position.pc - stat.pc
        inst.a = get_a_for_jump(stat, label_position, func)
        -- cleanup
        stat.pc = nil
        stat.scope = nil
      else
        -- store for the label to link forwards jumps
        stat.inst = inst
      end
    end,
    breakstat = function(stat,func)
      local inst = {
        op = opcodes.jmp, a = nil, sbx = nil,
        line = stat.break_token and stat.break_token.line,
        column = stat.break_token and stat.break_token.column,
      }
      func.instructions[#func.instructions+1] = inst
      stat.inst = inst
      stat.pc = #func.instructions
      -- figure out if and how far it needs to close upvals
      local scopes_that_matter_lut = {}
      local scope = func.current_scope
      while true do
        scopes_that_matter_lut[scope] = true
        if scope == stat.linked_loop then
          break
        end
        scope = scope.parent_scope
      end
      -- this is copy paste from `generate_scope`
      local lowest_captured_reg
      for _, live in ipairs(func.live_regs) do
        -- except this condition
        if scopes_that_matter_lut[live.scope] and live.upval_capture_pc and live.upval_capture_pc < stat.pc then
          if (not lowest_captured_reg) or live.reg < lowest_captured_reg then
            lowest_captured_reg = live.reg
          end
        end
      end
      inst.a = (lowest_captured_reg or -1) + 1
      -- whilestat, fornum, forlist and repeatstat set sbx
    end,

    empty = function(stat,func)
      -- empty statement
    end,

    inline_iife_retstat = function(stat,func)
      if stat.exp_list then
        generate_exp_list(
          stat.exp_list,
          stat.linked_inline_iife.in_reg,
          func,
          stat.linked_inline_iife.num_results
        )
      else
        generate_expr({
          node_type = "nil",
          line = stat.line,
          column = stat.column,
        },
          stat.linked_inline_iife.in_reg,
          func,
          stat.linked_inline_iife.num_results
        )
      end
    end,
  }
  function generate_code(functiondef)
    local debug_registers = {}
    local func = {
      line_defined = functiondef.function_token and functiondef.function_token.line,
      column_defined = functiondef.function_token and functiondef.function_token.column,
      last_line_defined = functiondef.end_token and functiondef.end_token.line,
      last_column_defined = functiondef.end_token and functiondef.end_token.column,
      num_params = functiondef.num_params,
      is_vararg = functiondef.is_vararg,
      max_stack_size = 2,
      instructions = {},
      constants = {},
      inner_functions = {},
      upvals = {},
      source = functiondef.source,
      debug_registers = debug_registers, -- cleaned up at the end
      ---temporary data during compilation
      live_regs = debug_registers,
      next_reg = 0,
      level = 0,
      scope_levels = {},
      label_positions = {}, -- `pc` and `scope` labels are in, needed for backwards jmp `a` and `sbx`
      current_scope = nil, -- managed by generate_scope
    }

    local upvals = func.upvals
    for i,upval in ipairs(functiondef.upvals) do
      local index = i - 1 -- *ZERO BASED* index
      upvals[i] = {
        index = index,
        name = upval.name,
        in_stack = upval.in_stack,
        local_idx = upval.local_idx,
        upval_idx = upval.upval_idx,
      }
      -- temporary, needed for closures to know the upval_idx to use
      upval.index = index

      -- since the parent function already evaluated these, it now
      -- just gets moved to the new data structure and deleted from the old one
      upval.in_stack = nil
      upval.local_idx = nil
      upval.upval_idx = nil
    end
    -- env being special as always
    if functiondef.is_main and upvals[1] then
      assert(upvals[1].name == "_ENV")
      upvals[1].in_stack = true
      upvals[1].local_idx = 0
    end

    for i,func_proto in ipairs(functiondef.func_protos) do
      -- temporary, needed for closures to know the function index
      func_proto.index = i - 1 -- *ZERO BASED* index
    end

    -- compile
    generate_scope(functiondef, func, function()
      for _, loc in ipairs(functiondef.locals) do
        if loc.whole_block then
          local live = create_live_reg(func, next_reg(func), loc.name)
          live.start_at = 1
        end
      end
    end)

    -- TODO: temp until it can be determined if the end of the function is reachable
    generate_statement({
      node_type = "retstat",
      return_token = functiondef.end_token or {
        node_type = "token",
        line = get_last_used_line(func),
        column = get_last_used_column(func),
      },
    }, func)

    -- debug_registers cleanup
    for _, reg in ipairs(debug_registers) do
      reg.level = nil
      reg.scope = nil
      reg.in_scope_at = nil
    end

    -- cleanup
    for _,func_proto in ipairs(functiondef.func_protos) do
      func_proto.index = nil
    end

    for _,upval in ipairs(func.upvals) do
      upval.index = nil
    end
    for _,upval in ipairs(functiondef.upvals) do
      upval.index = nil
    end

    func.live_regs = nil
    func.next_reg = nil
    func.level = nil
    func.scope_levels = nil
    func.label_positions = nil
    -- func.current_scope = nil -- is already `nil` after generate_scope

    -- inner_functions
    for i, func_proto in ipairs(functiondef.func_protos) do
      func.inner_functions[i] = generate_code(func_proto)
    end

    return func
  end
end

return generate_code
