
local invert = require("invert")
----------------------------------------------------------------------
local generate_code
do
  local opcodes = require("opcodes")
  --- get the next available register in the current function
  ---@param func Function
  ---@return number regnum
  local function next_reg(func)
    local n = func.next_reg
    local next_n = n + 1
    func.next_reg = next_n
    if next_n > func.max_stack_size then
      func.max_stack_size = next_n
    end
    return n
  end
  local function release_reg(func,reg)
    if reg ~= func.next_reg - 1 then
      error("Attempted to release register "..reg.." when top was "..func.next_reg)
    end
    -- if it had a live local in it, end it here
    local live_regs = func.live_regs
    local last_inst = func.instructions[#func.instructions]
    for i = #live_regs,1,-1 do
      local lr = live_regs[i]
      if not lr.stop_at and lr.reg == reg then
        lr.stop_at = last_inst
      end
    end

    func.next_reg = reg
  end
  local function release_down_to(func,reg)
    if reg == func.next_reg then
      return
    end

    if reg > func.next_reg then
      error("Attempted to release registers down to "..reg.." when top was "..func.next_reg)
    end
    -- if any had live locals, end them here
    local live_regs = func.live_regs
    local last_inst = func.instructions[#func.instructions]
    for i = #live_regs,1,-1 do
      local lr = live_regs[i]
      if not lr.stop_at and lr.reg >= reg then
        lr.stop_at = last_inst
      end
    end
    func.next_reg = reg
  end

  local generate_expr_code
  local vararg_tokens = invert{"...","call","selfcall"}
  local function generate_expr(expr,in_reg,func,num_results)
    generate_expr_code[expr.token](expr,in_reg,func,num_results)
    if num_results > 1 and not vararg_tokens[expr.token] then
      --loadnil in_reg+1 to in_reg+num_results
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadnil, a = in_reg+1, b = num_results - 1
      }
    end
  end

  local function generate_exp_list(exp_list,in_reg,func,num_results)
    local num_exp = #exp_list
    local base = in_reg - 1
    local used_temp
    do
      local at_top = in_reg >= func.next_reg - 1
      if not at_top then
        if num_results == -1 then
          error("Cannot generate variable-length exp_list except at top")
        end
        used_temp = true
        base = func.next_reg - 1
      end
    end
    for i,expr in ipairs(exp_list) do
      if i == num_exp then
        local n_result = -1
        if num_results ~= -1 then
          n_result = (num_results - num_exp) + 1
        end
        if used_temp then
          func.next_reg = base + i + 1
        end
        generate_expr(expr,base + i,func,n_result)
      elseif i > num_exp then
        break -- TODO: no error?
      else
        if used_temp then
          func.next_reg = base + i + 1
        end
        generate_expr(expr,base + i,func,1)
      end
    end
    if used_temp then
      -- move from base+i to in_reg+i
      for i = 1,num_results do
        func.instructions[#func.instructions+1] = {
          op = opcodes.move, a = in_reg+i, b = base+i
        }
      end
      release_down_to(func,base+1)
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
      }
    else
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadkx, a = in_reg,
      }
      func.instructions[#func.instructions+1] = {
        op = opcodes.extraarg, ax = k,
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
    local last_reg
    for i = #live_regs,1,-1 do
      local lr = live_regs[i]
      if not lr.stop_at and last_reg ~= lr.reg then
        last_reg = lr.reg
        if lr.name == ref.name then
          return lr.reg
        end
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
    if expr.token == "local" then
      return find_local(expr.ref,func)
    else
      generate_expr(expr,in_reg,func,1)
      return in_reg
    end
  end
  local const_tokens = invert{"true","false","nil","string","number"}
  local false_tokens = invert{"false","nil"}
  local logical_binops = invert{">",">=","==","~=","<=","<"}
  local function const_or_local_or_fetch(expr,in_reg,func)
    if const_tokens[expr.token] then
      return bit32.bor(add_constant(expr.value,func),0x100)
    else
      return local_or_fetch(expr,in_reg,func)
    end
  end
  local function upval_or_local_or_fetch(expr,in_reg,func)
    if expr.token == "upval" then
      return expr.ref.index,true
    else
      return local_or_fetch(expr,in_reg,func),false
    end
  end
  generate_expr_code = {
    ["local"] = function(expr,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.move, a = in_reg, b = find_local(expr.ref,func),
      }
    end,
    ---@param expr AstUpVal
    ---@param in_reg integer
    ---@param func GeneratedFunc
    upval = function(expr,in_reg,func)
      -- getupval
      func.instructions[#func.instructions+1] = {
        op = opcodes.getupval, a = in_reg, b = find_upval(expr.value,func),
      }
    end,
    binop = function(expr,in_reg,func)
      -- if expr.left and .right are locals, use them in place
      -- if they're constants, add to const table and use in place from there
      --   unless const table is too big, then fetch into temporary (and emit warning: const table too large)
      -- else fetch them into temporaries
      --   first temporary is in_reg, second is next_reg()
      local tmp_reg,used_temp = in_reg,false
      local left_reg = const_or_local_or_fetch(expr.left,tmp_reg,func)
      if left_reg == in_reg then
        tmp_reg = next_reg(func)
        used_temp = true
      end
      local right_reg = const_or_local_or_fetch(expr.right,tmp_reg,func)
      if used_temp and right_reg ~= tmp_reg then
        release_reg(func,tmp_reg)
        used_temp = false
      end

      func.instructions[#func.instructions+1] = {
        op = bin_opcodes[expr.op], a = in_reg, bk = left_reg, ck = right_reg
      }
      -- if two temporaries, release second
      if used_temp then
        release_reg(func,tmp_reg)
      end
    end,
    unop = function(expr,in_reg,func)
      -- if expr.ex is a local use that directly,
      -- else fetch into in_reg
      local scr_reg = local_or_fetch(expr.ex,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = un_opcodes[expr.op], a = in_reg, b = scr_reg,
      }
    end,
    concat = function(expr,in_reg,func)
      local tmp_reg = in_reg
      local used_temp
      if tmp_reg ~= func.next_reg - 1 then
        tmp_reg = next_reg(func)
        used_temp = true
      end
      local num_exp = #expr.exp_list
      generate_exp_list(expr.exp_list,tmp_reg,func,num_exp)
      func.instructions[#func.instructions+1] = {
        op = opcodes.concat, a = in_reg, b = tmp_reg, c = tmp_reg + num_exp - 1
      }
      if used_temp then
        release_reg(func,tmp_reg)
      end
    end,
    number = generate_const_code,
    string = generate_const_code,
    ["true"] = function(expr,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadbool, a = in_reg, b = 1, c = 0
      }
    end,
    ["false"] = function(expr,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadbool, a = in_reg, b = 0, c = 0
      }
    end,
    ["nil"] = function(expr,in_reg,func,num_results)
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadnil, a = in_reg, b = num_results or 0
      }
    end,
    constructor = function(expr,in_reg,func)
      local new_tab = {
        op = opcodes.newtable, a = in_reg, b = 0, c = 0 -- TODO: create with right size
      }
      func.instructions[#func.instructions+1] = new_tab
      local top = func.next_reg
      local list_count = 0
      local last_field = #expr.fields
      for i,field in ipairs(expr.fields) do
        if field.type == "list" then
          -- if list accumulate values
          local count = 1
          if i == last_field then
            count = -1
          end
          generate_expr(field.value,next_reg(func),func,count)
          --TODO: for very long lists, go ahead and assign it and start another set
        elseif field.type == "rec" then
          -- if rec, set in table immediately
          local tmp_reg,used_temp = next_reg(func),{}
          local key_reg = const_or_local_or_fetch(field.key,tmp_reg,func)
          if key_reg == in_reg then
            tmp_reg = next_reg(func)
            used_temp.key = true
          end
          local value_reg = const_or_local_or_fetch(field.value,tmp_reg,func)
          if value_reg ~= tmp_reg then
            release_reg(func,tmp_reg)
          else
            used_temp.val = true
          end

          func.instructions[#func.instructions+1] = {
            op = opcodes.settable, a = in_reg, bk = key_reg, ck = value_reg
          }

          if used_temp.val then
            release_reg(func,value_reg)
          end
          if used_temp.key then
            release_reg(func,key_reg)
          end
        else
          error("Invalid field type in table constructor")
        end
      end
      if list_count > 0 then
        func.instructions[#func.instructions+1] = {
          op = opcodes.setlist, a = in_reg, b = list_count,  c = 1
        }
        release_down_to(func,top)
      end
    end,
    func_proto = function(expr,in_reg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = in_reg, bx = expr.ref.index
      }
    end,
    ["..."] = function(expr,in_reg,func,num_results)
      func.instructions[#func.instructions+1] = {
        op = opcodes.vararg, a = in_reg, b = (num_results or 1)+1
      }
    end,
    call = function(expr,in_reg,func,num_results)
      local func_reg = in_reg
      local used_temp
      local top = func.next_reg
      local at_top =  func_reg >= func.next_reg - 1
      if not at_top then
        if num_results == -1 then
          error("Can't return variable results unless top of stack")
        end
        func_reg = next_reg(func)
        used_temp = true
      end
      generate_expr(expr.ex,func_reg,func,1)
      if used_temp then
        func.next_reg = func_reg + 2
      end
      generate_exp_list(expr.args,func_reg+1,func,-1)
      local arg_count = #expr.args
      if arg_count > 0 and vararg_tokens[expr.args[arg_count].token] then
        arg_count = -1
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.call, a = func_reg, b = arg_count+1, c = (num_results or 1)+1
      }
      if used_temp then
        error()
        -- copy from func_reg+n to in_reg+n
      end
      release_down_to(func,top)
    end,
    selfcall = function(expr,in_reg,func,num_results)
      local func_reg = in_reg
      local used_temp
      if func_reg ~= func.next_reg - 1 then
        if num_results == -1 then
          error("Can't return variable results unless top of stack")
        end
        func_reg = next_reg(func)
        used_temp = true
      end
      local exp_reg = local_or_fetch(expr.ex,func_reg,func)
      local suffix_reg = const_or_local_or_fetch(expr.suffix,func_reg+1,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.self, a = func_reg, b = exp_reg, c = suffix_reg
      }
      generate_exp_list(expr.args,func_reg+2,func,-1)
      local arg_count = #expr.args
      if arg_count > 0 and vararg_tokens[expr.args[arg_count].token] then
        arg_count = -1
      else
        arg_count = arg_count + 1
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.call, a = func_reg, b = arg_count+1, c = (num_results or 1)+1
      }
    end,
    index = function(expr,in_reg,func)
      local tmp_reg,used_temp = in_reg,false
      local ex,is_upval = upval_or_local_or_fetch(expr.ex,tmp_reg,func)
      if (not is_upval) and ex == in_reg then
        tmp_reg = next_reg(func)
        used_temp = true
      end

      local suffix = const_or_local_or_fetch(expr.suffix,tmp_reg,func)
      if used_temp and suffix ~= tmp_reg then
        release_reg(func,tmp_reg)
        used_temp = false
      end

      func.instructions[#func.instructions+1] = {
        op = is_upval and opcodes.gettabup or opcodes.gettable,
        a = in_reg, b = ex, ck = suffix
      }
      -- if two temporaries, release second
      if used_temp then
        release_reg(func,tmp_reg)
      end
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
    if condition.token == "binop" and logical_binops[condition.op] then

    else

    end
    error()
  end

  local generate_statement_code
  generate_statement_code = {
    localstat = function(stat,func)
      -- allocate registers for LHS, eval expressions into them
      local new_live = {}
      for i,ref in ipairs(stat.lhs) do
        local live = {reg = next_reg(func), name = ref}
        new_live[i] = live
        func.live_regs[#func.live_regs+1] = live
      end

      if stat.rhs then
        generate_exp_list(stat.rhs,new_live[1].reg,func,#stat.lhs)
      else
        --loadnil
        generate_expr_code["nil"](nil,new_live[1].reg,func,#stat.lhs)
      end

      -- declare new registers to be "live" with locals after this
      local last_pc = func.instructions[#func.instructions]
      for i,live in ipairs(new_live) do
        live.start_after = last_pc
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
        if left.token == "local" then
          lefts[i] = {
            type = "local",
            reg = find_local(left.ref,func),
          }
        elseif left.token == "upval" then
          lefts[i] = {
            type = "upval",
            upval = error()

          }
        elseif left.token == "index" then
          -- if index and parent not local/upval, fetch parent to temporary
          local new_left = {
            type = "index",
          }
          local tmp_reg = next_reg(func)
          new_left.ex,new_left.ex_is_up = upval_or_local_or_fetch(left.ex,tmp_reg,func)
          if not new_left.ex_is_up and new_left.ex == tmp_reg then
            tmp_reg = next_reg(func)
          end
          new_left.suffix = const_or_local_or_fetch(left.suffix,tmp_reg,func)
          if new_left.suffix ~= tmp_reg then
            release_reg(func,tmp_reg)
          end
          lefts[i] = new_left
        else
          error("Attempted to assign to " .. left.token)
        end
      end
      local n_lefts = #lefts
      local first_right = func.next_reg
      local n_rights = #stat.rhs
      if vararg_tokens[stat.rhs[n_rights].token] then
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
          -- presumably some clues attached to the token which upval it was, but i don't remember
          -- but that's some hints to attach for whenever you do get around to that
          error()
        end
      end
      release_down_to(func,top)
    end,
    localfunc = function(stat,func)
      -- allocate register for stat.name
      local a = next_reg(func)
      -- declare new register to be "live" with local right away for upval capture
      local live_reg = {
        reg = a,
        name = stat.ref,
      }
      func.live_regs[#func.live_regs+1] = live_reg
      -- CLOSURE into that register
      local instr = {
        op = opcodes.closure, a = a, bx = stat.ref.index,
      }
      live_reg.start_at = instr
      func.instructions[#func.instructions+1] = instr
    end,
    ---@param stat AstFuncStat
    funcstat = function(stat,func)
      local in_reg,parent,parent_is_up
      if #stat.names == 1 and stat.names[1].token=="local" then
        -- if name is a local, we can just build the closure in place
        in_reg = find_local(stat.names[1].ref,func) ---@diagnostic disable-line: undefined-field -- TODO
      else
        -- otherwise, we need its parent table and a temporary to fetch it in...
        error()
        in_reg = next_reg(func)
      end

      -- CLOSURE into that register
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
        generate_statement_code[inner_stat.token](inner_stat,func)
      end
      release_down_to(func,top)
    end,
    ifstat = function(stat,func)
      for i,if_block in ipairs(stat.ifs) do
        local top = func.next_reg
        local condition = if_block.condition
        local condition_token = condition.token

        if false_tokens[condition_token] then
          -- always false, skip this block
          goto next_block
        elseif const_tokens[condition_token] then
          -- always true, stop after this block

          -- TODO: include table constructors and closures here
          -- maybe function calls of known truthy return types too?
          -- but those still need to eval it if captured to a block local
          error()
        else
          -- generate a value and `test` it...
          generate_test_code(condition)
          error()
        end

        -- generate body
        for j,inner_stat in ipairs(if_block.body) do
          generate_statement_code[inner_stat.token](inner_stat,func)
        end
        release_down_to(func,top)
        -- jump from end of body to end of blocks (not yet determined, build patch list)
        -- patch test failure to jump here for next test/else/next_block
        ::next_block::
      end
      if stat.elseblock then
        local top = func.next_reg
        for i,inner_stat in ipairs(stat.elseblock.body) do
          generate_statement_code[inner_stat.token](inner_stat,func)
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
        name = {token = "internal", value = "(for generator)"},
      }
      func.live_regs[#func.live_regs+1] = generator_info
      local state = next_reg(func)
      local state_info = {
        reg = state,
        name = {token = "internal", value = "(for state)"},
      }
      func.live_regs[#func.live_regs+1] = state_info
      local control = next_reg(func)
      local control_info = {
        reg = control,
        name = {token = "internal", value = "(for control)"},
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
        generate_statement_code[inner_stat.token](inner_stat,func)
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
        generate_statement_code[inner_stat.token](inner_stat,func)
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
        generate_statement_code[inner_stat.token](inner_stat,func)
      end
      -- jump back

      release_down_to(func,top)
    end,
    repeatstat = function(stat,func)
      error()
      local top = func.next_reg
      -- generate body
      for i,inner_stat in ipairs(stat.body) do
        generate_statement_code[inner_stat.token](inner_stat,func)
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
      generate_statement_code[stat.token](stat,func)
    end

    func.instructions[#func.instructions+1] = {
      op = opcodes["return"], a = 0, b = 1,
    }

    for i,func_proto in ipairs(func.func_protos) do
      generate_code(func_proto)
    end

  end
end

return generate_code
