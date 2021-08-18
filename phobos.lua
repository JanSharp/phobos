
local invert = require("invert")
local phobos_consts = require("constants")
local util = require("util")
----------------------------------------------------------------------
local generate_code
do
  local opcodes = require("opcodes")
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
  local function release_reg(func, reg)
    if reg ~= func.next_reg - 1 then
      error("Attempted to release register "..reg.." when top was "..func.next_reg)
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
  local function release_down_to(func, reg)
    if reg == func.next_reg then
      return
    end

    if reg > func.next_reg then
      error("Attempted to release registers down to "..reg.." when top was "..func.next_reg)
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
  local function create_live_reg(func, reg, name)
    local live = {
      reg = reg,
      name = name,
    }
    func.live_regs[#func.live_regs+1] = live
    return live
  end
  local function get_top(func)
    return func.next_reg - 1
  end
  local function reg_is_top(func, reg)
    return reg >= get_top(func)
  end

  local generate_expr_code
  local vararg_node_types = invert{"vararg","call","selfcall"}
  local function generate_expr(expr,in_reg,func,num_results)
    generate_expr_code[expr.node_type](expr,in_reg,func,num_results)
    if num_results > 1 and not (vararg_node_types[expr.node_type] or expr.node_type == "nil") then
      generate_expr({
        node_type = "nil",
        line = expr.line,
        column = expr.column,
      }, in_reg + 1, func, num_results - 1)
    end
  end

  local function generate_exp_list(exp_list,in_reg,func,num_results)
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
        end
        generate_expr(expr, get_expr_in_reg(), func, expr_num_results)
      elseif i > num_exp then
        break -- TODO: no error?
      else
        generate_expr(expr, get_expr_in_reg(), func, 1)
      end
    end
    if used_temp then
      -- move from base+i to in_reg+i-1
      local line = func.instructions[#func.instructions].line
      local column = func.instructions[#func.instructions].column
      for i = 1, num_results do
        func.instructions[#func.instructions+1] = {
          -- since original_top is the original top live reg, the temporary regs
          -- are actually starting 1 past it, meaning it must not have the -1
          -- unlike in_reg
          op = opcodes.move, a = in_reg + i - 1, b = original_top + i,
          line = line,
          column = column,
        }
      end
      release_down_to(func, original_top)
    end
  end

  local function add_constant(value,func)
    for i,const in ipairs(func.constants) do
      if value == const then
        return i - 1
      end
    end
    local i = #func.constants
    func.constants[i+1] = value
    return i
  end
  local function generate_const_code(expr,in_reg,func)
    local k = add_constant(expr.value,func)
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
  local bin_opcodes = {
    ["+"] = opcodes.add,
    ["-"] = opcodes.sub,
    ["*"] = opcodes.mul,
    ["/"] = opcodes.div,
    ["%"] = opcodes.mod,
    ["^"] = opcodes.pow,
  }
  local un_opcodes = {
    ["-"] = opcodes.unm,
    ["#"] = opcodes.len,
    ["not"] = opcodes["not"],
  }
  local function find_local(ref,func)
    -- find it in live_regs and use that...
    local live_regs = func.live_regs
    for i = #live_regs,1,-1 do
      local lr = live_regs[i]
      if (not lr.stop_at) and lr.name == ref.name then
        return lr.reg
      end
    end
  end
  ---@param upval_name string
  ---@param func GeneratedFunc
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
      return find_local(expr,func)
    else
      use_reg(func, in_reg)
      generate_expr(expr,in_reg,func,1)
      return in_reg
    end
  end
  local function is_falsy(node)
    return node.node_type == "nil" or (node.node_type == "boolean" and node.node_type.value == false)
  end
  local const_node_types = invert{"boolean","nil","string","number"}
  local logical_binops = invert{">",">=","==","~=","<=","<"}
  local function const_or_local_or_fetch(expr,in_reg,func)
    if const_node_types[expr.node_type] then
      return bit32.bor(add_constant(expr.value,func),0x100)
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
  generate_expr_code = {
    local_ref = function(expr,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.move, a = in_reg, b = find_local(expr.name,func),
        line = expr.line, column = expr.column,
      }
    end,
    ---@param expr AstUpvalReference
    ---@param in_reg integer
    ---@param func GeneratedFunc
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
      local left_reg = const_or_local_or_fetch(expr.left,in_reg,func)
      -- if left_reg used in_reg, eval next expression into next_reg if needed
      local temp_reg = left_reg == in_reg and peek_next_reg(func) or in_reg
      local right_reg = const_or_local_or_fetch(expr.right,temp_reg,func)

      func.instructions[#func.instructions+1] = {
        op = bin_opcodes[expr.op], a = in_reg, b = left_reg, c = right_reg,
        line = expr.op_token and expr.op_token.line, -- TODO: probably should just use expr.line/column
        column = expr.op_token and expr.op_token.column,
      }
      -- release temporaries if they were used
      release_down_to(func, in_reg)
    end,
    unop = function(expr,in_reg,func)
      -- if expr.ex is a local use that directly,
      -- else fetch into in_reg
      local scr_reg = local_or_fetch(expr.ex,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = un_opcodes[expr.op], a = in_reg, b = scr_reg,
        line = expr.line, column = expr.column,
      }
    end,
    concat = function(expr,in_reg,func)
      local temp_reg = in_reg
      local used_temp
      if not reg_is_top(func, temp_reg) then
        temp_reg = next_reg(func)
        used_temp = true
      end
      local num_exp = #expr.exp_list
      generate_exp_list(expr.exp_list,temp_reg,func,num_exp)
      func.instructions[#func.instructions+1] = {
        op = opcodes.concat, a = in_reg, b = temp_reg, c = temp_reg + num_exp - 1,
        line = expr.line, column = expr.column,
      }
      if used_temp then
        release_reg(func,temp_reg) -- TODO: once i checked out generate_exp_list make sure this is correct
      end
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
      if func.instructions[#func.instructions] and func.instructions[#func.instructions].op == opcodes.loadnil then
        func.instructions[#func.instructions].b = func.instructions[#func.instructions].b + num_results
      else
        func.instructions[#func.instructions+1] = {
          op = opcodes.loadnil, a = in_reg, b = num_results - 1, -- from a to a + b
          line = expr.line, column = expr.column,
        }
      end
    end,
    ---@param expr AstConstructor
    constructor = function(expr,in_reg,func)
      local new_tab = {
        op = opcodes.newtable, a = in_reg, b = nil, c = nil, -- set later
        line = expr.line, column = expr.column,
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
        local src_position = (field_index == 0 and expr.close_paren_token)
        -- if `field_index == 0` and `expr.close_paren_token == nil` this will also be `nil` because there is no `0` field
          or expr.comma_tokens[field_index]
          or func.instructions[#func.instructions] -- fallback in both cases
        func.instructions[#func.instructions+1] = {
          op = opcodes.setlist, a = in_reg, b = count, c = flush_count,
          line = src_position.line,
          column = src_position.column,
        }
        release_down_to(func, initial_top)
      end

      for i,field in ipairs(expr.fields) do
        if field.type == "list" then
          ---@narrow field AstListField
          -- if list accumulate values
          local count = 1
          if i == fields_count and vararg_node_types[field.value.node_type] then
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
            line = field.eq_token and field.eq_token.line, -- TODO: probably should just use expr.line/column
            column = field.eq_token and field.eq_token.column,
          }

          release_down_to(func, original_top)
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
      -- TODO: set upval indexes for in_stack upvals
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = in_reg, bx = expr.ref.index,
        line = expr.line, column = expr.column,
      }
    end,
    vararg = function(expr,in_reg,func,num_results)
      func.instructions[#func.instructions+1] = {
        op = opcodes.vararg, a = in_reg, b = (num_results or 1)+1,
        line = expr.line, column = expr.column,
      }
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
      if num_args > 0 and vararg_node_types[expr.args[num_args].node_type] then
        num_args = -1
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.call, a = func_reg, b = num_args+1, c = num_results + 1,
        line = expr.line, column = expr.column,
      }
      if used_temp then
        -- copy from func_reg+n to in_reg+n
        for i = 1, num_results do
          func.instructions[#func.instructions+1] = {
            op = opcodes.move, a = in_reg + i - 1, b = func_reg + i - 1,
            line = expr.line, column = expr.column,
          }
        end
      end
      release_down_to(func,original_top)
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
        line = expr.suffix.line or expr.line,
        column = expr.suffix.column or expr.column,
      }
      use_reg(func, func_reg + 1)
      -- TODO: the rest is copy paste from call
      generate_exp_list(expr.args,peek_next_reg(func),func,-1)
      local num_args = #expr.args
      if num_args > 0 and vararg_node_types[expr.args[num_args].node_type] then
        num_args = -1
      else
        num_args = num_args + 1 -- except this, because selfcall has 1 more arg, period
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.call, a = func_reg, b = num_args + 1, c = num_results + 1,
        -- and this is different
        -- TODO: change what the parser assigns to line/column
        line = expr.open_paren_token and expr.open_paren_token.line or expr.line,
        column = expr.open_paren_token and expr.open_paren_token.column or expr.column,
      }
      if used_temp then
        -- copy from func_reg+n to in_reg+n
        for i = 1, num_results do
          func.instructions[#func.instructions+1] = {
            op = opcodes.move, a = in_reg + i - 1, b = func_reg + i - 1,
            line = expr.line, column = expr.column,
          }
        end
      end
      release_down_to(func, original_top)
    end,
    index = function(expr,in_reg,func)
      local original_top = get_top(func)
      local temp_reg = in_reg
      local ex_reg,is_upval = upval_or_local_or_fetch(expr.ex,temp_reg,func)
      if (not is_upval) and ex_reg == in_reg then
        temp_reg = next_reg(func)
      end

      local suffix_reg = const_or_local_or_fetch(expr.suffix,temp_reg,func)

      func.instructions[#func.instructions+1] = {
        op = is_upval and opcodes.gettabup or opcodes.gettable,
        a = in_reg, b = ex_reg, c = suffix_reg,
        line = expr.line, column = expr.column,
      }
      release_down_to(func, original_top)
    end,
  }

  local function generate_test_code(condition)
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
      * -> test
    ]]
    if condition.node_type == "binop" and logical_binops[condition.op] then

    else

    end
    error()
  end

  local generate_statement_code
  generate_statement_code = {
    localstat = function(stat,func)
      -- allocate registers for LHS, eval expressions into them
      local new_live_regs = {}
      for i,ref in ipairs(stat.lhs) do
        local live = create_live_reg(func, get_top(func) + i, ref.name)
        live.start_at = #func.instructions + 1
        new_live_regs[i] = live
      end

      if stat.rhs then
        generate_exp_list(stat.rhs, new_live_regs[1].reg, func, #stat.lhs)
      else
        use_reg(func, new_live_regs[#stat.lhs].reg)
        generate_expr({
          node_type = "nil",
          line = stat.line,
          column = stat.column,
        }, new_live_regs[1].reg, func, #stat.lhs)
      end

      do return end -- TODO: figure out if it's really better to have them be life before the expression list is evaluated
      -- declare new registers to be "live" with locals after this
      local last_pc = #func.instructions
      for _,live in ipairs(new_live_regs) do
        live.start_at = last_pc + 1
      end
    end,
    assignment = function(stat,func)
      -- evaluate all expressions (assignment parent/key, values) into temporaries, left to right
      -- last expr in value list is for enough values to fill the list
      -- emit warning and drop extra values with no targets
      -- move/settable/settabup from temporary to target, right to left
      local top = func.next_reg
      local lefts = {}
      for i,left in ipairs(stat.lhs) do
        if left.node_type == "local" then
          lefts[i] = {
            type = "local",
            reg = find_local(left.ref,func),
          }
        elseif left.node_type == "upval" then
          lefts[i] = {
            type = "upval",
            upval = error()

          }
        elseif left.node_type == "index" then
          -- if index and parent not local/upval, fetch parent to temporary
          local new_left = {
            type = "index",
          }
          local temp_reg = next_reg(func)
          new_left.ex,new_left.ex_is_up = upval_or_local_or_fetch(left.ex,temp_reg,func)
          if not new_left.ex_is_up and new_left.ex == temp_reg then
            temp_reg = next_reg(func)
          end
          new_left.suffix = const_or_local_or_fetch(left.suffix,temp_reg,func)
          if new_left.suffix ~= temp_reg then
            release_reg(func,temp_reg)
          end
          lefts[i] = new_left
        else
          error("Attempted to assign to " .. left.node_type)
        end
      end
      local n_lefts = #lefts
      local first_right = func.next_reg
      local n_rights = #stat.rhs
      if vararg_node_types[stat.rhs[n_rights].node_type] then
        n_rights = n_lefts
      end
      generate_exp_list(stat.rhs,first_right,func,n_rights)
      if n_rights < n_lefts then
        -- set nil to extra lefts
        for i = n_lefts,n_rights+1,-1 do
          -- justarandomgeek
          -- not sure why i made a loop for setting nil to extras, you just need to generate a LOADNIL for "the rest" there basically
          error()
        end
      end
      -- copy rights to lefts
      for i = n_rights,1,-1 do
        local right = first_right + i - 1
        local left = lefts[i]
        if left.type == "index" then
          func.instructions[#func.instructions+1] = {
            op = left.ex_is_up and opcodes.settabup or opcodes.settable,
            a = left.ex, b = left.suffix, ck = right
          }
        elseif left.type == "local" then
          func.instructions[#func.instructions+1] = {
            op = opcodes.move, a = left.reg, b = right
          }
        else
          -- justarandomgeek:
          -- oh i guess it would need another case there paired with handling the top one to deal with an upval
          -- which is for if you do foo = 1 and foo is an upval rather than a local
          -- so it doesn't need any prefetch but it needs setupval instead of move when you generate code for it
          -- presumably some clues attached to the node which upval it was, but i don't remember
          -- but that's some hints to attach for whenever you do get around to that
          error()
        end
      end
      release_down_to(func,top)
    end,
    localfunc = function(stat,func)
      -- allocate register for stat.name
      local func_reg = next_reg(func)
      local live_reg = create_live_reg(func, func_reg, stat.name.name)
      -- declare new register to be "live" with local right away for upval capture
      func.live_regs[#func.live_regs+1] = live_reg
      -- CLOSURE into that register
      -- TODO: set upval indexes for in_stack upvals
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = func_reg, bx = stat.ref.index,
        line = stat.line, column = stat.column,
      }
      live_reg.start_at = #func.instructions
    end,
    ---@param stat AstFuncStat
    funcstat = function(stat,func)
      local in_reg,parent,parent_is_up
      if #stat.names == 1 and stat.names[1].node_type=="local" then
        -- if name is a local, we can just build the closure in place
        in_reg = find_local(stat.names[1].ref,func) ---@diagnostic disable-line: undefined-field -- TODO
      else
        -- otherwise, we need its parent table and a temporary to fetch it in...
        error()
        in_reg = next_reg(func)
      end

      -- CLOSURE into that register
      -- TODO: set upval indexes for in_stack upvals
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = in_reg, bx = stat.ref.index, ---@diagnostic disable-line: undefined-field -- TODO
      }

      if parent then
        error()
      elseif parent_is_up then
        error()
      end
    end,
    dostat = function(stat,func)
      local top = func.next_reg
      for i,inner_stat in ipairs(stat.body) do
        generate_statement_code[inner_stat.node_type](inner_stat,func)
      end
      release_down_to(func,top)
    end,
    ifstat = function(stat,func)
      for i,if_block in ipairs(stat.ifs) do
        local top = func.next_reg
        local condition_node = if_block.condition
        local condition_node_type = condition_node.node_type

        if is_falsy(condition_node) then -- TODO: imo this should be moved out to be an optimization
          -- always false, skip this block
          goto next_block
        elseif const_node_types[condition_node_type] then
          -- always true, stop after this block

          -- TODO: include table constructors and closures here
          -- maybe function calls of known truthy return types too?
          -- but those still need to eval it if captured to a block local
          error()
        else
          -- generate a value and `test` it...
          generate_test_code(condition_node)
          error()
        end

        -- generate body
        for j,inner_stat in ipairs(if_block.body) do
          generate_statement_code[inner_stat.node_type](inner_stat,func)
        end
        release_down_to(func,top)
        -- jump from end of body to end of blocks (not yet determined, build patch list)
        -- patch test failure to jump here for next test/else/next_block
        ::next_block::
      end
      if stat.elseblock then
        local top = func.next_reg
        for i,inner_stat in ipairs(stat.elseblock.body) do
          generate_statement_code[inner_stat.node_type](inner_stat,func)
        end
        release_down_to(func,top)
        -- patch if block ends to jump here
      end
    end,
    call = function(stat,func)
      -- evaluate as a call expression for zero results
      local func_reg = next_reg(func)
      generate_expr(stat,func_reg,func,0)
      release_down_to(func,func_reg)
    end,
    selfcall = function(stat,func)
      -- evaluate as a selfcall expression for zero results
      local func_reg = next_reg(func)
      generate_expr(stat,func_reg,func,0)
      release_down_to(func,func_reg)
    end,
    forlist = function(stat,func)
      local top = func.next_reg
      -- allocate forlist internal vars
      local generator = next_reg(func)
      local generator_info = {
        reg = generator,
        name = {node_type = "internal", value = "(for generator)"},
      }
      func.live_regs[#func.live_regs+1] = generator_info
      local state = next_reg(func)
      local state_info = {
        reg = state,
        name = {node_type = "internal", value = "(for state)"},
      }
      func.live_regs[#func.live_regs+1] = state_info
      local control = next_reg(func)
      local control_info = {
        reg = control,
        name = {node_type = "internal", value = "(for control)"},
      }
      func.live_regs[#func.live_regs+1] = control_info
      local inner_top = func.next_reg
      -- eval exp_list for three results starting at generator
      generate_exp_list(stat.exp_list,generator,func,3)
      -- jmp to tforcall
      local jmp = {
        op = opcodes.jmp, a = 0, -- a=close upvals?, sbx= jump target
      }
      func.instructions[#func.instructions+1] = jmp
      -- go back and set internals live
      generator_info.start_at = jmp
      state_info.start_at = jmp
      control_info.start_at = jmp
      -- allocate for locals, declare them live
      for i,name in ipairs(stat.name_list) do
        func.live_regs[#func.live_regs+1] = {
          reg = control,
          name = name,
          start_at = jmp
        }
      end
      -- generate body
      for i,inner_stat in ipairs(stat.body) do
        generate_statement_code[inner_stat.node_type](inner_stat,func)
      end

      release_down_to(func,inner_top)
      -- loop
      local tforcall = {
        op = opcodes.tforcall, a = generator, c = #stat.name_list, -- a=func, c=num loop vars
      }
      jmp.sbx = tforcall
      func.instructions[#func.instructions+1] = tforcall
      func.instructions[#func.instructions+1] = {
        op = opcodes.tforloop, a = control, sbx = jmp, -- jump back to just start of body
      }

      release_down_to(func,top)
    end,
    fornum = function(stat,func)
      error()
      local top = func.next_reg
      -- allocate fornum internal vars
      -- eval start/stop/step into internals
      -- allocate for local, declare it live
      -- generate body
      for i,inner_stat in ipairs(stat.body) do
        generate_statement_code[inner_stat.node_type](inner_stat,func)
      end
      -- loop

      release_down_to(func,top)
    end,
    whilestat = function(stat,func)
      error()
      local top = func.next_reg
      -- eval stat.condition in a temporary
      -- test, else jump past body+jump
      -- generate body
      for i,inner_stat in ipairs(stat.body) do
        generate_statement_code[inner_stat.node_type](inner_stat,func)
      end
      -- jump back

      release_down_to(func,top)
    end,
    repeatstat = function(stat,func)
      error()
      local top = func.next_reg
      -- generate body
      for i,inner_stat in ipairs(stat.body) do
        generate_statement_code[inner_stat.node_type](inner_stat,func)
      end
      -- eval stat.condition in a temporary
      -- jump back if false

      release_down_to(func,top)
    end,

    retstat = function(stat,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes["return"], a = 0, b = 1
      }
      -- error() -- TODO
      -- eval exp_list into temporaries
      -- RETURN them
    end,

    label = function(stat,func)
      error()
      -- record PC for label
      -- check for pending jump and patch to jump here
    end,
    gotostat = function(stat,func)
      error()
      -- match to jump-back label, or set as pending jump
    end,
    breakstat = function(stat,func)
      error()
      -- jump to end of block (record for later rewrite)
    end,

    empty = function(stat,func)
      -- empty statement
    end,
  }
  function generate_code(func)
    func.live_regs = {}
    func.next_reg = 0 -- *ZERO BASED* index of next register to use
    func.max_stack_size = 2 -- always at least two registers
    func.instructions = {}

    for i,func_proto in ipairs(func.func_protos) do
      func_proto.index = i - 1 -- *ZERO BASED* index
    end

    for i,upval in ipairs(func.upvals) do
      upval.index = i - 1 -- *ZERO BASED* index
    end

    for i,stat in ipairs(func.body) do
      generate_statement_code[stat.node_type](stat,func)
    end

    -- TODO: this is temp
    func.instructions[#func.instructions+1] = {
      op = opcodes["return"], a = 0, b = 1,
      line = func.end_token and func.end_token.line
        or func.instructions[#func.instructions] and func.instructions[#func.instructions].line
        or 0,
      column = func.end_token and func.end_token.column
        or func.instructions[#func.instructions] and func.instructions[#func.instructions].column
        or 0,
    }
    -- TODO: not sure about this
    release_down_to(func, -1)

    for i,func_proto in ipairs(func.func_protos) do
      generate_code(func_proto)
    end

  end
end

return generate_code
