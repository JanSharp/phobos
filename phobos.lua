local serpent = require("serpent")
----------------------------------------------------------------------
local generate_code
do
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
  end
  local generate_expr_code
  generate_expr_code = {
  }
  local function generate_expr(expr,inreg,func)
    return generate_expr_code[expr.token](expr,inreg,func)
  end
  local generate_statement_code
  generate_statement_code = {
    localstat = function(stat,func)
      -- allocate registers for LHS, eval expressions into them
      -- declare new registers to be "live" with locals after this
    end,
    localfunc = function(stat,func)
      -- allocate register for stat.name
      -- declare new register to be "live" with local right away for upval capture
      -- CLOSURE into that register
    end,
    dostat = function(stat,func)
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      -- close live locals from this block
    end,
    funcstat = function(stat,func)
      -- if name is not local, allocate a temporary
      -- CLOSURE into that register
      -- if name is not local, assign from temporary and release
    end,
    assignment = function(stat,func)
      -- if LHS is locals, check for conflict with RHS and if none use them directly
      -- else allocate temporary registers, eval RHS expressions into them
    end,
    ifstat = function(stat,func)
      for i,ifblock in ipairs(stat.ifs) do
        --generate a test for ifblock.cond

        -- generate body
        for i,innerstat in ipairs(ifblock.body) do
          generate_statement_code[innerstat.token](innerstat,func)
        end
        -- patch test to jump here
      end
      if stat.elseblock then
        for i,innerstat in ipairs(stat.elseblock.body) do
          generate_statement_code[innerstat.token](innerstat,func)
        end
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
      -- alocate forlist internal vars
      -- eval explist for three results
      -- allocate for locals, declare them live
      -- generate body
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      -- loop
    end,
    fornum = function(stat,func)
      -- alocate fornum internal vars
      -- eval start/stop/step into internals
      -- allocate for local, declare it live
      -- generate body
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      -- loop
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
    whilestat = function(stat,func)
      -- jump past body to test
      -- generate body
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      -- eval stat.cond in a temporary
      -- jump back if true
    end,
    repeatstat = function(stat,func)
      -- generate body
      for i,innerstat in ipairs(stat.body) do
        generate_statement_code[innerstat.token](innerstat,func)
      end
      -- eval stat.cond in a temporary
      -- jump back if false
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
