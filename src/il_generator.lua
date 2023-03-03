
local ast = require("ast_util")
local nodes = require("nodes")
local ill = require("indexed_linked_list")
local consts = require("constants")
local il = require("il_util")
local util = require("util")

---same as in parser
local prevent_assert = {prevent_assert = true}

---@type Options?
local current_options
local generate_expr
local generate_stat
local generate_il_func

local function get_last_used_position(func)
  return func.instructions.last and func.instructions.last.position
end

---@param expr AstLocalReference
---@param func ILFunction
local function find_local(expr, func)
  return assert(func.temp.local_reg_lut[expr.reference_def])
end

---@param expr AstUpvalReference
---@param func ILFunction
local function find_upval(expr, func)
  return assert(func.temp.upval_def_lut[expr.reference_def])
end

local function set_local_reg(local_ref, reg, func)
  func.temp.local_reg_lut[local_ref.reference_def] = reg
end

local function local_or_fetch(expr, func)
  if expr.node_type == "local_ref" then
    return find_local(expr, func)
  else
    -- TODO: can generate_expr actually result in `nil` here?
    return generate_expr(expr, func)--[[@as ILRegister]]
  end
end

local function const_or_local_or_fetch(expr, func)
  if ast.is_const_node(expr) then
    return ({
      ["number"] = function()
        return il.new_number(expr.value)
      end,
      ["string"] = function()
        return il.new_string(expr.value)
      end,
      ["boolean"] = function()
        return il.new_boolean(expr.value)
      end,
      ["nil"] = function()
        return il.new_nil()
      end,
    })[expr.node_type]()
  else
    return local_or_fetch(expr, func)
  end
end

---@generic T : ILInstruction
---@param func ILFunction
---@param inst T
---@return T
local function add_inst(func, inst)
  ill.append(func.instructions, inst)
  return inst
end

