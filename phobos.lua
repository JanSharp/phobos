local serpent = require("serpent")
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
    func.nextreg = reg
    -- if it had a live local in it, end it here
  end
  local function release_down_to(func,reg)
    if reg >= func.nextreg - 1 then
      error("Attempted to release registers down to "..reg.." when top was "..func.nextreg)
    end
    func.nextreg = reg
    -- if any had live locals, end them here
  end

  local generate_expr_code
  local function generate_expr(expr,inreg,func)
    return generate_expr_code[expr.token](expr,inreg,func)
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
  local function local_or_fetch(expr,inreg,func)
    if expr.token == "local" then
      -- find it in liveregs and use that...
      error()
    else
      generate_expr(expr.ex,inreg,func)
      return inreg
    end
  end
  local const_tokens = invert{"true","false","nil","string","number"}
  local function const_or_local_or_fetch(expr,inreg,func)
    if const_tokens[expr.token] then
      return bit32.bor(add_constant(expr.value,func),0x10)
    else
      return local_or_fetch(expr,inreg,func)
    end
  end
  local function upval_or_local_or_fetch(expr,inreg,func)
    if expr.token == "upval" then
      -- find it in upvals...
      error()
    else
      return local_or_fetch(expr,inreg,func),false
    end
  end
  generate_expr_code = {
    ["local"] = function(expr,inreg,func)
      func.instructions[#func.instructions+1] = {
        op = opcodes.move, a = inreg, b = -1,
      }
    end,
    upval = function(expr,inreg,func)
      -- getupval
      func.instructions[#func.instructions+1] = {
        op = opcodes.getupval, a = inreg, b = -1,
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
    end,
    functiondef = function(expr,inreg,func)
    end,
    vararg = function(expr,inreg,func,numresults)
    end,
    call = function(expr,inreg,func,numresults)
    end,
    selfcall = function(expr,inreg,func,numresults)
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
  local generate_statement_code
  generate_statement_code = {
    localstat = function(stat,func)
      -- allocate registers for LHS, eval expressions into them

      -- declare new registers to be "live" with locals after this
    end,
    assignment = function(stat,func)
      -- if LHS is locals, check for conflict with RHS and if none use them directly
      -- else fetch parent table and allocate temporary registers, eval RHS expressions into them
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
    funcstat = function(stat,func)
      -- if name is not local, allocate a temporary
      local a = next_reg(func)
      -- CLOSURE into that register
      func.instructions[#func.instructions+1] = {
        op = opcodes.closure, a = a, bx = stat.ref.index,
      }
      -- if name is not local, assign from temporary and release
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
        --generate a test for ifblock.cond
        -- skip obviously-false, stop at obviously-true

        -- generate body
        for j,innerstat in ipairs(ifblock.body) do
          generate_statement_code[innerstat.token](innerstat,func)
        end
        release_down_to(func,top)
        -- patch test to jump here
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

      -- fetch stat.ex into a temporary
      -- fetch stat.args into temporaries
      -- CALL for zero results
    end,
    selfcall = function(stat,func)
      -- evaluate as a selfcall expression for zero results
      
      -- fetch stat.ex into a temporary
      -- SELF temporary:suffix
      -- fetch stat.args into temporaries
      -- CALL for zero results
    end,
    forlist = function(stat,func)
      local top = func.nextreg
      -- alocate forlist internal vars
      -- eval explist for three results
      -- allocate for locals, declare them live
      -- generate body
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      -- loop
      
      release_down_to(func,top)
    end,
    fornum = function(stat,func)
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
      -- eval explist into temporaries
      -- RETURN them
    end,

    label = function(stat,func)
      -- record PC for label
      -- check for pending jump and patch to jump here
    end,
    gotostat = function(stat,func)
      -- match to jump-back label, or set as pending jump
    end,
    breakstat = function(stat,func)
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

    for i,fproto in ipairs(func.funcprotos) do
      generate_code(fproto)
    end

  end
end
----------------------------------------------------------------------
local filename = ... or "phobos.lua"
local file = io.open(filename,"r")
local text = file:read("*a")
file:close()

local main = require("parser")(text,"@" .. filename)

require("optimize.fold_const")(main)

generate_code(main)

print(serpent.dump(main,{indent = '  ', sparse = true, sortkeys = false, comment=true}))

--foo
