
local invert = require("invert")
----------------------------------------------------------------------
local generate_code
do
  local opcodes = {}
  for i,op in ipairs{
    "move", "loadk", "loadkx", "loadbool", "loadnil",

    "getupval", "gettabup", "gettable",
    "settabup", "setupval", "settable",

    "newtable", "self",

    "add", "sub", "mul", "div", "mod", "pow",
    "unm", "not", "len",

    "concat",

    "jmp", "eq", "lt", "le",

    "test", "testset",

    "call", "tailcall", "return",

    "forloop", "forprep",
    "tforcall", "tforloop",

    "setlist",
    "closure",
    "vararg",
    "extraarg",
  } do
    opcodes[op] = i-1
  end
  --- get the next available register in the current function
  ---@param func Function
  ---@return number regnum
  local function next_reg(func)
    local n = func.nextreg
    local ninc = n + 1
    func.nextreg = ninc
    if ninc > func.maxstacksize then
      func.maxstacksize = ninc
    end
    return n
  end
  local function release_reg(func,reg)
    if reg ~= func.nextreg - 1 then
      error("Attempted to release register "..reg.." when top was "..func.nextreg)
    end
    -- if it had a live local in it, end it here
    local liveregs = func.liveregs
    local lastinst = func.instructions[#func.instructions]
    for i = #liveregs,1,-1 do
      local lr = liveregs[i]
      if not lr.stopat and lr.reg == reg then
        lr.stopat = lastinst
      end
    end

    func.nextreg = reg
  end
  local function release_down_to(func,reg)
    if reg == func.nextreg then
      return
    end

    if reg > func.nextreg then
      error("Attempted to release registers down to "..reg.." when top was "..func.nextreg)
    end
    -- if any had live locals, end them here
    local liveregs = func.liveregs
    local lastinst = func.instructions[#func.instructions]
    for i = #liveregs,1,-1 do
      local lr = liveregs[i]
      if not lr.stopat and lr.reg >= reg then
        lr.stopat = lastinst
      end
    end
    func.nextreg = reg
  end

  local generate_expr_code
  local varargtokens = invert{"...","call","selfcall"}
  local function generate_expr(expr,inreg,func,numresults)
    generate_expr_code[expr.token](expr,inreg,func,numresults)
    if numresults > 1 and not varargtokens[expr.token] then
      --loadnil inreg+1 to inreg+numresults
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadnil, a = inreg+1, b = numresults - 1
      }
    end
  end

  local function generate_explist(explist,inreg,func,numresults)
    local numexpr = #explist
    local base = inreg - 1
    local used_temp
    do
      local attop = inreg >= func.nextreg - 1
      if not attop then
        if numresults == -1 then
          error("Cannot generate variable-length explist except at top")
        end
        used_temp = true
        base = func.nextreg - 1
      end
    end
    for i,expr in ipairs(explist) do
      if i == numexpr then
        local nres = -1
        if numresults ~= -1 then
          nres = (numresults - numexpr) + 1
        end
        if used_temp then
          func.nextreg = base + i + 1
        end
        generate_expr(expr,base + i,func,nres)
      elseif i > numexpr then
        break -- TODO: no error?
      else
        if used_temp then
          func.nextreg = base + i + 1
        end
        generate_expr(expr,base + i,func,1)
      end
    end
    if used_temp then
      -- move from base+i to inreg+i
      for i = 1,numresults do
        func.instructions[#func.instructions+1] = {
          op = opcodes.move, a = inreg+i, b = base+i
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
  local function generate_const_code(expr,inreg,func)
    local k = add_constant(expr.value,func)
    if k <= 0x3ffff then
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadk, a = inreg, bx = k,
      }
    else
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadkx, a = inreg,
      }
      func.instructions[#func.instructions+1] = {
        op = opcodes.extraarg, ax = k,
      }
    end
  end
  local binopcodes = {
    ["+"] = opcodes.add,
    ["-"] = opcodes.sub,
    ["*"] = opcodes.mul,
    ["/"] = opcodes.div,
    ["%"] = opcodes.mod,
    ["^"] = opcodes.pow,
  }
  local unopcodes = {
    ["-"] = opcodes.unm,
    ["#"] = opcodes.len,
    ["not"] = opcodes["not"],
  }
  local function find_local(ref,func)
    -- find it in liveregs and use that...
    local liveregs = func.liveregs
    local lastreg
    for i = #liveregs,1,-1 do
      local lr = liveregs[i]
      if not lr.stopat and lastreg ~= lr.reg then
        lastreg = lr.reg
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
  local function local_or_fetch(expr,inreg,func)
    if expr.token == "local" then
      return find_local(expr.ref,func)
    else
      generate_expr(expr,inreg,func,1)
      return inreg
    end
  end
  local const_tokens = invert{"true","false","nil","string","number"}
  local false_tokens = invert{"false","nil"}
  local logical_binops = invert{">",">=","==","~=","<=","<"}
  local function const_or_local_or_fetch(expr,inreg,func)
    if const_tokens[expr.token] then
      return bit32.bor(add_constant(expr.value,func),0x100)
    else
      return local_or_fetch(expr,inreg,func)
    end
  end
  local function upval_or_local_or_fetch(expr,inreg,func)
    if expr.token == "upval" then
      return expr.ref.index,true
    else
      return local_or_fetch(expr,inreg,func),false
    end
  end
  generate_expr_code = {
    ["local"] = function(expr,inreg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.move, a = inreg, b = find_local(expr.ref,func),
      }
    end,
    ---@param expr AstUpVal
    ---@param inreg integer
    ---@param func GeneratedFunc
    upval = function(expr,inreg,func)
      -- getupval
      func.instructions[#func.instructions+1] = {
        op = opcodes.getupval, a = inreg, b = find_upval(expr.value,func),
      }
    end,
    binop = function(expr,inreg,func)
      -- if expr.left and .right are locals, use them in place
      -- if they're constants, add to const table and use in place from there
      --   unless const table is too big, then fetch into temporary (and emit warning: const table too large)
      -- else fetch them into temporaries
      --   first temporary is inreg, second is next_reg()
      local tmpreg,used_temp = inreg,false
      local leftreg = const_or_local_or_fetch(expr.left,tmpreg,func)
      if leftreg == inreg then
        tmpreg = next_reg(func)
        used_temp = true
      end
      local rightreg = const_or_local_or_fetch(expr.right,tmpreg,func)
      if used_temp and rightreg ~= tmpreg then
        release_reg(func,tmpreg)
        used_temp = false
      end

      func.instructions[#func.instructions+1] = {
        op = binopcodes[expr.op], a = inreg, bk = leftreg, ck = rightreg
      }
      -- if two temporaries, release second
      if used_temp then
        release_reg(func,tmpreg)
      end
    end,
    unop = function(expr,inreg,func)
      -- if expr.ex is a local use that directly,
      -- else fetch into inreg
      local srcreg = local_or_fetch(expr.ex,inreg,func)
      func.instructions[#func.instructions+1] = {
        op = unopcodes[expr.op], a = inreg, b = srcreg,
      }
    end,
    concat = function(expr,inreg,func)
      local tmpreg = inreg
      local used_temp
      if tmpreg ~= func.nextreg - 1 then
        tmpreg = next_reg(func)
        used_temp = true
      end
      local numexpr = #expr.explist
      generate_explist(expr.explist,tmpreg,func,numexpr)
      func.instructions[#func.instructions+1] = {
        op = opcodes.concat, a = inreg, b = tmpreg, c = tmpreg + numexpr - 1
      }
      if used_temp then
        release_reg(func,tmpreg)
      end
    end,
    number = generate_const_code,
    string = generate_const_code,
    ["true"] = function(expr,inreg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadbool, a = inreg, b = 1, c = 0
      }
    end,
    ["false"] = function(expr,inreg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadbool, a = inreg, b = 0, c = 0
      }
    end,
    ["nil"] = function(expr,inreg,func,numresults)
      func.instructions[#func.instructions+1] = {
        op = opcodes.loadnil, a = inreg, b = numresults or 0
      }
    end,
    constructor = function(expr,inreg,func)
      local newtab = {
        op = opcodes.newtable, a = inreg, b = 0, c = 0 -- TODO: create with riht size
      }
      func.instructions[#func.instructions+1] = newtab
      local top = func.nextreg
      local listcount = 0
      local lastfield = #expr.fields
      for i,field in ipairs(expr.fields) do
        if field.type == "list" then
          -- if list accumulate values
          local count = 1
          if i == lastfield then
            count = -1
          end
          generate_expr(field.value,next_reg(func),func,count)
          --TODO: for very long lists, go ahead and assign it and start another set
        elseif field.type == "rec" then
          -- if rec, set in table immediately
          local tmpreg,used_temp = next_reg(func),{}
          local keyreg = const_or_local_or_fetch(field.key,tmpreg,func)
          if keyreg == inreg then
            tmpreg = next_reg(func)
            used_temp.key = true
          end
          local valreg = const_or_local_or_fetch(field.value,tmpreg,func)
          if valreg ~= tmpreg then
            release_reg(func,tmpreg)
          else
            used_temp.val = true
          end

          func.instructions[#func.instructions+1] = {
            op = opcodes.settable, a = inreg, bk = keyreg, ck = valreg
          }

          if used_temp.val then
            release_reg(func,valreg)
          end
          if used_temp.key then
            release_reg(func,keyreg)
          end
        else
          error("Invalid field type in table constructor")
        end
      end
      if listcount > 0 then
        func.instructions[#func.instructions+1] = {
          op = opcodes.setlist, a = inreg, b = listcount,  c = 1
        }
        release_down_to(func,top)
      end
    end,
    funcproto = function(expr,inreg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = inreg, bx = expr.ref.index
      }
    end,
    ["..."] = function(expr,inreg,func,numresults)
      func.instructions[#func.instructions+1] = {
        op = opcodes.vararg, a = inreg, b = (numresults or 1)+1
      }
    end,
    call = function(expr,inreg,func,numresults)
      local funcreg = inreg
      local used_temp
      local top = func.nextreg
      local attop =  funcreg >= func.nextreg - 1
      if not attop then
        if numresults == -1 then
          error("Can't return variable results unless top of stack")
        end
        funcreg = next_reg(func)
        used_temp = true
      end
      generate_expr(expr.ex,funcreg,func,1)
      if used_temp then
        func.nextreg = funcreg + 2
      end
      generate_explist(expr.args,funcreg+1,func,-1)
      local argcount = #expr.args
      if argcount > 0 and varargtokens[expr.args[argcount].token] then
        argcount = -1
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.call, a = funcreg, b = argcount+1, c = (numresults or 1)+1
      }
      if used_temp then
        error()
        -- copy from funcreg+n to inreg+n
      end
      release_down_to(func,top)
    end,
    selfcall = function(expr,inreg,func,numresults)
      local funcreg = inreg
      local used_temp
      if funcreg ~= func.nextreg - 1 then
        if numresults == -1 then
          error("Can't return variable results unless top of stack")
        end
        funcreg = next_reg(func)
        used_temp = true
      end
      local exreg = local_or_fetch(expr.ex,funcreg,func)
      local suffixreg = const_or_local_or_fetch(expr.suffix,funcreg+1,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.self, a = funcreg, b = exreg, c = suffixreg
      }
      generate_explist(expr.args,funcreg+2,func,-1)
      local argcount = #expr.args
      if argcount > 0 and varargtokens[expr.args[argcount].token] then
        argcount = -1
      else
        argcount = argcount + 1
      end
      func.instructions[#func.instructions+1] = {
        op = opcodes.call, a = funcreg, b = argcount+1, c = (numresults or 1)+1
      }
    end,
    index = function(expr,inreg,func)
      local tmpreg,used_temp = inreg,false
      local ex,isupval = upval_or_local_or_fetch(expr.ex,tmpreg,func)
      if (not isupval) and ex == inreg then
        tmpreg = next_reg(func)
        used_temp = true
      end

      local suffix = const_or_local_or_fetch(expr.suffix,tmpreg,func)
      if used_temp and suffix ~= tmpreg then
        release_reg(func,tmpreg)
        used_temp = false
      end

      func.instructions[#func.instructions+1] = {
        op = isupval and opcodes.gettabup or opcodes.gettable,
        a = inreg, b = ex, ck = suffix
      }
      -- if two temporaries, release second
      if used_temp then
        release_reg(func,tmpreg)
      end
    end,
  }

  local function generate_test_code(cond)
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
    if cond.token == "binop" and logical_binops[cond.op] then

    else

    end
    error()
  end

  local generate_statement_code
  generate_statement_code = {
    localstat = function(stat,func)
      -- allocate registers for LHS, eval expressions into them
      local newlive = {}
      for i,ref in ipairs(stat.lhs) do
        local live = {reg = next_reg(func), name = ref}
        newlive[i] = live
        func.liveregs[#func.liveregs+1] = live
      end

      if stat.rhs then
        generate_explist(stat.rhs,newlive[1].reg,func,#stat.lhs)
      else
        --loadnil
        generate_expr_code["nil"](nil,newlive[1].reg,func,#stat.lhs)
      end

      -- declare new registers to be "live" with locals after this
      local lastpc = func.instructions[#func.instructions]
      for i,live in ipairs(newlive) do
        live.startafter = lastpc
      end
    end,
    assignment = function(stat,func)
      -- evaluate all expressions (assignment parent/key, values) into temporaries, left to right
      -- last expr in value list is for enough values to fill the list
      -- emit warning and drop extra values with no targets
      -- move/settable/settabup from temporary to target, right to left
      local top = func.nextreg
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
          local newleft = {
            type = "index",
          }
          local tmpreg = next_reg(func)
          newleft.ex,newleft.ex_is_up = upval_or_local_or_fetch(left.ex,tmpreg,func)
          if not newleft.ex_is_up and newleft.ex == tmpreg then
            tmpreg = next_reg(func)
          end
          newleft.suffix = const_or_local_or_fetch(left.suffix,tmpreg,func)
          if newleft.suffix ~= tmpreg then
            release_reg(func,tmpreg)
          end
          lefts[i] = newleft
        else
          error("Attempted to assign to " .. left.token)
        end
      end
      local numlefts = #lefts
      local firstright = func.nextreg
      local numrights = #stat.rhs
      if varargtokens[stat.rhs[numrights].token] then
        numrights = numlefts
      end
      generate_explist(stat.rhs,firstright,func,numrights)
      if numrights < numlefts then
        -- set nil to extra lefts
        for i = numlefts,numrights+1,-1 do
          -- justarandomgeek
          -- not sure why i made a loop for setting nil to extras, you just need to generate a setnil for "the rest" there basically
          error()
        end
      end
      -- copy rights to lefts
      for i = numrights,1,-1 do
        local right = firstright + i - 1
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
      local livereg = {
        reg = a,
        name = stat.ref,
      }
      func.liveregs[#func.liveregs+1] = livereg
      -- CLOSURE into that register
      local instr = {
        op = opcodes.closure, a = a, bx = stat.ref.index,
      }
      livereg.startat = instr
      func.instructions[#func.instructions+1] = instr
    end,
    ---@param stat AstFuncStat
    funcstat = function(stat,func)
      local inreg,parent,parent_is_up
      if #stat.names == 1 and stat.names[1].token=="local" then
        -- if name is a local, we can just build the closure in place
        inreg = find_local(stat.names[1].ref,func)
      else
        -- otherwise, we need its parent table and a temporary to fetch it in...
        error()
        inreg = next_reg(func)
      end

      -- CLOSURE into that register
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = inreg, bx = stat.ref.index,
      }

      if parent then
        error()
      elseif parent_is_up then
        error()
      end
    end,
    dostat = function(stat,func)
      local top = func.nextreg
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      release_down_to(func,top)
    end,
    ifstat = function(stat,func)
      for i,ifblock in ipairs(stat.ifs) do
        local top = func.nextreg
        local cond = ifblock.cond
        local condtoken = cond.token

        if false_tokens[condtoken] then
          -- always false, skip this block
          goto nextblock
        elseif const_tokens[condtoken] then
          -- always true, stop after this block

          -- TODO: include table constructors and closures here
          -- maybe function calls of known truthy return types too?
          -- but those still need to eval it if captured to a block local
          error()
        else
          -- generate a value and `test` it...
          generate_test_code(cond)
          error()
        end

        -- generate body
        for j,innerstat in ipairs(ifblock.body) do
          generate_statement_code[innerstat.token](innerstat,func)
        end
        release_down_to(func,top)
        -- jump from end of body to end of blocks (not yet determined, build patchlist)
        -- patch test failure to jump here for next test/else/nextblock
        ::nextblock::
      end
      if stat.elseblock then
        local top = func.nextreg
        for i,innerstat in ipairs(stat.elseblock.body) do
          generate_statement_code[innerstat.token](innerstat,func)
        end
        release_down_to(func,top)
        -- patch if block ends to jump here
      end
    end,
    call = function(stat,func)
      -- evaluate as a call expression for zero results
      local funcreg = next_reg(func)
      generate_expr(stat,funcreg,func,0)
      release_down_to(func,funcreg)
    end,
    selfcall = function(stat,func)
      -- evaluate as a selfcall expression for zero results
      local funcreg = next_reg(func)
      generate_expr(stat,funcreg,func,0)
      release_down_to(func,funcreg)
    end,
    forlist = function(stat,func)
      local top = func.nextreg
      -- alocate forlist internal vars
      local generator = next_reg(func)
      local generator_info = {
        reg = generator,
        name = {token = "internal", value = "(for generator)"},
      }
      func.liveregs[#func.liveregs+1] = generator_info
      local state = next_reg(func)
      local state_info = {
        reg = state,
        name = {token = "internal", value = "(for state)"},
      }
      func.liveregs[#func.liveregs+1] = state_info
      local control = next_reg(func)
      local control_info = {
        reg = control,
        name = {token = "internal", value = "(for control)"},
      }
      func.liveregs[#func.liveregs+1] = control_info
      local innertop = func.nextreg
      -- eval explist for three results starting at generator
      generate_explist(stat.explist,generator,func,3)
      -- jmp to tforcall
      local jmp = {
        op = opcodes.jmp, a = 0, -- a=close upvals?, sbx= jump target
      }
      func.instructions[#func.instructions+1] = jmp
      -- go back and set internals live
      generator_info.startat = jmp
      state_info.startat = jmp
      control_info.startat = jmp
      -- allocate for locals, declare them live
      for i,name in ipairs(stat.namelist) do
        func.liveregs[#func.liveregs+1] = {
          reg = control,
          name = name,
          startat = jmp
        }
      end
      -- generate body
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end

      release_down_to(func,innertop)
      -- loop
      local tforcall = {
        op = opcodes.tforcall, a = generator, c = #stat.namelist, -- a=func, c=num loop vars
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
      local top = func.nextreg
      -- alocate fornum internal vars
      -- eval start/stop/step into internals
      -- allocate for local, declare it live
      -- generate body
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      -- loop

      release_down_to(func,top)
    end,
    whilestat = function(stat,func)
      error()
      local top = func.nextreg
      -- eval stat.cond in a temporary
      -- test, else jump past body+jump
      -- generate body
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      -- jump back

      release_down_to(func,top)
    end,
    repeatstat = function(stat,func)
      error()
      local top = func.nextreg
      -- generate body
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      -- eval stat.cond in a temporary
      -- jump back if false

      release_down_to(func,top)
    end,

    retstat = function(stat,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes["return"], a = 0, b = 1
      }
      -- error() -- TODO
      -- eval explist into temporaries
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
    func.liveregs = {}
    func.nextreg = 0 -- *ZERO BASED* index of next register to use
    func.maxstacksize = 2 -- always at least two registers
    func.instructions = {}

    for i,fproto in ipairs(func.funcprotos) do
      fproto.index = i - 1 -- *ZERO BASED* index
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

    for i,fproto in ipairs(func.funcprotos) do
      generate_code(fproto)
    end

  end
end

return generate_code
