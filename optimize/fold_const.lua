local invert = require("invert")
local function walk_block(ast,open,close)
  if open then open(ast) end
  if ast.token == "ifstat" then
    for _,ifblock in ipairs(ast.ifs) do
      walk_block(ifblock,open,close)
    end
    if ast.elseblock then
      walk_block(ast.elseblock,open,close)
    end
  else
    if ast.funcprotos then
      for _,func in ipairs(ast.funcprotos) do
        walk_block(func,open,close)
      end
    end
    if ast.body then
      for _,stat in ipairs(ast.body) do
        walk_block(stat,open,close)
      end
    end
  end
  if close then close(ast) end
end

local function walk_exp(exp,open,close)
  if open then open(exp) end
  if exp.token == "unop" then
    walk_exp(exp.ex,open,close)
  elseif exp.token == "binop" then
    walk_exp(exp.left,open,close)
    walk_exp(exp.right,open,close)
  elseif exp.token == "concat" then
    for _,sub in ipairs(exp.explist) do
      walk_exp(sub,open,close)
    end
  elseif exp.token == "index" then
    walk_exp(exp.ex,open,close)
    walk_exp(exp.suffix,open,close)
  elseif exp.token == "call" then
    walk_exp(exp.ex,open,close)
    for _,sub in ipairs(exp.args) do
      walk_exp(sub,open,close)
    end
  elseif exp.token == "selfcall" then
    walk_exp(exp.ex,open,close)
    walk_exp(exp.suffix,open,close)
    for _,sub in ipairs(exp.args) do
      walk_exp(sub,open,close)
    end
  elseif exp.token == "funcproto" then
    -- no children, only ref
  else
    -- local, upval: no children, only ref
    -- number, boolean, string: no children, only value
  end
  if close then close(exp) end
end

local function foldexp(parentexp,tok,value,childtok)
  parentexp.token = tok
  parentexp.value = value
  parentexp.ex = nil        -- call, selfcall
  parentexp.op = nil        -- binop,unop
  parentexp.left = nil      -- binop
  parentexp.right = nil     -- binop
  parentexp.explist = nil   -- concat
  if childtok then
    parentexp.line = childtok.line
    parentexp.column = childtok.column
  elseif childtok == false then
    parentexp.line = nil
    parentexp.column = nil
  end
  parentexp.folded = true
end

