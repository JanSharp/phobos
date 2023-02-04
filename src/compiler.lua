
local phobos_consts = require("constants")
local util = require("util")
local ast = require("ast_util")
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes

----------------------------------------------------------------------
local generate_code
do
  ---@param func CompiledFunc
  ---@return integer?
  local function get_last_used_line(func)
    return (#func.instructions > 0)
      and func.instructions[#func.instructions].line
      or nil
  end

  ---@param func CompiledFunc
  ---@return integer?
  local function get_last_used_column(func)
    return (#func.instructions > 0)
      and func.instructions[#func.instructions].column
      or nil
  end

  local function get_level(scope, func)
    return func.scope_levels[scope]
      or assert(false, "Trying to get the level for a scope that has not been reached yet")
  end
  local function get_current_level(func)
    -- technically this could just return `func.level`, but i wanted to follow
    -- the "convention" of always using the `get_level` function
    return get_level(func.current_scope, func)
  end

  local function create_stack()
    return {
      max_stack_size = 0,
      next_reg_index = 0, -- **zero based**
      registers = {}, -- all registers
      active_registers = {}, -- started or to be started registers that are not stopped
      completed_registers = {}, -- similar to `registers` but invalid registers are excluded
      -- (registers get added in release_reg to this, while use_reg adds them to the other 2)
    }
    -- NOTE: in selfcall for the self instruction it is possible for `b` to be a temp register which
    -- actually ends up stopping just before the instruction. While this is not an issue, it is
    -- something to keep in mind, because it's something i've been trying to avoid as best as possible
    -- (note that this might not be the only case, just the only one i noticed)
  end

  local function peek_next_reg_index(func)
    return func.stack.next_reg_index
  end

  local function get_top(func)
    return func.stack.next_reg_index - 1
  end

  local function reg_is_top_or_above(reg, func)
    return reg.index >= get_top(func)
  end

  local function regs_are_in_order(regs, num_results, first_index)
    if first_index then
      if regs[num_results].index ~= first_index then
        return false
      end
    else
      first_index = regs[num_results].index
    end
    for i = num_results - 1, 1, -1 do
      first_index = first_index + 1
      if regs[i].index ~= first_index then
        return false
      end
    end
    return true
  end

  local function regs_are_at_top_in_order(regs, num_results, func)
    return regs_are_in_order(regs, num_results, func.stack.next_reg_index)
  end

  local function create_temp_reg(func, index)
    return {
      index = index or peek_next_reg_index(func),
      level = get_current_level(func), -- TODO: what are these even for
      scope = func.current_scope, -- TODO: what are these even for
      temporary = true,
    }
  end

  local function create_local_reg(local_def, func, index)
    local reg = create_temp_reg(func, index)
    reg.name = local_def.name
    reg.temporary = nil
    local_def.register = reg
    return reg
  end

  local function release_reg(reg, func, stop_at, allow_not_at_top)
    if reg.stop_at then
      return
    end
    if reg.index == get_top(func) then
      func.stack.next_reg_index = func.stack.next_reg_index - 1
    elseif not allow_not_at_top then
      error("Attempted to release register "..reg.index.." when top was "..get_top(func))
    end
    func.stack.active_registers[reg.index] = nil
    reg.stop_at = stop_at or #func.instructions
    if reg.start_at <= reg.stop_at then
      func.stack.completed_registers[#func.stack.completed_registers+1] = reg
    end
  end

  local function release_temp_reg(reg, func, stop_at)
    if reg.temporary then
      release_reg(reg, func, stop_at)
    end
  end

  local function release_temp_regs(regs, func, stop_at)
    for _, reg in ipairs(regs) do
      release_temp_reg(reg, func, stop_at)
    end
  end

  ---releases all regs down to `reg_index` but keeps `reg_index` live
  local function release_down_to(reg_index, func)
    if reg_index > get_top(func) then
      error("Attempted to release registers down to "..reg_index.." when top was "..get_top(func))
    end
    for i = get_top(func), reg_index + 1, -1 do
      release_reg(func.stack.active_registers[i], func)
    end
  end

  local function use_reg(reg, func, start_at)
    if reg.start_at then
      return reg
    end
    if func.stack.next_reg_index ~= reg.index then
      release_reg(func.stack.active_registers[reg.index], func, nil, true)
    end
    if func.stack.next_reg_index == reg.index then
      func.stack.next_reg_index = reg.index + 1
    end
    if func.stack.max_stack_size < reg.index + 1 then
      func.stack.max_stack_size = reg.index + 1
    end
    reg.start_at = start_at or #func.instructions + 1
    func.stack.registers[#func.stack.registers+1] = reg
    func.stack.active_registers[reg.index] = reg
    return reg
  end

  local function find_local(local_ref)
    return assert(local_ref.reference_def.register)
  end

  local function find_upval(upval_ref)
    return assert(upval_ref.reference_def.index)
  end

  local generate_expr_code
  local function generate_expr(expr,num_results,func,regs)
    if num_results == -1 and not reg_is_top_or_above(regs[num_results], func) then
      assert(false, "Attempt to generate '"..expr.node_type
        .."' expression with var results into register "
        ..regs[-1].index.." when top was "..get_top(func)
      )
    end
    local manage_temp = num_results == 0 and not regs
    if manage_temp then
      regs = {[0] = create_temp_reg(func)}
    end
    generate_expr_code[expr.node_type](
      expr,
      expr.force_single_result and 1 or num_results,
      func,
      expr.force_single_result and {regs[num_results]} or regs
    )
    if manage_temp then
      release_temp_reg(regs[0], func)
    end
    if num_results > 1 and ast.is_single_result_node(expr) then
      -- in a case like `local foo, bar; foo, bar = (...)`
      -- this will LOADNIL into `bar` before the assignment MOVEs the temporary
      -- register into `foo`. Note that the index of the temp is higher than `bar`
      -- TODO: so if there can be GC between LOADNIL and MOVE then that's a problem
      -- and I can't think of a good or easy way to put this LOADNIL after that MOVE
      -- (note that this might not be the only case where this applies)
      generate_expr({
        node_type = "nil",
        line = get_last_used_line(func),
        column = get_last_used_column(func),
      }, num_results - 1, func, regs)
    end
  end

  local function generate_exp_list(exp_list,num_results,func,regs)
    if num_results > 0 and (#exp_list) == 0 then
      -- it wants results but there are no expressions to generate, so just generate nil
      generate_expr({
        node_type = "nil",
        line = get_last_used_line(func),
        column = get_last_used_column(func),
      }, num_results, func, regs)
      return
    end

    local expr_regs = {}
    local num_exp = #exp_list
    for i,expr in ipairs(exp_list) do
      if num_results ~= -1 and i > num_results then
        generate_expr(expr, 0, func)
      elseif i == num_exp then
        local this_expr_regs
        local expr_num_results
        if num_results ~= -1 then
          this_expr_regs = regs
          expr_num_results = (num_results - num_exp) + 1
        elseif ast.is_vararg_node(expr) then
          this_expr_regs = expr_regs
          expr_num_results = -1
          expr_regs[-1] = regs[1]
        else
          this_expr_regs = regs
          expr_num_results = 1
        end
        generate_expr(expr, expr_num_results, func, this_expr_regs)
        expr_regs[-1] = nil
      else
        expr_regs[1] = regs[#regs - i + 1]
        generate_expr(expr, 1, func, expr_regs)
        expr_regs[1] = nil
      end
    end
  end

  local generate_statement_code
  local function generate_statement(stat, func)
    generate_statement_code[stat.node_type](stat, func)
  end

  local function get_lowest_captured_reg(scope, func)
    local lowest_captured_reg
    for _, reg in ipairs(func.stack.registers) do -- TODO: could this use active_registers? (also check other similar cases)
      if reg.scope == scope and reg.upval_capture_pc then
        if (not lowest_captured_reg) or reg.index < lowest_captured_reg.index then
          lowest_captured_reg = reg
        end
      end
    end
    return lowest_captured_reg
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
    local stat = scope.body.first
    while stat do
      generate_statement(stat, func)
      stat = stat.next
    end
    if post_block then
      post_block()
    end

    if func.level ~= 1 then -- no need to do anything in the root scope
      -- TODO: this condition can be improved once the compiler knows that [...]
      -- the given location (the end of the scope) is unreachable
      -- note that the root scope might still be an exception at that point
      local lowest_captured_reg = get_lowest_captured_reg(scope, func)
      if lowest_captured_reg then
        func.instructions[#func.instructions+1] = {
          -- the +1 for `a` is handled after generating all code for this function
          op = opcodes.jmp, a = lowest_captured_reg, sbx = 0,
          -- TODO: better selection than hard coded `end_token`, see repeatstat for example
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
    -- TODO: what does this mean: [...]
    -- unless const table is too big, then fetch into temporary (and emit warning: const table too large)
    -- (comment was from justarandomgeek originally in the binop function)

    if new_constant.value == nil then
      if func.nil_constant_idx then
        return func.nil_constant_idx
      end
      func.nil_constant_idx = #func.constants
      func.constants[func.nil_constant_idx+1] = {node_type = "nil"}
      return func.nil_constant_idx
    end

    if new_constant.value ~= new_constant.value then
      if func.nan_constant_idx then
        return func.nan_constant_idx
      end
      func.nan_constant_idx = #func.constants
      func.constants[func.nan_constant_idx+1] = {node_type = "number", value = 0/0}
      return func.nan_constant_idx
    end

    if func.constant_lut[new_constant.value] then
      return func.constant_lut[new_constant.value]
    end
    local i = #func.constants
    func.constants[i+1] = {
      node_type = new_constant.node_type,
      value = new_constant.value,
    }
    func.constant_lut[new_constant.value] = i
    return i
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

  local function local_or_fetch(expr,func)
    if expr.node_type == "local_ref" then
      return find_local(expr)
    else
      local reg = create_temp_reg(func)
      generate_expr(expr,1,func,{reg})
      return reg
    end
  end

  local function generate_const_code_internal(expr, k, func, reg)
    if k <= 0x3ffff then
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadk, a = use_reg(reg, func), bx = k,
        line = expr.line, column = expr.column,
      }
    else
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadkx, a = use_reg(reg, func),
        line = expr.line, column = expr.column,
      }
      func.instructions[#func.instructions+1] = {
        op = opcodes.extraarg, ax = k,
        line = expr.line, column = expr.column,
      }
    end
  end

  local function generate_const_code(expr,num_results,func,regs)
    generate_const_code_internal(expr, add_constant(expr, func), func, regs[num_results])
  end

  local const_node_types = util.invert{"boolean","nil","string","number"}
  local function const_or_local_or_fetch(expr,func)
    if const_node_types[expr.node_type] then
      local k = add_constant(expr, func)
      if k >= 0x100 then
        local reg = create_temp_reg(func)
        generate_const_code_internal(expr, k, func, reg)
        return reg, false
      end
      return bit32.bor(add_constant(expr,func),0x100), true
    else
      return local_or_fetch(expr,func), false
    end
  end

  local function upval_or_local_or_fetch(expr,func)
    if expr.node_type == "upval_ref" then
      return expr.reference_def.index, true
    else
      return local_or_fetch(expr,func), false
    end
  end

  local function eval_upval_indexes(target_func_proto, func)
    for _, upval in ipairs(target_func_proto.func_def.upvals) do
      upval.in_stack = ast.upval_is_in_stack(upval)
      if upval.in_stack then
        local reg = upval.parent_def.register
        upval.local_idx = reg.index
        if not reg.upval_capture_pc then
          reg.upval_capture_pc = #func.instructions
        end
      else
        upval.upval_idx = upval.parent_def.index
      end
    end
  end

  local function get_real_expr(node)
    local not_count = 0
    while node.node_type == "unop" and node.op == "not" do
      node = node.ex
      not_count = not_count + 1
    end
    return node, not_count
  end

  local function is_branchy(node)
    node = get_real_expr(node)
    return node.node_type == "binop"
      and (
        logical_binop_lut[node.op]
        or node.op == "and"
        or node.op == "or"
      )
  end

  local function jump_here(jumps, func)
    for _, jump in ipairs(jumps) do
      jump.sbx = #func.instructions - jump.pc
      jump.pc = nil
    end
  end

  local function generate_move(target_reg, source_reg, position, func)
    -- TODO: this index comparison will have to change once stack merging is implemented
    if target_reg.index ~= source_reg.index then
      func.instructions[#func.instructions+1] = {
        op = opcodes.move, a = target_reg, b = source_reg,
        line = position and position.line,
        column = position and position.column,
      }
    end
  end

  local test_expr_with_result
  local test_expr_and_jump
  do

    local function eval_inverted(not_count, inverted)
      -- if not_count is uneven then invert `inverted`
      return inverted ~= ((not_count % 2) == 1)
    end

    local function eval_force_bool_result(not_count, force_bool_result)
      -- if there was at least one `not` unop force_bool_result has to be `true`
      -- otherwise fall back to the initial value
      return (not_count >= 1) or force_bool_result
    end

    local function create_test(expr, op_token, jump_if_true, jump_target)
      return {
        type = "test",
        expr = expr.expr,
        line = op_token and op_token.line,
        column = op_token and op_token.column,
        jump_if_true = jump_if_true ~= expr.inverted,
        jump_to_success = jump_if_true, --~= expr.inverted,
        jump_target = jump_target,
        force_bool_result = expr.force_bool_result,
      }
    end

    local function create_expr(expr, inverted, force_bool_result)
      local not_count
      expr, not_count = get_real_expr(expr)
      return {
        type = "expr",
        expr = expr,
        inverted = eval_inverted(not_count, inverted),
        force_bool_result = eval_force_bool_result(not_count, force_bool_result),
      }
    end

    local create_jump_target
    do
      ---this id is purely used for debugging
      ---the actual algorithm uses table identity
      local id = 0
      function create_jump_target()
        id = id + 1
        return {id = id}
      end
    end

    local function generate_test_chain(node, chain, func, jump_if_true, jump_target, store_result)
      local expr = node.expr

      if expr.node_type == "binop" then
        if expr.op == "and" or expr.op == "or" then
          jump_if_true = (expr.op == "or") ~= node.inverted

          local jump_here_target = create_jump_target()
          local left = create_expr(expr.left, node.inverted, node.force_bool_result) ---@type table?

          while left and is_branchy(left.expr) do
            local real_expr, not_count = get_real_expr(left.expr)
            local inverted = eval_inverted(not_count, left.inverted)
            local inner_jump_target
            if real_expr.node_type == "binop" -- is the inner expr part of this "chain"?
              and (
                logical_binop_lut[real_expr.op]
                or (
                  (real_expr.op == "and" or real_expr.op == "or")
                  and (
                    (real_expr.op == expr.op and inverted == node.inverted)
                    or (real_expr.op ~= expr.op and inverted ~= node.inverted)
                  )
                )
              )
            then -- if so jump to the same target this test will
              inner_jump_target = jump_target
            else -- otherwise jump to (just past) this test
              inner_jump_target = jump_here_target
            end
            left = generate_test_chain(left, chain, func, jump_if_true, inner_jump_target, store_result)
          end

          if left then
            chain[#chain+1] = create_test(left, expr.op_token, jump_if_true, jump_target)
          end

          -- tell inner chains to jump to right after this test (or logical test)
          if left or chain[#chain].type == "logical" then
            chain[#chain].jump_here_target = jump_here_target
          end

          return create_expr(expr.right, node.inverted, node.force_bool_result)
        elseif logical_binop_lut[expr.op] then

          local test = create_test(node, expr.op_token, jump_if_true, jump_target)
          test.type = "logical"
          test.expr = expr
          test.force_bool_result = true
          chain[#chain+1] = test
          return
        end
      end

      if jump_target.is_main and store_result and ((not node.force_bool_result) or node.inverted) then
        chain[#chain+1] = create_expr(expr, node.inverted, node.force_bool_result)
        chain[#chain].jump_target = jump_target
      else
        chain[#chain+1] = create_test(node, ast.get_main_position(node.expr), jump_if_true, jump_target)
      end
    end

    local function generate_test_test(test, reg, store_result, func)
      local expr = test.expr
      local line = test.line
      local column = test.column

      local expr_reg = local_or_fetch(expr, func)
      if store_result
        and test.jump_target.is_main
        and (not test.force_bool_result)
        -- TODO: this index comparison will have to change once stack merging is implemented
        and (reg.index ~= expr_reg.index)
      then
        -- NOTE: `reg` is not yet used (has not started yet), but this instruction references it anyway
        func.instructions[#func.instructions+1] = {
          op = opcodes.testset, a = reg, b = expr_reg, c = test.jump_if_true and 1 or 0,
          line = line, column = column,
        }
      else
        func.instructions[#func.instructions+1] = {
          op = opcodes.test, a = expr_reg, c = test.jump_if_true and 1 or 0,
          line = line, column = column,
        }
      end
      local jump = {
        op = opcodes.jmp, a = 0, sbx = nil,
        line = line, column = column,
        force_bool_result = test.force_bool_result,
        jump_to_success = test.jump_to_success,
      }
      func.instructions[#func.instructions+1] = jump
      jump.pc = #func.instructions
      release_temp_reg(expr_reg, func)
      return jump
    end

    local function generate_logical_test(test, func)
      local expr = test.expr
      local line = test.line
      local column = test.column

      local left_reg, left_is_const = const_or_local_or_fetch(expr.left,func)
      local right_reg, right_is_const = const_or_local_or_fetch(expr.right,func)
      func.instructions[#func.instructions+1] = {
        op = logical_binop_lut[expr.op], a = (logical_invert_lut[expr.op] ~= test.jump_if_true) and 1 or 0,
        b = left_reg, c = right_reg,
        line = line, column = column,
      }
      local jump = {
        op = opcodes.jmp, a = 0, sbx = nil,
        line = line, column = column,
        force_bool_result = test.force_bool_result,
        jump_to_success = test.jump_to_success,
      }
      func.instructions[#func.instructions+1] = jump
      jump.pc = #func.instructions
      if not right_is_const then release_temp_reg(right_reg, func) end
      if not left_is_const then release_temp_reg(left_reg, func) end
      return jump
    end

    local function finish_test_expr_storing_result(chain, jumps, reg, func)
      local load_false = false
      local load_true = false

      if chain[#chain].type ~= "expr" and chain[#chain].force_bool_result then
        load_false = true
        load_true = true
      else
        for _, jump in ipairs(jumps) do
          if jump.force_bool_result then
            if jump.jump_to_success then
              load_true = true
            else
              load_false = true
            end
          end
        end
      end

      if (load_true or load_false) and chain[#chain].type == "expr" then
        local jump = {
          op = opcodes.jmp, a = 0, sbx = nil,
          line = chain[#chain].line,
          column = chain[#chain].column,
          force_bool_result = false,
          jump_to_success = true,
        }
        jumps[#jumps+1] = jump
        func.instructions[#func.instructions+1] = jump
        jump.pc = #func.instructions
      end

      local true_pc
      local false_pc

      local function generate_loadbool(value, skip_next)
        func.instructions[#func.instructions+1] = {
          op = opcodes.loadbool, a = use_reg(reg, func), b = value and 1 or 0, c = skip_next and 1 or 0,
          line = chain[#chain].line,
          column = chain[#chain].column,
        }
      end
      local function generate_false(skip_next)
        if load_false then
          false_pc = #func.instructions
          generate_loadbool(false, skip_next)
        end
      end
      local function generate_true(skip_next)
        if load_true then
          true_pc = #func.instructions
          generate_loadbool(true, skip_next)
        end
      end

      if chain[#chain].type ~= "expr" and chain[#chain].jump_to_success then
        generate_false(load_true)
        generate_true()
      else
        generate_true(load_false)
        generate_false()
      end

      for _, jump in ipairs(jumps) do
        if jump.force_bool_result then
          if jump.jump_to_success then
            jump.sbx = true_pc - jump.pc
          else
            jump.sbx = false_pc - jump.pc
          end
        else
          jump.sbx = #func.instructions - jump.pc
        end
        jump.pc = nil
        jump.force_bool_result = nil
        jump.jump_to_success = nil
      end
    end

    local function test_expr(node, reg, jump_if_true, func)
      assert(jump_if_true ~= nil)

      local store_result = not not reg
      local chain = {}
      local leave_jump_target = create_jump_target()
      leave_jump_target.is_main = true

      local last_expr = create_expr(node, false, false) ---@type table?
      repeat
        last_expr = generate_test_chain(last_expr, chain, func, jump_if_true, leave_jump_target, store_result)
      until not last_expr

      local jumps = {}
      for _, test in ipairs(chain) do
        local function add_jump(jump)
          local jumps_to_jump_target = jumps[test.jump_target]
          if not jumps_to_jump_target then
            jumps_to_jump_target = {}
            jumps[test.jump_target] = jumps_to_jump_target
          end
          jumps_to_jump_target[#jumps_to_jump_target+1] = jump
        end

        if test.type == "expr" then
          if test.inverted then
            generate_expr({
              node_type = "unop",
              op = "not",
              op_token = ast.get_main_position(test.expr),
              ex = test.expr,
            }, 1, func, {reg})
          else
            generate_expr(test.expr, 1, func, {reg})
          end
        else
          if test.type == "test" then
            add_jump(generate_test_test(test, reg, store_result, func))
          elseif test.type == "logical" then
            add_jump(generate_logical_test(test, func))
          else
            error("Invalid test type '"..test.type.."'.")
          end

          for _, jump in ipairs(jumps[test.jump_here_target] or {}) do
            jump.sbx = #func.instructions - jump.pc
            jump.pc = nil
            jump.force_bool_result = nil
            jump.jump_to_success = nil
          end
        end
      end

      jumps = jumps[leave_jump_target] or {}

      if store_result then
        finish_test_expr_storing_result(chain, jumps, reg, func)
        assert(reg.start_at, "There is somehow a path where a test expr with result \z
          didn't end up using the result register. The only instructions that reference \z
          the register but don't actually use it are testset, but there should always be \z
          either a last expression or a loadbool at the end, right?"
        )
      else
        local result = {}
        for _, jump in ipairs(jumps) do
          if jump.jump_to_success == jump_if_true then
            result[#result+1] = jump
          else
            jump.sbx = #func.instructions - jump.pc
            jump.pc = nil
          end
          jump.force_bool_result = nil
          jump.jump_to_success = nil
        end
        return result
      end
    end

    function test_expr_with_result(node, reg, func)
      -- jump_if_true can be false or true, doesn't matter (i think)
      test_expr(node, reg, true, func)
    end

    function test_expr_and_jump(node, jump_if_true, func)
      return test_expr(node, nil, jump_if_true, func)
    end

  end

  local function get_position_for_call_instruction(expr)
    local position = expr.open_paren_token
    if (not position) and #expr.args == 1 then
      if expr.args[1].node_type == "string" then
        position = expr.args[1]
      elseif expr.args[1].node_type == "constructor" then
        position = expr.args[1].open_token
      end
    end
    return position
  end

  local function generate_call(expr,num_results,func,regs,is_tail_call,get_func_reg)
    -- out of order regs can be a problem
    -- if they would require moves both up and down the stack
    -- because values would most likely get overwritten with the current algorithm.
    -- there is no check for this right now because nothing is creating
    -- such `regs` tables, but it may be required to handle it somehow in the future
    local need_temps = not regs_are_at_top_in_order(regs, num_results, func)
    if is_tail_call then
      assert(not need_temps, "When generating a tailcall the given regs must be at top in order")
    end
    local func_reg, first_arg_reg = get_func_reg()
    local args_regs = {}
    local num_args = #expr.args
    for i = 1, num_args do
      args_regs[num_args - i + 1] = create_temp_reg(func, get_top(func) + i)
    end
    generate_exp_list(expr.args,-1,func,args_regs)
    if num_args > 0 and ast.is_vararg_node(expr.args[num_args]) then
      num_args = -1
    else
      num_args = num_args + (first_arg_reg and 1 or 0)
    end
    local position = get_position_for_call_instruction(expr)
    func.instructions[#func.instructions+1] = {
      op = is_tail_call and opcodes.tailcall or opcodes.call,
      a = func_reg, b = num_args + 1, c = not is_tail_call and num_results + 1 or nil,
      line = position and position.line,
      column = position and position.column,
    }
    local temp_regs
    if not need_temps then
      temp_regs = regs
    else
      assert(num_results >= 1, "Impossible because generate_expr makes sure this isn't the case")
      temp_regs = {}
      for i = 1, num_results do
        temp_regs[num_results - i + 1] = create_temp_reg(func, func_reg.index - 1 + i)
      end
    end
    use_reg(temp_regs[num_results], func) -- num_results may be -1 or 0
    for i = num_results - 1, 1, -1 do -- num_results itself is used above
      use_reg(temp_regs[i], func)
    end
    release_temp_regs(args_regs, func)
    if first_arg_reg then
      release_temp_reg(first_arg_reg, func)
    end
    release_temp_reg(func_reg, func)
    if need_temps then
      for i = num_results, 1, -1 do
        generate_move(use_reg(regs[i], func), temp_regs[i], position, func)
      end
      release_temp_regs(temp_regs, func)
    end
    -- if this isn't using temps and the last node that gets generated in a scope is a call
    -- the registers passed into this function will start_at _past_ the call instruction
    -- but stop_at _at_ the call instruction.
    -- those are malformed registers, and requires some sort of handling
    -- i'm not how though
    -- in all other expressions and statements end up using the regs passed into them
    -- starting at some instruction they generate, which avoids this issue
    -- it might be required to behave the same in here as well, but evaluating the
    -- right register reference for the call itself is awkward if it should be avoided to
    -- use a reference to an already stopped register: func_reg
    --
    -- update: this is now handled by completed_registers. release_reg only adds
    -- valid registers to said array
  end

  local function generate_call_node(node,num_results,func,regs,is_tail_call)
    if not node.is_selfcall then
      generate_call(node, num_results, func, regs, is_tail_call, function()
        local func_reg = create_temp_reg(func)
        generate_expr(node.ex,1,func,{func_reg})
        return func_reg
      end)
    else
      generate_call(node, num_results, func, regs, is_tail_call, function()
        local func_reg = create_temp_reg(func)
        local first_arg_reg = create_temp_reg(func, get_top(func) + 2)
        local ex_reg = local_or_fetch(node.ex, func)
        local suffix_reg, suffix_is_const = const_or_local_or_fetch(node.suffix, func)
        -- maybe these 2 should be used after the instruction
        use_reg(func_reg, func)
        use_reg(first_arg_reg, func)
        func.instructions[#func.instructions+1] = {
          op = opcodes.self, a = func_reg, b = ex_reg, c = suffix_reg,
          line = node.colon_token and node.colon_token.line,
          column = node.colon_token and node.colon_token.column,
        }
        if not suffix_is_const then release_temp_reg(suffix_reg) end
        release_temp_reg(ex_reg)
        return func_reg, first_arg_reg
      end)
    end
  end

  generate_expr_code = {
    local_ref = function(expr,num_results,func,regs)
      generate_move(use_reg(regs[num_results], func), find_local(expr), expr, func)
    end,
    upval_ref = function(expr,num_results,func,regs)
      func.instructions[#func.instructions+1] = {
        op = opcodes.getupval, a = use_reg(regs[num_results], func), b = find_upval(expr),
        line = expr.line, column = expr.column,
      }
    end,
    ---@param expr AstBinOp
    binop = function(expr,num_results,func,regs)
      if logical_binop_lut[expr.op] or expr.op == "and" or expr.op == "or" then
        test_expr_with_result(expr, regs[num_results], func)
      elseif bin_opcode_lut[expr.op] then
        local left_reg, left_is_const = const_or_local_or_fetch(expr.left,func)
        local right_reg, right_is_const = const_or_local_or_fetch(expr.right,func)
        func.instructions[#func.instructions+1] = {
          op = bin_opcode_lut[expr.op], a = use_reg(regs[num_results], func), b = left_reg, c = right_reg,
          line = expr.op_token and expr.op_token.line,
          column = expr.op_token and expr.op_token.column,
        }
        if not right_is_const then release_temp_reg(right_reg, func) end
        if not left_is_const then release_temp_reg(left_reg, func) end
      else
        error("Invalid binop operator '"..expr.op.."'.")
      end
    end,
    unop = function(expr,num_results,func,regs)
      local real_expr, not_count = get_real_expr(expr)
      if not_count > 1 or is_branchy(real_expr) then
        test_expr_with_result(expr, regs[num_results], func)
      else
        local src_reg = local_or_fetch(expr.ex,func)
        func.instructions[#func.instructions+1] = {
          op = un_opcodes[expr.op], a = use_reg(regs[num_results], func), b = src_reg,
          line = expr.op_token and expr.op_token.line,
          column = expr.op_token and expr.op_token.column,
        }
        release_temp_reg(src_reg, func)
      end
    end,
    concat = function(expr,num_results,func,regs)
      -- OP_CONCAT does run `checkGC`, but in a way that allows directly assigning to a not at top register
      -- it's logic is `checkGC(L, (ra >= rb ? ra + 1 : rb));`
      local num_exp = #expr.exp_list
      local temp_regs = {}
      for i = 1, num_exp do
        temp_regs[num_exp - i + 1] = create_temp_reg(func, get_top(func) + i)
      end
      generate_exp_list(expr.exp_list,num_exp,func,temp_regs)
      local position = expr.op_tokens and expr.op_tokens[1]
      func.instructions[#func.instructions+1] = {
        op = opcodes.concat, a = use_reg(regs[num_results], func),
        b = temp_regs[num_exp], c = temp_regs[1],
        line = position and position.line,
        column = position and position.column,
      }
      release_temp_regs(temp_regs, func)
    end,
    number = generate_const_code,
    string = generate_const_code,
    boolean = function(expr,num_results,func,regs)
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadbool, a = use_reg(regs[num_results], func), b = expr.value and 1 or 0, c = 0,
        line = expr.line, column = expr.column,
      }
    end,
    ["nil"] = function(expr,num_results,func,regs)
      -- TODO: check if the "combine loadnil" optimization is enabled
      local prev = func.instructions[#func.instructions]
      if prev and prev.op == opcodes.loadnil and (prev.a.index + prev.b + 1) == regs[num_results].index then
        -- only combine if prev was loadnil and stops loading nils just before regs[num_results].index
        prev.b = prev.b + num_results
      else
        func.instructions[#func.instructions+1] = {
          op = opcodes.loadnil, a = regs[num_results], b = num_results - 1, -- from a to a + b
          line = expr.line, column = expr.column,
        }
      end
      for i = num_results, 1, -1 do
        use_reg(regs[i], func, #func.instructions)
      end
    end,
    constructor = function(expr,num_results,func,regs)
      -- OP_NEWTABLE runs `checkGC(L, ra + 1);` so we have to generate new tables at the top of the stack
      local tab_reg = use_reg(create_temp_reg(func), func)
      local new_tab = {
        op = opcodes.newtable, a = tab_reg, b = nil, c = nil, -- set later
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
          op = opcodes.setlist, a = tab_reg, b = count, c = flush_count,
          line = position.line,
          column = position.column,
        }
        release_down_to(initial_top, func)
      end

      for i,field in ipairs(expr.fields) do
        if field.type == "list" then
          -- if list accumulate values
          local temp_regs = {}
          local count = 1
          if i == fields_count and ast.is_vararg_node(field.value) then
            count = -1
          end
          temp_regs[count] = create_temp_reg(func)
          generate_expr(field.value,count,func,temp_regs)
          num_fields_to_flush = num_fields_to_flush + 1
          if count == -1 then
            flush(0, i) -- 0 means up to top
            total_rec_field_count = fields_count - total_list_field_count
            total_list_field_count = total_list_field_count - 1 -- don't count the vararg field
          elseif num_fields_to_flush == phobos_consts.fields_per_flush then
            flush(num_fields_to_flush, i)
          end
        elseif field.type == "rec" then
          -- if rec, set in table immediately
          local key_reg, key_is_const = const_or_local_or_fetch(field.key, func)
          local value_reg, value_is_const = const_or_local_or_fetch(field.value, func)
          func.instructions[#func.instructions+1] = {
            op = opcodes.settable, a = tab_reg, b = key_reg, c = value_reg,
            line = field.eq_token and field.eq_token.line,
            column = field.eq_token and field.eq_token.column,
          }
          if not value_is_const then release_temp_reg(value_reg, func) end
          if not key_is_const then release_temp_reg(key_reg, func) end
        else
          error("Invalid field type in table constructor")
        end
      end

      if num_fields_to_flush > 0 then
        flush(num_fields_to_flush, 0)
      end
      new_tab.b = util.number_to_floating_byte(total_list_field_count)
      new_tab.c = util.number_to_floating_byte(total_rec_field_count or (fields_count - total_list_field_count))
      generate_move(use_reg(regs[num_results], func), tab_reg, expr.open_token, func)
      release_temp_reg(tab_reg, func)
    end,
    func_proto = function(expr,num_results,func,regs)
      -- OP_CLOSURE runs `checkGC(L, ra + 1);` so we have to generate closures at the top of the stack
      local temp_reg = use_reg(create_temp_reg(func), func)
      local func_token = expr.func_def.function_token
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = temp_reg, bx = expr.func_def.index,
        line = func_token and func_token.line,
        column = func_token and func_token.column,
      }
      eval_upval_indexes(expr, func)
      generate_move(use_reg(regs[num_results], func), temp_reg, func_token, func)
      release_temp_reg(temp_reg, func)
    end,
    vararg = function(expr,num_results,func,regs)
      if not func.is_vararg then
        -- the parser also validates this, but AST can be transformed incorrectly
        assert(false, "Cannot generate vararg expression ('...') outside a vararg function.")
      end
      -- TODO: this is technically an optimization, so it probably shouldn't be here
      if num_results == 0 then
        return
      end
      local need_temps = not regs_are_at_top_in_order(regs, num_results, func)
      local temp_regs
      if not need_temps then
        temp_regs = regs
      else
        assert(num_results >= 1, "Impossible because generate_expr makes sure this isn't the case")
        temp_regs = {}
        local top = get_top(func)
        for i = 1, num_results do
          temp_regs[num_results - i + 1] = create_temp_reg(func, top + i)
        end
      end
      for i = num_results, 1, -1 do
        use_reg(temp_regs[i], func)
      end
      if num_results == -1 then
        use_reg(temp_regs[-1], func)
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.vararg, a = temp_regs[num_results], b = num_results + 1,
        line = expr.line, column = expr.column,
      }
      if need_temps then
        for i = num_results, 1, -1 do
          generate_move(use_reg(regs[i], func), temp_regs[i], expr, func)
        end
        release_temp_regs(temp_regs, func)
      end
    end,
    call = generate_call_node,
    index = function(expr,num_results,func,regs)
      local ex_reg, is_upval = upval_or_local_or_fetch(expr.ex,func)
      local suffix_reg, suffix_is_const = const_or_local_or_fetch(expr.suffix,func)
      local position = ast.get_main_position(expr)
      func.instructions[#func.instructions+1] = {
        op = is_upval and opcodes.gettabup or opcodes.gettable,
        a = use_reg(regs[num_results], func), b = ex_reg, c = suffix_reg,
        line = position and position.line,
        column = position and position.column,
      }
      if not suffix_is_const then release_temp_reg(suffix_reg, func) end
      if not is_upval then release_temp_reg(ex_reg, func) end
    end,

    inline_iife = function(expr,num_results,func,regs)
      -- TODO: handle vararg num_results [...]
      -- currently inline_iife is not marked as a vararg expression, but it totally is
      -- considering it is the replacement/inline variant of a function call.
      -- that means if a vararg result is expected this expression has to "return"
      -- (and in the process set top) however many expressions the inline_iife_retstat "returned"

      -- expr.in_reg = in_reg
      -- expr.num_results = num_results
      -- generate_scope(expr, func)
      -- expr.in_reg = nil
      -- expr.num_results = nil
      error("-- TODO: refactor me!")
    end,
  }

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
    local function should_close(index)
      if (not lowest_captured_reg) or index < lowest_captured_reg then
        lowest_captured_reg = index
      end
    end
    for _, reg in ipairs(func.stack.registers) do
      if scopes_that_matter_lut[reg.scope] and reg.upval_capture_pc and reg.upval_capture_pc < go.pc then
        if is_backwards then
          if (reg.in_scope_at or reg.start_at) > label_position.pc then -- goes out of scope when jumping back
            should_close(reg.index)
          end
        else
          if reg.stop_at and reg.stop_at <= label_position.pc then -- goes out of scope when jumping forward
            should_close(reg.index)
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
      local regs = {}
      for i, local_ref in ipairs(stat.lhs) do
        regs[#stat.lhs - i + 1] = create_local_reg(local_ref.reference_def, func, get_top(func) + i)
      end
      if stat.rhs then
        generate_exp_list(stat.rhs, #stat.lhs, func, regs)
      else
        generate_expr({
          node_type = "nil",
          line = stat.lhs[1].line,
          column = stat.lhs[1].column,
        }, #stat.lhs, func, regs)
      end
    end,
    assignment = function(stat,func)
      local original_top = get_top(func)
      local lefts = {}
      for i,left in ipairs(stat.lhs) do
        if left.node_type == "local_ref" then
          lefts[i] = {
            type = "local",
            reg = find_local(left),
          }
        elseif left.node_type == "upval_ref" then
          lefts[i] = {
            type = "upval",
            upval_idx = find_upval(left),
          }
        elseif left.node_type == "index" then
          -- if index and parent not local/upval, fetch parent to temporary
          local new_left = {
            type = "index",
          }
          new_left.ex_reg, new_left.ex_is_upval = upval_or_local_or_fetch(left.ex, func)
          new_left.suffix_reg, new_left.suffix_is_const = const_or_local_or_fetch(left.suffix, func)
          lefts[i] = new_left
        else
          error("Attempted to assign to "..left.node_type)
        end
      end

      local function generate_settabup_or_settable(left, lhs_expr, right_reg)
        local position = ast.get_main_position(lhs_expr)
        func.instructions[#func.instructions+1] = {
          op = left.ex_is_upval and opcodes.settabup or opcodes.settable,
          a = left.ex_reg, b = left.suffix_reg, c = right_reg,
          line = position and position.line, column = position and position.column,
        }
      end

      local function generate_setupval(left, lhs_expr, right_reg)
        func.instructions[#func.instructions+1] = {
          op = opcodes.setupval, a = right_reg, b = left.upval_idx, -- up(b) := r(a)
          line = lhs_expr.line, column = lhs_expr.column,
        }
      end

      local function assign_from_temps(temp_regs, num_lhs, move_last_local)
        for i = num_lhs, 1, -1 do
          local left = lefts[i]
          local right_reg = temp_regs[num_lhs - i + 1]
          if left.type == "index" then
            generate_settabup_or_settable(left, stat.lhs[i], right_reg)
          elseif left.type == "local" then
            if move_last_local or i ~= num_lhs then
              generate_move(left.reg, right_reg, stat.lhs[i], func)
            end
          elseif left.type == "upval" then
            generate_setupval(left, stat.lhs[i], right_reg)
          else
            assert(false, "Impossible left type "..left.type)
          end
        end
      end

      -- if #rhs >= #lhs then
      --   1) generate rhs into temporaries, up to second last left hand side
      --   2) generate next expression directly into most right left hand side
      --   3) generate the rest of the right hand side with 0 results
      --   4) assign from temps to lhs right to left
      -- if #rhs < #lhs then
      --   1) generate rhs into temporaries.
      --      most right reg may not be a temporary if most right lhs is a local ref
      --   2) assign from temps to lhs right to left

      local num_lhs = #stat.lhs
      local num_rhs = #stat.rhs
      local temp_regs = {}
      if num_rhs >= num_lhs then
        -- 1) generate rhs into temporaries, up to second last left hand side
        local exp_list = {}
        for i = 1, num_lhs - 1 do
          temp_regs[num_lhs - 1 - i + 1] = create_temp_reg(func, get_top(func) + i)
          exp_list[i] = stat.rhs[i]
        end
        generate_exp_list(exp_list, num_lhs - 1, func, temp_regs)

        -- 2) generate next expression directly into most right left hand side
        local last_left = lefts[num_lhs]
        local last_expr = stat.rhs[num_lhs]
        if last_left.type == "index" then
          local reg, is_const = const_or_local_or_fetch(last_expr, func)
          generate_settabup_or_settable(last_left, stat.lhs[#stat.lhs], reg)
          if not is_const then release_temp_reg(reg, func) end
        elseif last_left.type == "local" then
          generate_expr(last_expr, 1, func, {last_left.reg})
        elseif last_left.type == "upval" then
          local reg = local_or_fetch(last_expr, func)
          generate_setupval(last_left, stat.lhs[#stat.lhs], reg)
          release_temp_reg(reg, func)
        else
          assert(false, "Impossible left type "..last_left.type)
        end

        -- 3) generate the rest of the right hand side with 0 results
        for i = num_lhs + 1, num_rhs do
          generate_expr(stat.rhs[i], 0, func)
        end

        -- 4) assign from temps to lhs right to left
        assign_from_temps(temp_regs, num_lhs - 1, true)
      else
        -- 1) generate rhs into temporaries.
        --    most right reg may not be a temporary if most right lhs is a local ref
        for i = 1, num_lhs - 1 do
          temp_regs[num_lhs - i + 1] = create_temp_reg(func, get_top(func) + i)
        end
        if lefts[num_lhs].type == "local" then
          temp_regs[1] = lefts[num_lhs].reg
        else
          temp_regs[1] = create_temp_reg(func, get_top(func) + num_lhs)
        end
        generate_exp_list(stat.rhs, num_lhs, func, temp_regs)

        -- 2) assign from temps to lhs right to left
        assign_from_temps(temp_regs, num_lhs, false)
      end

      -- release all temporary registers
      -- this can easily be optimized by just using release_down_to
      -- but doing it manually like this makes it clear what temps were used
      release_temp_regs(temp_regs, func)
      for i = num_lhs, 1, -1 do
        if lefts[i].type == "index" then
          if not lefts[i].suffix_is_const then
            release_temp_reg(lefts[i].suffix_reg, func)
          end
          if not lefts[i].ex_is_upval then
            release_temp_reg(lefts[i].ex_reg, func)
          end
        end
      end
      assert(get_top(func) == original_top, "Didn't release some temp regs")
    end,
    localfunc = function(stat,func)
      local func_reg = create_local_reg(stat.name.reference_def, func)
      local func_token = stat.func_def.function_token
      -- CLOSURE into that register
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = use_reg(func_reg, func), bx = stat.func_def.index,
        line = func_token and func_token.line, column = func_token and func_token.column,
      }
      eval_upval_indexes(stat, func)
    end,
    funcstat = function(stat,func)
      -- maybe these nodes should be removed from the ast at some point prior
      -- but for now this works very well
      generate_statement({
        node_type = "assignment",
        lhs = {stat.name},
        rhs = {
          {
            node_type = "func_proto",
            func_def = stat.func_def,
          },
        },
      }, func)
    end,
    dostat = generate_scope,
    ifstat = function(stat,func)
      local prev_failure_jumps
      local finish_jumps = {}
      for _,if_block in ipairs(stat.ifs) do
        -- generate a value and `test` it...
        prev_failure_jumps = test_expr_and_jump(if_block.condition, false, func)

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

        if prev_failure_jumps then
          jump_here(prev_failure_jumps, func)
        end
      end
      if stat.elseblock then
        generate_scope(stat.elseblock, func)
      else
        if finish_jumps[#finish_jumps] then
          func.instructions[#func.instructions] = nil
          finish_jumps[#finish_jumps] = nil
          if prev_failure_jumps then
            for _, jump in ipairs(prev_failure_jumps) do
              jump.sbx = jump.sbx - 1
            end
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
      generate_expr(stat,0,func)
    end,
    forlist = function(stat,func)
      local regs = {}
      local jump, jump_pc

      for i, name in ipairs{"(for generator)", "(for state)", "(for control)"} do
        local reg = create_temp_reg(func, get_top(func) + i)
        reg.name = name
        regs[3 - i + 1] = reg
      end
      generate_exp_list(stat.exp_list, 3, func, regs)

      -- jmp to tforcall
      jump = {
        op = opcodes.jmp, a = 0, sbx = nil,
        line = stat.do_token and stat.do_token.line,
        column = stat.do_token and stat.do_token.column,
      }
      func.instructions[#func.instructions+1] = jump
      jump_pc = #func.instructions

      local function pre_block()
        -- use regs for locals
        -- released by generate_scope
        for _, local_ref in ipairs(stat.name_list) do
          use_reg(create_local_reg(local_ref.reference_def, func), func)
        end
      end

      generate_scope(stat, func, pre_block)

      jump.sbx = #func.instructions - jump_pc
      func.instructions[#func.instructions+1] = {
        op = opcodes.tforcall, a = regs[3], c = #stat.name_list, -- a=func, c=num loop vars
        line = stat.for_token and stat.for_token.line,
        column = stat.for_token and stat.for_token.column,
      }
      func.instructions[#func.instructions+1] = {
        -- sbx: jump back to just start of body
        op = opcodes.tforloop, a = regs[1], sbx = jump_pc - (#func.instructions + 1),
        line = stat.for_token and stat.for_token.line,
        column = stat.for_token and stat.for_token.column,
      }

      release_temp_regs(regs, func)

      patch_breaks_to_jump_here(stat, func)
    end,
    fornum = function(stat,func)
      local regs = {}
      local function generate_into_reg(name, expr)
        local reg = create_temp_reg(func)
        reg.name = name
        regs[1] = reg
        generate_expr(expr, 1, func, regs)
        return reg
      end

      local index_reg = generate_into_reg("(for index)", stat.start)
      local limit_reg = generate_into_reg("(for limit)", stat.stop)
      local step_reg = generate_into_reg("(for step)", stat.step or {
        node_type = "number",
        value = 1,
        line = get_last_used_line(func),
        column = get_last_used_column(func),
      })

      local forprep_inst, forprep_pc

      local function pre_block()
        -- released by generate_scope
        use_reg(create_local_reg(stat.var.reference_def, func), func)

        forprep_inst = {
          op = opcodes.forprep, a = index_reg, sbx = nil,
          line = stat.do_token and stat.do_token.line,
          column = stat.do_token and stat.do_token.column,
        }
        func.instructions[#func.instructions+1] = forprep_inst
        forprep_pc = #func.instructions
      end

      generate_scope(stat, func, pre_block)

      forprep_inst.sbx = #func.instructions - forprep_pc
      func.instructions[#func.instructions+1] = {
        op = opcodes.forloop, a = index_reg, sbx = forprep_pc - (#func.instructions + 1),
        line = stat.for_token and stat.for_token.line,
        column = stat.for_token and stat.for_token.column,
      }

      release_temp_regs({step_reg, limit_reg, index_reg}, func)

      patch_breaks_to_jump_here(stat, func)
    end,
    whilestat = function(stat,func)
      local start_pc = #func.instructions
      local failure_jumps
      -- generate condition and test
      failure_jumps = test_expr_and_jump(stat.condition, false, func)
      -- generate body
      generate_scope(stat, func)
      -- jump back
      func.instructions[#func.instructions+1] = {
        op = opcodes.jmp, a = 0, sbx = start_pc - (#func.instructions + 1),
        line = stat.end_token and stat.end_token.line,
        column = stat.end_token and stat.end_token.column,
      }
      -- patch failure_jump to jump here
      if failure_jumps then
        jump_here(failure_jumps, func)
      end
      -- patch breaks to jump here as well
      patch_breaks_to_jump_here(stat, func)
    end,
    repeatstat = function(stat,func)
      local start_pc = #func.instructions
      -- generate body
      generate_scope(stat, func, nil, function()
        local lowest_captured_reg = get_lowest_captured_reg(stat, func)
        for _, jump in ipairs(test_expr_and_jump(stat.condition, false, func)) do
          -- jump back if it failed
          jump.sbx = start_pc - jump.pc
          jump.pc = nil

          if lowest_captured_reg then
            -- the +1 for `a` is handled after generating all code for this function
            jump.a = lowest_captured_reg
          end
        end
        patch_breaks_to_jump_here(stat, func)
      end)
    end,

    ---@param stat AstRetStat
    retstat = function(stat,func)
      local first_reg = 0 ---@type 0|table
      local temp_regs = {}
      local num_results = 0
      local is_tail_call = false

      if stat.exp_list and stat.exp_list[1] then
        if func.compiler_options
          and func.compiler_options.optimizations
          and func.compiler_options.optimizations.tail_calls
          and (not stat.exp_list[2])
          and (stat.exp_list[1].node_type == "call")
          and (not stat.exp_list[1].force_single_result)
        then
          first_reg = create_temp_reg(func)
          generate_call_node(stat.exp_list[1], -1, func, {[-1] = first_reg}, true)
          num_results = -1
          is_tail_call = true
        else
          -- not a tail call

          num_results = #stat.exp_list
          -- NOTE: this is an optimization, meaning it might be moved out of here
          local are_sequential_locals = true
          local first_local_reg
          for i, expr in ipairs(stat.exp_list) do
            if expr.node_type == "local_ref" then
              if i == 1 then
                first_local_reg = find_local(expr)
              elseif find_local(expr).index ~= first_local_reg.index + i - 1 then
                are_sequential_locals = false
                break
              end
            else
              are_sequential_locals = false
              break
            end
          end

          if are_sequential_locals then
            first_reg = first_local_reg
          else
            -- have to use temporaries and actually generate the expression list
            for i = 1, num_results do
              temp_regs[num_results - i + 1] = create_temp_reg(func, get_top(func) + i)
            end
            first_reg = temp_regs[num_results]
            if ast.is_vararg_node(stat.exp_list[num_results]) then
              num_results = -1
            end
            generate_exp_list(stat.exp_list, num_results, func, temp_regs)
          end
        end
      end

      func.instructions[#func.instructions+1] = {
        op = opcodes["return"], a = first_reg, b = num_results + 1,
        line = stat.return_token and stat.return_token.line,
        column = stat.return_token and stat.return_token.column,
      }
      release_temp_regs(temp_regs, func)
      if is_tail_call then
        release_temp_reg(first_reg, func)
      end
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
      for _, reg in ipairs(func.stack.registers) do
        -- except this condition
        if scopes_that_matter_lut[reg.scope]
          and reg.upval_capture_pc
          and reg.upval_capture_pc < stat.pc
          and (
            (not lowest_captured_reg)
            or reg.index < lowest_captured_reg
          ) then
            lowest_captured_reg = reg.index
        end
      end
      inst.a = (lowest_captured_reg or -1) + 1
      -- whilestat, fornum, forlist, repeatstat and loopstat set sbx
    end,

    empty = function(stat,func)
      -- empty statement
    end,

    inline_iife_retstat = function(stat,func)
      -- if stat.exp_list then
      --   generate_exp_list(
      --     stat.exp_list,
      --     stat.linked_inline_iife.in_reg,
      --     func,
      --     stat.linked_inline_iife.num_results
      --   )
      -- else
      --   generate_expr({
      --     node_type = "nil",
      --     line = stat.return_token and stat.return_token.line,
      --     column = stat.return_token and stat.return_token.column,
      --   },
      --     stat.linked_inline_iife.in_reg,
      --     func,
      --     stat.linked_inline_iife.num_results
      --   )
      -- end
      error("-- TODO: refactor me!")
    end,
    loopstat = function(stat,func)
      local start_pc = #func.instructions
      generate_scope(stat, func)
      if stat.do_jump_back then
        func.instructions[#func.instructions+1] = {
          op = opcodes.jmp, a = 0, sbx = start_pc - (#func.instructions + 1),
          line = stat.close_token and stat.close_token.line,
          column = stat.close_token and stat.close_token.column,
        }
      end
      patch_breaks_to_jump_here(stat, func)
    end
  }
  function generate_code(functiondef, compiler_options)
    local stack = create_stack()
    stack.max_stack_size = 2
    local func = {
      line_defined = functiondef.function_token and functiondef.function_token.line,
      column_defined = functiondef.function_token and functiondef.function_token.column,
      last_line_defined = functiondef.end_token and functiondef.end_token.line,
      last_column_defined = functiondef.end_token and functiondef.end_token.column,
      num_params = (#functiondef.params) + (functiondef.is_method and 1 or 0),
      is_vararg = functiondef.is_vararg,
      max_stack_size = nil,
      instructions = {},
      constants = {},
      inner_functions = {},
      upvals = {},
      source = functiondef.source,
      debug_registers = stack.completed_registers, -- cleaned up at the end
      ---temporary data during compilation
      stack = stack,
      constant_lut = {},
      nil_constant_idx = nil,
      nan_constant_idx = nil,
      level = 0,
      scope_levels = {},
      label_positions = {}, -- `pc` and `scope` labels are in, needed for backwards jmp `a` and `sbx`
      current_scope = nil, -- managed by generate_scope
      compiler_options = compiler_options,
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
          use_reg(create_local_reg(loc, func), func)
        end
      end
    end)

    -- TODO: temp until it can be determined if the end of the function is reachable
    do
      local position = functiondef.body.last
        and ast.get_main_position(functiondef.body.last)
      local line = get_last_used_line(func)
      if line and position and position.line > line then
        line = position.line
      end
      local column = get_last_used_column(func)
      if column and position and position.column > column then
        column = position.column
      end
      generate_statement({
        node_type = "retstat",
        return_token = functiondef.end_token or {
          node_type = "token",
          line = line,
          column = column,
        },
      }, func)
    end

    -- normalize register indexes
    for _, inst in ipairs(func.instructions) do
      for k, v in pairs(inst.op.params) do
        if v == opcode_util.param_types.register then
          local reduce = inst.op.reduce_if_not_zero[k]
          if reduce then
            if type(inst[k]) == "table" then
              inst[k] = inst[k].index + reduce
            end
          else
            if not inst.op.conditional[k]
              or type(inst[k]) == "table"
            then
              inst[k] = inst[k].index
            end
          end
        elseif v == opcode_util.param_types.register_or_constant then
          if type(inst[k]) == "table" then
            inst[k] = inst[k].index
          end
        end
      end
    end

    -- move max_stack_size
    func.max_stack_size = stack.max_stack_size

    -- debug_registers cleanup
    for _, reg in ipairs(func.debug_registers) do
      reg.level = nil
      reg.scope = nil
      reg.in_scope_at = nil
    end

    -- cleanup
    for _,func_proto in ipairs(functiondef.func_protos) do
      func_proto.index = nil
    end

    -- this is a bit of a hack to use scope_levels to get all scopes, but it works
    for scope in pairs(func.scope_levels) do
      for _, loc in ipairs(scope.locals) do
        loc.register = nil
      end
    end

    for _,upval in ipairs(func.upvals) do
      upval.index = nil
    end
    for _,upval in ipairs(functiondef.upvals) do
      upval.index = nil
    end

    func.stack = nil
    func.constant_lut = nil
    func.nil_constant_idx = nil
    func.nan_constant_idx = nil
    func.level = nil
    func.scope_levels = nil
    func.label_positions = nil
    -- func.current_scope = nil -- is already `nil` after generate_scope
    func.compiler_options = nil

    -- inner_functions
    for i, func_proto in ipairs(functiondef.func_protos) do
      func.inner_functions[i] = generate_code(func_proto)
    end

    return func
  end
end

return generate_code