local function generate_expr_list(expr_list, func, num_results, regs, allow_ptrs)
  local num_expr = #expr_list
  if num_results > 0 and num_expr == 0 then
    -- it wants results but there are no expressions to generate, so just generate nil
    generate_expr(nodes.new_nil{
      position = get_last_used_position(func),
    }, func, num_results, regs)
    return
  end
  for i, expr in ipairs(expr_list) do
    if num_results ~= -1 and i > num_results then
      generate_expr(expr, func, 0)
    elseif i == num_expr then
      num_results = num_results == -1 and -1 or ((num_results - num_expr) + 1)
      if allow_ptrs and (num_results == 1 or num_results == -1 and not ast.is_vararg_node(expr)) then
        regs[#regs+1] = const_or_local_or_fetch(expr, func)
      else
        generate_expr(expr, func, num_results, regs)
      end
    else
      if allow_ptrs then
        regs[#regs+1] = const_or_local_or_fetch(expr, func)
      else
        generate_expr(expr, func, 1, regs)
      end
    end
  end
end

---@return ILLabel? @ the label the jumps are jumping to, or nil if `jumps` is empty
local function jump_here(jumps, func, label_position)
  if not jumps[1] then
    return
  end
  local label
  if func.instructions.last.inst_type == "label" then
    label = func.instructions.last
    if label.inst_group
      or not (label.position == label_position
        or (label.position and label_position
          and label.position.line == label_position.line
          and label.position.column == label_position.column
        )
      )
    then
      label = nil
    end
  end
  if not label then
    label = add_inst(func, il.new_label{position = label_position})
  end
  for _, jump in ipairs(jumps) do
    jump.label = label
  end
  return label
end

do
  local function make_generate_const_expr(right_ptr_constructor)
    return function(expr, func)
      local reg = il.new_reg()
      add_inst(func, il.new_move{
        position = expr,
        result_reg = reg,
        right_ptr = right_ptr_constructor(expr.value),
      })
      return reg
    end
  end

  local function create_result_regs(num_results, regs)
    local result_regs = {}
    if num_results == -1 then
      local reg = il.new_vararg_reg()
      result_regs[#result_regs+1] = reg
      regs[#regs+1] = reg
    else
      for i = 1, num_results do
        local reg = il.new_reg()
        result_regs[i] = reg
        regs[#regs+1] = reg
      end
    end
    return result_regs
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

  local exprs = {
    ["local_ref"] = function(expr, func)
      local reg = il.new_reg()
      add_inst(func, il.new_move{
        position = expr,
        result_reg = reg,
        right_ptr = find_local(expr, func),
      })
      return reg
    end,
    ["upval_ref"] = function(expr, func)
      local reg = il.new_reg()
      add_inst(func, il.new_get_upval{
        position = expr,
        result_reg = reg,
        upval = find_upval(expr, func),
      })
      return reg
    end,
    ["index"] = function(expr, func)
      local reg = il.new_reg()
      add_inst(func, il.new_get_table{
        position = ast.get_main_position(expr),
        result_reg = reg,
        table_reg = local_or_fetch(expr.ex, func),
        key_ptr = const_or_local_or_fetch(expr.suffix, func),
      })
      return reg
    end,
    ["unop"] = function(expr, func)
      local reg = il.new_reg()
      add_inst(func, il.new_unop{
        position = expr.op_token,
        result_reg = reg,
        op = expr.op,
        right_ptr = const_or_local_or_fetch(expr.ex, func),
      })
      return reg
    end,
    ["binop"] = function(expr, func)
      if expr.op == "and" or expr.op == "or" then
        local reg = generate_expr(expr.left, func)
        local jump = add_inst(func, il.new_test{
          condition_ptr = reg,
          position = expr.op_token,
          jump_if_true = expr.op == "or",
          label = prevent_assert,
        })
        -- should directly assign to `reg`, but the IL generator currently does not have this capability
        add_inst(func, il.new_move{
          position = expr.op_token,
          result_reg = reg,
          right_ptr = const_or_local_or_fetch(expr.right, func),
        })
        jump_here({jump}, func, expr.op_token)
        return reg
      else
        local reg = il.new_reg()
        add_inst(func, il.new_binop{
          position = expr.op_token,
          result_reg = reg,
          left_ptr = const_or_local_or_fetch(expr.left, func),
          op = expr.op,
          right_ptr = const_or_local_or_fetch(expr.right, func),
        })
        return reg
      end
    end,
    ---@param expr AstConcat
    ["concat"] = function(expr, func)
      local reg = il.new_reg()
      local right_ptrs = {}
      generate_expr_list(expr.exp_list, func, #expr.exp_list, right_ptrs, true)
      add_inst(func, il.new_concat{
        position = expr.op_tokens and expr.op_tokens[#expr.op_tokens],
        result_reg = reg,
        right_ptrs = right_ptrs,
      })
      return reg
    end,
    ["number"] = make_generate_const_expr(il.new_number),
    ["string"] = make_generate_const_expr(il.new_string),
    ["nil"] = function(expr, func, num_results, regs)
      -- this could be changed to not be a multiple result node
      for _ = 1, num_results do
        local reg = il.new_reg()
        add_inst(func, il.new_move{
          position = expr,
          result_reg = reg,
          right_ptr = il.new_nil(),
        })
        regs[#regs+1] = reg
      end
    end,
    ["boolean"] = make_generate_const_expr(il.new_boolean),
    ["vararg"] = function(expr, func, num_results, regs)
      -- TODO: vararg really is just a weird kind of move... so what if it was just a move?
      if expr.force_single_result then
        num_results = 1
        regs = {}
      end
      if num_results == 0 then
        return
      end
      add_inst(func, il.new_vararg{
        position = expr,
        result_regs = create_result_regs(num_results, regs),
      })
      if expr.force_single_result then
        return regs[1]
      end
    end,
    ["func_proto"] = function(expr, func)
      local reg = il.new_reg()
      add_inst(func, il.new_closure{
        position = expr.func_def.function_token,
        result_reg = reg,
        func = generate_il_func(expr.func_def, current_options, func),
      })
      return reg
    end,
    ["constructor"] = function(expr, func)
      -- TODO: option to make this behave just like regular Lua would in terms of assignment order [...]
      -- but if anybody currently relies on the normal behavior... Idk, that's just weird.
      -- but to preserve the fact that Phobos can compile regular Lua without any different behavior
      -- this should actually default to the normal, weird behavior
      local use_same_behavior_as_lua = true

      local table_reg = il.new_reg()
      local array_size = 0
      local hash_size = 0
      local new_table_inst = il.new_new_table{
        position = expr.open_token,
        result_reg = table_reg,
        -- TODO: the array and hash size should be evaluated differently
        array_size = prevent_assert--[[@as integer]], -- set later
        hash_size = prevent_assert--[[@as integer]], -- set later
      }
      add_inst(func, new_table_inst)

      local set_list_start_index = 1
      local right_ptrs = {}
      local instruction_before_set_list
      local function generate_set_list(position)
        ill.insert_after(
          use_same_behavior_as_lua
            and func.instructions.last
            or instruction_before_set_list,
          il.new_set_list{
            position = position or instruction_before_set_list.position,
            table_reg = table_reg,
            start_index = set_list_start_index,
            right_ptrs = right_ptrs,
          }
        )
        set_list_start_index = set_list_start_index + consts.fields_per_flush
        right_ptrs = {}
      end

      for i, field in ipairs(expr.fields) do
        if field.type == "list" then
          local value_ptr
          local is_last_field = i == #expr.fields
          if is_last_field and ast.is_vararg_node(field.value) then
            value_ptr = generate_expr(field.value, func, -1)
          else
            value_ptr = const_or_local_or_fetch(field.value, func)
          end
          array_size = array_size + 1
          instruction_before_set_list = func.instructions.last
          right_ptrs[array_size - set_list_start_index + 1] = value_ptr
          if is_last_field or (array_size % consts.fields_per_flush) == 0 then
            generate_set_list(expr.comma_tokens and expr.comma_tokens[i])
          end
        else
          hash_size = hash_size + 1
          add_inst(func, il.new_set_table{
            position = field.eq_token,
            table_reg = table_reg,
            key_ptr = const_or_local_or_fetch(field.key, func),
            right_ptr = const_or_local_or_fetch(field.value, func),
          })
        end
      end

      if right_ptrs[1] then
        generate_set_list()
      end

      new_table_inst.array_size = array_size
      new_table_inst.hash_size = hash_size

      return table_reg
    end,
    ["call"] = function(expr, func, num_results, regs)
      if expr.force_single_result then
        num_results = 1
        regs = {}
      end
      local func_reg
      local arg_ptrs = {}
      if expr.is_selfcall then
        func_reg = il.new_reg()
        local self_reg = local_or_fetch(expr.ex, func)
        arg_ptrs[1] = self_reg
        add_inst(func, il.new_get_table{
          position = expr.colon_token,
          result_reg = func_reg,
          table_reg = self_reg,
          key_ptr = const_or_local_or_fetch(expr.suffix),
        })
      else
        func_reg = generate_expr(expr.ex, func)
      end

      generate_expr_list(expr.args, func, -1, arg_ptrs, true)

      add_inst(func, il.new_call{
        position = get_position_for_call_instruction(expr),
        func_reg = func_reg,
        arg_ptrs = arg_ptrs,
        result_regs = create_result_regs(num_results, regs),
      })
      if expr.force_single_result then
        return regs[1]
      end
    end,
  }

  ---@param regs ILRegister[]|nil @ will be filled by this function
  function generate_expr(expr, func, num_results, regs)
    num_results = num_results or 1
    if ast.is_single_result_node(expr) then
      local reg = exprs[expr.node_type](expr, func)
      if num_results > 1 then
        assert(regs)
        regs[#regs+1] = reg
        exprs["nil"](nodes.new_nil{
          position = get_last_used_position(func),
        }, func, num_results - 1, regs)
      elseif regs then
        regs[#regs+1] = reg
      elseif num_results == 0 then
        -- do nothing
      else
        return reg
      end
    else
      if num_results == -1 and not ast.is_vararg_node(expr) then
        num_results = 0
      end
      if num_results > 1 then
        assert(regs)
      end
      regs = regs or {}
      exprs[expr.node_type](expr, func, num_results, regs)
      if num_results == 1 or num_results == -1 then
        return regs[#regs]
      end
    end
  end
end

local function add_scoping_for_scope_locals(scope, func)
  local regs = {}
  for i, local_def in ipairs(scope.locals) do
    regs[i] = func.temp.local_reg_lut[local_def]
  end
  if regs[1] then
    add_inst(func, il.new_scoping{
      position = get_last_used_position(func),
      regs = regs,
    })
  end
end

local function generate_scope(scope, func, pre_block, post_block)
  if pre_block then
    pre_block()
  end
  local stat = scope.body.first
  while stat do
    generate_stat(stat, func)
    stat = stat.next
  end
  if post_block then
    post_block()
  end
  -- must keep all all locals until the end of the block because the last usage of a local
  -- might be inside an inner loop scope at which point the local would get closed too early
  -- (or even a manual loop using gotos would cause the same problem)
  add_scoping_for_scope_locals(scope, func)
end

do
  local function generate_test(condition, func, jump_if_true)
    local test = add_inst(func, il.new_test{
      position = ast.get_main_position(condition),
      condition_ptr = const_or_local_or_fetch(condition, func),
      jump_if_true = jump_if_true,
      label = prevent_assert,
    })
    return test
  end

  ---@return ILLabel? @ the label the jumps are jumping to, or nil if the loop's `linked_breaks` is empty
  local function breaks_jump_here(loop, func, label_position)
    if not loop.linked_breaks then
      return
    end
    local jumps = {}
    for i, breakstat in ipairs(loop.linked_breaks) do
      jumps[i] = func.temp.break_jump_lut[breakstat]
    end
    return jump_here(jumps, func, label_position)
  end

  local stats = {
    ["empty"] = function(stat, func)
      -- do nothing
    end,
    ["ifstat"] = function(stat, func)
      local leave_jumps = {}
      local failure_jumps = {}
      for _, testblock in ipairs(stat.ifs) do
        jump_here(failure_jumps, func, testblock.if_token)
        failure_jumps[1] = generate_test(testblock.condition, func, false)
        generate_scope(testblock, func)
        leave_jumps[#leave_jumps+1] = add_inst(func, il.new_jump{
          position = get_last_used_position(func),
          label = prevent_assert,
        })
      end
      jump_here(failure_jumps, func, stat.elseblock and stat.elseblock.else_token or stat.end_token)
      if stat.elseblock then
        generate_scope(stat.elseblock, func)
      end
      jump_here(leave_jumps, func, stat.end_token)
    end,
    -- ["testblock"] = function(stat, func)
    -- end,
    -- ["elseblock"] = function(stat, func)
    -- end,
    ["whilestat"] = function(stat, func)
      local start_label = add_inst(func, il.new_label{position = stat.do_token})
      local failure_jump = generate_test(stat.condition, func, false)
      generate_scope(stat, func)
      add_inst(func, il.new_jump{
        position = stat.end_token,
        label = start_label,
      })
      jump_here({failure_jump}, func, stat.end_token)
      breaks_jump_here(stat, func, stat.end_token)
    end,
    ["dostat"] = function(stat, func)
      generate_scope(stat, func)
    end,
    ["fornum"] = function(stat, func)
      local index_reg = generate_expr(stat.start, func)
      local limit_reg = generate_expr(stat.stop, func)
      local step_reg = generate_expr(stat.step or nodes.new_number{
        value = 1,
        position = get_last_used_position(func)
      }, func)
      index_reg.name = "(for index)"
      limit_reg.name = "(for limit)"
      step_reg.name = "(for step)"

      -- start of forprep group

      -- convert index, limit and step to numbers
      local forprep_group_start = add_inst(func, il.new_to_number{
        position = stat.for_token,
        result_reg = index_reg,
        right_ptr = index_reg
      })
      add_inst(func, il.new_to_number{
        position = stat.for_token,
        result_reg = limit_reg,
        right_ptr = limit_reg
      })
      add_inst(func, il.new_to_number{
        position = stat.for_token,
        result_reg = step_reg,
        right_ptr = step_reg
      })

      -- subtract step from index once to match the forprep instruction
      add_inst(func, il.new_binop{
        position = stat.for_token,
        raw = true,
        result_reg = index_reg,
        left_ptr = index_reg,
        op = "-",
        right_ptr = step_reg,
      })

      -- jump to the forloop instruction which is past the body of the loop
      local prep_jump_forward = add_inst(func, il.new_jump{
        position = stat.for_token,
        label = prevent_assert,
      })

      -- stop of forprep group

      il.new_forprep_group{
        position = stat.for_token,
        start = forprep_group_start,
        stop = prep_jump_forward,
        index_reg = index_reg,
        limit_reg = limit_reg,
        step_reg = step_reg,
        loop_jump = prep_jump_forward,
      }

      -- the target label for forloop. it can be anywhere because it's simply sbx, unrelated to forprep
      local start_label = add_inst(func, il.new_label{position = stat.for_token})

      -- goes into scope after the loop back label but before the body of the loop
      local local_reg = il.new_reg(stat.var.name)
      set_local_reg(stat.var, local_reg, func)
      add_inst(func, il.new_scoping{
        position = stat.for_token,
        regs = {local_reg},
      })

      -- body of the loop
      generate_scope(stat, func)

      -- the local goes out of scope here, so upvalues must be closed, but the forloop instruction reuses the
      -- register for the next iteration
      add_inst(func, il.new_close_up{
        position = stat.do_token,
        regs = {local_reg},
      })

      -- target label for forprep. just like for forloop, this can be anywhere, so not part of the group
      prep_jump_forward.label = add_inst(func, il.new_label{position = stat.for_token})

      local leave_jumps = {}

      -- start of forloop group

      -- increment index using a temporary register to match the internal implementation of forloop
      -- it only writes the new value of the index to the index register if it continues looping
      local incremented_index_reg = il.new_reg()
      local forloop_group_start = add_inst(func, il.new_binop{
        position = stat.do_token,
        result_reg = incremented_index_reg,
        left_ptr = index_reg,
        op = "+",
        right_ptr = step_reg,
        raw = true,
      })

      -- test `step > 0`
      local temp_reg = il.new_reg()
      add_inst(func, il.new_binop{
        position = stat.for_token,
        result_reg = temp_reg,
        left_ptr = step_reg,
        op = ">",
        right_ptr = il.new_number(0),
        raw = true,
      })
      local step_comp_jump = add_inst(func, il.new_test{
        position = stat.for_token,
        condition_ptr = temp_reg,
        jump_if_true = true,
        label = prevent_assert,
      })

      -- this is the branch: `if step <= 0 then`
      -- and this does `if index < limit then break end`
      temp_reg = il.new_reg()
      add_inst(func, il.new_binop{
        position = stat.for_token,
        result_reg = temp_reg,
        left_ptr = incremented_index_reg,
        op = "<",
        right_ptr = limit_reg,
        raw = true,
      })
      leave_jumps[#leave_jumps+1] = add_inst(func, il.new_test{
        position = stat.for_token,
        condition_ptr = temp_reg,
        jump_if_true = true,
        label = prevent_assert,
      })
      -- jump past the other branch for the initial `step > 0` test
      local jump_to_block = add_inst(func, il.new_jump{
        position = stat.for_token,
        label = prevent_assert,
      })

      -- set jump target for the second branch
      jump_here({step_comp_jump}, func, stat.for_token)
      -- this is the branch: `if step > 0 then`
      -- and this does `if index > limit then break end`
      temp_reg = il.new_reg()
      add_inst(func, il.new_binop{
        position = stat.for_token,
        result_reg = temp_reg,
        left_ptr = incremented_index_reg,
        op = ">",
        right_ptr = limit_reg,
        raw = true,
      })
      leave_jumps[#leave_jumps+1] = add_inst(func, il.new_test{
        position = stat.for_token,
        condition_ptr = temp_reg,
        jump_if_true = true,
        label = prevent_assert,
      })

      -- set jump target for the first branch, since it skips the second branch on success (and breaks/leaves on failure)
      jump_here({jump_to_block}, func, stat.for_token)
      -- `index = incremented_index`
      add_inst(func, il.new_move{
        position = stat.eq_token,
        result_reg = index_reg,
        right_ptr = incremented_index_reg,
      })
      -- `local_var = incremented_index`
      add_inst(func, il.new_move{
        position = stat.eq_token,
        result_reg = local_reg,
        right_ptr = incremented_index_reg,
      })
      -- jump back up, next loop iteration
      local forloop_group_loop_jump = add_inst(func, il.new_jump{
        position = stat.do_token,
        label = start_label,
      })

      -- set jump target for leave and break jumps
      local forloop_group_stop = jump_here(leave_jumps, func, stat.end_token)
      ---@cast forloop_group_stop -nil

      -- stop of forloop group

      il.new_forloop_group{
        position = stat.for_token,
        start = forloop_group_start,
        stop = forloop_group_stop,
        index_reg = index_reg,
        limit_reg = limit_reg,
        step_reg = step_reg,
        local_reg = local_reg,
        loop_jump = forloop_group_loop_jump,
      }

      breaks_jump_here(stat, func, stat.end_token)

      -- prevent internal regs from going out of scope too early
      add_inst(func, il.new_scoping{
        position = stat.end_token,
        regs = {
          index_reg,
          limit_reg,
          step_reg,
        },
      })
    end,
    ["forlist"] = function(stat, func)
      local regs = {}
      generate_expr_list(stat.exp_list, func, 3, regs)
      local generator_reg = regs[1]
      local state_reg = regs[2]
      local control_reg = regs[3]
      generator_reg.name = "(for generator)"
      state_reg.name = "(for state)"
      control_reg.name = "(for control)"

      local start_label = add_inst(func, il.new_label{position = stat.do_token})

      local local_regs = {}
      for i, local_ref in ipairs(stat.name_list) do
        local_regs[i] = il.new_reg(local_ref.name)
        set_local_reg(local_ref, local_regs[i], func)
      end

      add_inst(func, il.new_call{
        position = stat.in_token,
        result_regs = local_regs,
        func_reg = generator_reg,
        arg_ptrs = {state_reg, control_reg},
      })

      local temp_reg = il.new_reg()
      add_inst(func, il.new_binop{
        position = stat.in_token,
        result_reg = temp_reg,
        left_ptr = local_regs[1],
        op = "==",
        right_ptr = il.new_nil(),
      })
      local leave_jump = add_inst(func, il.new_test{
        position = stat.in_token,
        condition_ptr = temp_reg,
        jump_if_true = true,
        label = prevent_assert,
      })

      add_inst(func, il.new_move{
        position = stat.in_token,
        result_reg = control_reg,
        right_ptr = local_regs[1],
      })

      generate_scope(stat, func)

      add_inst(func, il.new_jump{
        position = stat.end_token,
        label = start_label,
      })

      -- prevent internal regs from going out of scope too early
      add_inst(func, il.new_scoping{
        position = stat.end_token,
        regs = {generator_reg, state_reg, control_reg},
      })

      jump_here({leave_jump}, func, stat.end_token)
      breaks_jump_here(stat, func, stat.end_token)
    end,
    ["repeatstat"] = function(stat, func)
      local start_label = add_inst(func, il.new_label{position = stat.repeat_token})
      generate_scope(stat, func, nil, function()
        -- the condition is in the post_block callback in order for
        -- all locals in the scope to stay alive until past the condition
        --
        -- we just want to continue without jumping if it's not successful
        -- so failure has to jump back up
        local failure_jump = generate_test(stat.condition, func, false)
        failure_jump.label = start_label
      end)
      breaks_jump_here(stat, func, get_last_used_position(func))
    end,
    ["funcstat"] = function(stat, func)
      generate_stat(nodes.new_assignment{
        lhs = {stat.name},
        rhs = {
          nodes.new_func_proto{
            func_def = stat.func_def,
          },
        },
      }, func)
    end,
    ["localstat"] = function(stat, func)
      local regs = {}
      generate_expr_list(stat.rhs or {nodes.new_nil{
        position = stat.lhs[1],
      }}, func, #stat.lhs, regs)
      for i, local_ref in ipairs(stat.lhs) do
        regs[i].name = local_ref.name
        set_local_reg(local_ref, regs[i], func)
      end
    end,
    ["localfunc"] = function(stat, func)
      local reg = il.new_reg(stat.name.name)
      set_local_reg(stat.name, reg, func)
      add_inst(func, il.new_closure{
        position = stat.func_def.function_token,
        result_reg = reg,
        func = generate_il_func(stat.func_def, current_options, func),
      })
    end,
    ["label"] = function(stat, func)
      local label_inst = add_inst(func, il.new_label{
        position = stat.name_token,
        name = stat.name,
      })
      func.temp.label_inst_lut[stat] = label_inst
      for _, go in ipairs(stat.linked_gotos) do
        local goto_inst = func.temp.goto_inst_lut[go]
        if goto_inst then
          goto_inst.label = label_inst
        end
      end
    end,
    ["retstat"] = function(stat, func)
      local ptrs = {}
      generate_expr_list(stat.exp_list, func, -1, ptrs, true)
      add_inst(func, il.new_ret{
        position = stat.return_token,
        ptrs = ptrs,
      })
    end,
    ["breakstat"] = function(stat, func)
      local inst = add_inst(func, il.new_jump{
        position = stat.break_token,
        label = prevent_assert,
      })
      func.temp.break_jump_lut[stat] = inst
    end,
    ["gotostat"] = function(stat, func)
      local jump = add_inst(func, il.new_jump{
        position = stat.goto_token,
        label = prevent_assert,
      })
      func.temp.goto_inst_lut[stat] = jump
      local label_inst = func.temp.label_inst_lut[stat.linked_label]
      if label_inst then
        jump.label = label_inst
      end
    end,
    ["call"] = function(stat, func)
      generate_expr(stat, func, 0)
    end,
    ["assignment"] = function(stat, func)
      local lefts = {}
      for i,left in ipairs(stat.lhs) do
        if left.node_type == "local_ref" then
          lefts[i] = {
            type = "local",
            reg = find_local(left, func),
          }
        elseif left.node_type == "upval_ref" then
          lefts[i] = {
            type = "upval",
          }
        elseif left.node_type == "index" then
          lefts[i] = {
            type = "index",
            table_reg = local_or_fetch(left.ex, func),
            key_ptr = const_or_local_or_fetch(left.suffix, func),
          }
        else
          error("Attempted to assign to "..left.node_type)
        end
      end

      local function generate_settable(left, lhs_expr, right_reg)
        add_inst(func, il.new_set_table{
          position = ast.get_main_position(lhs_expr),
          table_reg = left.table_reg,
          key_ptr = left.key_ptr,
          right_ptr = right_reg,
        })
      end

      local function generate_setupval(left, lhs_expr, right_ptr)
        add_inst(func, il.new_set_upval{
          position = lhs_expr,
          upval = find_upval(lhs_expr, func),
          right_ptr = right_ptr,
        })
      end

      local function assign_from_temps(temp_regs, num_lhs, move_last_local)
        for i = num_lhs, 1, -1 do
          local left = lefts[i]
          local right_reg = temp_regs[i]
          if left.type == "index" then
            generate_settable(left, stat.lhs[i], right_reg)
          elseif left.type == "local" then
            if move_last_local or i ~= num_lhs then
              add_inst(func, il.new_move{
                position = stat.lhs[i],
                result_reg = left.reg,
                right_ptr = right_reg,
              })
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
      if num_rhs >= num_lhs then
        -- 1) generate rhs into temporaries, up to second last left hand side
        local temp_regs = {}
        local exp_list = {}
        for i = 1, num_lhs - 1 do
          exp_list[i] = stat.rhs[i]
        end
        generate_expr_list(exp_list, func, num_lhs - 1, temp_regs)

        -- 2) generate next expression directly into most right left hand side
        local last_left = lefts[num_lhs]
        local last_expr = stat.rhs[num_lhs]
        if last_left.type == "index" then
          local reg = const_or_local_or_fetch(last_expr, func)
          generate_settable(last_left, stat.lhs[#stat.lhs], reg)
        elseif last_left.type == "local" then
          add_inst(func, il.new_move{
            position = ast.get_main_position(last_expr),
            result_reg = last_left.reg,
            right_ptr = const_or_local_or_fetch(last_expr, func),
          })
        elseif last_left.type == "upval" then
          local ptr = const_or_local_or_fetch(last_expr, func)
          generate_setupval(last_left, stat.lhs[#stat.lhs], ptr)
        else
          assert(false, "Impossible left type "..last_left.type)
        end

        -- 3) generate the rest of the right hand side with 0 results
        for i = num_lhs + 1, num_rhs do
          generate_expr(stat.rhs[i], func, 0)
        end

        -- 4) assign from temps to lhs right to left
        assign_from_temps(temp_regs, num_lhs - 1, true)
      else
        -- 1) generate rhs into temporaries.
        --    most right reg may not be a temporary if most right lhs is a local ref
        local temp_regs = {}
        generate_expr_list(stat.rhs, func, num_lhs, temp_regs)

        -- 2) assign from temps to lhs right to left
        assign_from_temps(temp_regs, num_lhs, true) -- TODO: change last one to directly assign to local somehow
      end
    end,
    ["loopstat"] = function(stat, func)
      local start_label
      if stat.do_jump_back then
        start_label = add_inst(func, il.new_label{position = stat.open_token})
      end
      generate_scope(stat, func)
      if stat.do_jump_back then
        add_inst(func, il.new_jump{
          position = stat.close_token,
          label = start_label,
        })
      end
      breaks_jump_here(stat, func, stat.close_token)
    end,
  }

  function generate_stat(stat, func)
    stats[stat.node_type](stat, func)
  end
end

---@param functiondef AstFunctionDef
---@param options Options?
---@param parent_func ILFunction?
---@return ILFunction
function generate_il_func(functiondef, options, parent_func)
  current_options = options
  if options and options.use_int32 then
    util.debug_abort("Intermediate language does not support compilation as int32.")
  end
  if not functiondef.is_main then
    util.debug_assert(parent_func, "`parent_func` can only be omitted if the given functiondef is a main chunk")
  end

  ---@type ILFunction
  local func = {
    parent_func = parent_func,
    inner_functions = {},
    instructions = ill.new(true),
    temp = {
      local_reg_lut = {},
      upval_def_lut = {},
      break_jump_lut = {},
      label_inst_lut = {},
      goto_inst_lut = {},
    },
    upvals = {},
    param_regs = {},
    is_vararg = functiondef.is_vararg,
    source = functiondef.source,
    defined_position = functiondef.function_token,
    last_defined_position = functiondef.end_token,

    has_blocks = false,
    has_start_stop_insts = false,
    has_reg_liveliness = false,
    has_types = false,
    has_reg_usage = false,
    is_compiling = false,
  }

  if parent_func then
    parent_func.inner_functions[#parent_func.inner_functions+1] = func
  end

  for i, upval in ipairs(functiondef.upvals) do
    local il_upval = {
      name = upval.name,
      parent_type = nil, -- set below
      child_upvals = {},
    }
    func.upvals[i] = il_upval
    func.temp.upval_def_lut[upval] = il_upval
    if upval.parent_def.def_type == "upval" then
      ---@cast parent_func -?
      il_upval.parent_type = "upval"
      local parent_upval = parent_func.temp.upval_def_lut[upval.parent_def]
      func.upvals[i].parent_upval = parent_upval
      parent_upval.child_upvals[#parent_upval.child_upvals+1] = func.upvals[i]
    elseif upval.parent_def.scope.node_type == "env_scope" then
      -- this will actually only ever happen for the main chunk, but I like this test better
      -- I think it is more explicit and descriptive
      il_upval.parent_type = "env"
    else -- upval.parent_def.def_type == "local" (and it is not the _ENV "local")
      ---@cast parent_func -?
      il_upval.parent_type = "local"
      local reg_in_parent_func = parent_func.temp.local_reg_lut[upval.parent_def]
      func.upvals[i].reg_in_parent_func = reg_in_parent_func
      reg_in_parent_func.captured_as_upval = true
    end
  end

  -- special handling for methods because self is not in the params list
  if functiondef.is_method then
    local reg = il.new_reg("self")
    reg.is_parameter = true
    func.param_regs[1] = reg
    func.temp.local_reg_lut[functiondef.locals[1]] = func.param_regs[1]
  end
  local param_offset = functiondef.is_method and 1 or 0
  for i, param in ipairs(functiondef.params) do
    local reg = il.new_reg(param.name)
    reg.is_parameter = true
    func.param_regs[i + param_offset] = reg
    set_local_reg(param, func.param_regs[i + param_offset], func)
  end

  -- all parameters have to be in scope from the beginning because they are automatically set by Lua
  if func.param_regs[1] then
    add_inst(func, il.new_scoping{
      position = not functiondef.is_main and functiondef.function_token or nil,
      regs = func.param_regs, -- using a reference to the same table!
    })
  end

  generate_scope(functiondef, func)

  -- parameters also have to stay alive for the entire function in case they are captured a an upvalue
  if func.param_regs[1] then
    add_inst(func, il.new_scoping{
      position = not functiondef.is_main and functiondef.function_token or nil,
      regs = func.param_regs, -- using a reference to the same table!
    })
  end

  -- self does have a local so it gets included in the scope's SCOPING instruction

  -- as per usual, an extra return for good measure
  add_inst(func, il.new_ret{position = functiondef.end_token or get_last_used_position(func)})

  func.temp = nil
  return func
end

return generate_il_func