local isconsttoken = invert{"string","number","true","false","nil"}
local foldunop = {
  ["-"] = function(exp)
    -- number
    if exp.ex.token == "number" then
      foldexp(exp,"number", -exp.ex.value)
    end
  end,
  ["not"] = function(exp)
    -- boolean
    if exp.ex.token == "boolean" then
      foldexp(exp, "boolean", not exp.ex.value)
    end
  end,
  ["#"] = function(exp)
    -- table or string
    if exp.ex.token == "string" then
      foldexp(exp, "string", #exp.ex.value)
    elseif exp.ex.token == "constructor" then

    end
  end,
}
local foldbinop = {
  ["+"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      foldexp(exp, "number", exp.left.value + exp.right.value)
    end
  end,
  ["-"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      foldexp(exp, "number", exp.left.value - exp.right.value)
    end
  end,
  ["*"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      foldexp(exp, "number", exp.left.value * exp.right.value)
    end
  end,
  ["/"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      foldexp(exp, "number", exp.left.value / exp.right.value)
    end
  end,
  ["%"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      foldexp(exp, "number", exp.left.value % exp.right.value)
    end
  end,
  ["^"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      foldexp(exp, "number", exp.left.value ^ exp.right.value)
    end
  end,
  ["<"] = function(exp)
    -- matching types, number or string
    if exp.left.token == exp.right.token and
      (exp.left.token == "number" or exp.left.token == "string") then
      local res =  exp.left.value < exp.right.value
      foldexp(exp, tostring(res), res)
    end
  end,
  ["<="] = function(exp)
    -- matching types, number or string
    if exp.left.token == exp.right.token and
      (exp.left.token == "number" or exp.left.token == "string") then
        local res =  exp.left.value <= exp.right.value
        foldexp(exp, tostring(res), res)
    end
  end,
  [">"] = function(exp)
    -- matching types, number or string
    if exp.left.token == exp.right.token and
      (exp.left.token == "number" or exp.left.token == "string") then
        local res =  exp.left.value > exp.right.value
        foldexp(exp, tostring(res), res)
    end
  end,
  [">="] = function(exp)
    -- matching types, number or string
    if exp.left.token == exp.right.token and
      (exp.left.token == "number" or exp.left.token == "string") then
        local res =  exp.left.value >= exp.right.value
        foldexp(exp, tostring(res), res)
    end
  end,
  ["=="] = function(exp)
    -- any type
    if exp.left.token == exp.right.token and isconsttoken[exp.left.token] then
      local res =  exp.left.value == exp.right.value
      foldexp(exp, tostring(res), res)
    elseif isconsttoken[exp.left.token] and isconsttoken[exp.right.token] then
      -- different types of constants
      foldexp(exp, "false", false)
    end
  end,
  ["~="] = function(exp)
    -- any type
    if exp.left.token == exp.right.token and isconsttoken[exp.left.token] then
      local res =  exp.left.value ~= exp.right.value
      foldexp(exp, tostring(res), res)
    elseif isconsttoken[exp.left.token] and isconsttoken[exp.right.token] then
      -- different types of constants
      foldexp(exp, "true", true)
    end
  end,
  ["and"] = function(exp)
    -- any type
    if exp.left.token == "nil" or exp.left.token == "false" then
      local sub = exp.left
      foldexp(exp, sub.token, sub.value, sub)
    elseif isconsttoken[exp.left.token] then
      -- the constants that failed the first test are all truthy
      local sub = exp.right
      foldexp(exp, sub.token, sub.value, sub)
    end
  end,
  ["or"] = function(exp)
    -- any type
    if exp.left.token == "nil" or exp.left.token == "false" then
      local sub = exp.right
      foldexp(exp, sub.token, sub.value, sub)
    elseif isconsttoken[exp.left.token] then
      -- the constants that failed the first test are all truthy
      local sub = exp.left
      foldexp(exp, sub.token, sub.value, sub)
    end
  end,
}
local function fold_const_exp(exp)
  walk_exp(exp,nil,function(exp)
    if exp.token == "unop" then
      foldunop[exp.op](exp)
    elseif exp.token == "binop" then
      foldbinop[exp.op](exp)
    elseif exp.token == "concat" then
      -- combine adjacent number or string
      local newexplist = {}
      local combining = {}
      local combiningpos
      for _,sub in ipairs(exp.explist) do
        if sub.token == "string" or sub.token == "number" then
          if not combining[1] then
            combiningpos = {line = sub.line, column = sub.column}
          end
          combining[#combining+1] = sub.value
        else
          if #combining == 1 then
            newexplist[#newexplist+1] = {
              token = "string",
              line = combiningpos.line, column = combiningpos.column,
              value = combining[1],
              folded = true
            }
            combining = {}
            combiningpos = nil
          elseif #combining > 1 then
            newexplist[#newexplist+1] = {
              token = "string",
              line = combiningpos.line, column = combiningpos.column,
              value = table.concat(combining),
              folded = true
            }
            combining = {}
            combiningpos = nil
            exp.folded = true
          end
          newexplist[#newexplist+1] = sub
        end
      end
      if #combining == 1 then
        newexplist[#newexplist+1] = {
          token = "string",
          line = combiningpos.line, column = combiningpos.column,
          value = combining[1],
          folded = true
        }
      elseif #combining > 1 then
        newexplist[#newexplist+1] = {
          token = "string",
          line = combiningpos.line, column = combiningpos.column,
          value = table.concat(combining),
          folded = true
        }
        exp.folded = true
      end

      exp.explist = newexplist

      if #exp.explist == 1 then
        -- fold a single string away entirely, if possible
        local sub = exp.explist[1]
        foldexp(exp,sub.token,sub.value,sub)
      end
    else
      -- anything else?
      -- indexing of known-const tables?
      -- calling of specific known-identity, known-const functions?
    end
  end)
end

local function fold_const(main)
  walk_block(main, nil,
  function(token)
    if token.cond then -- if,while,repeat
      fold_const_exp(token.cond)
    end
    if token.ex then -- call, selfcall
      fold_const_exp(token.ex)
    end
    if token.suffix then -- selfcall
      fold_const_exp(token.suffix)
    end
    if token.args then -- call, selfcall
      for _,exp in ipairs(token.args) do
        fold_const_exp(exp)
      end
    end
    if token.explist then -- localstat, return
      for _,exp in ipairs(token.explist) do
        fold_const_exp(exp)
      end
    end
    if token.lhs then -- assignment
      for _,exp in ipairs(token.lhs) do
        fold_const_exp(exp)
      end
    end
    if token.rhs then -- assignment
      for _,exp in ipairs(token.rhs) do
        fold_const_exp(exp)
      end
    end
  end)
end


return fold_const