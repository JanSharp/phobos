local invert = require("invert")
local function walk_block(ast,open,close)
  if open then open(ast) end
  if ast.token == "ifstat" then
    for _,if_block in ipairs(ast.ifs) do
      walk_block(if_block,open,close)
    end
    if ast.elseblock then
      walk_block(ast.elseblock,open,close)
    end
  else
    if ast.func_protos then
      for _,func in ipairs(ast.func_protos) do
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
    for _,sub in ipairs(exp.exp_list) do
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
  elseif exp.token == "func_proto" then
    -- no children, only ref
  else
    -- local, upval: no children, only ref
    -- number, boolean, string: no children, only value
  end
  if close then close(exp) end
end

local function fold_exp(parent_exp,tok,value,child_token)
  parent_exp.token = tok
  parent_exp.value = value
  parent_exp.ex = nil        -- call, selfcall
  parent_exp.op = nil        -- binop,unop
  parent_exp.left = nil      -- binop
  parent_exp.right = nil     -- binop
  parent_exp.exp_list = nil   -- concat
  if child_token then
    parent_exp.line = child_token.line
    parent_exp.column = child_token.column
  elseif child_token == false then
    parent_exp.line = nil
    parent_exp.column = nil
  end
  parent_exp.folded = true
end

local is_const_token = invert{"string","number","true","false","nil"}
local fold_unop = {
  ["-"] = function(exp)
    -- number
    if exp.ex.token == "number" then
      fold_exp(exp,"number", -exp.ex.value)
    end
  end,
  ["not"] = function(exp)
    -- boolean
    if exp.ex.token == "boolean" then
      fold_exp(exp, "boolean", not exp.ex.value)
    end
  end,
  ["#"] = function(exp)
    -- table or string
    if exp.ex.token == "string" then
      fold_exp(exp, "string", #exp.ex.value)
    elseif exp.ex.token == "constructor" then

    end
  end,
}
local fold_binop = {
  ["+"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      fold_exp(exp, "number", exp.left.value + exp.right.value)
    end
  end,
  ["-"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      fold_exp(exp, "number", exp.left.value - exp.right.value)
    end
  end,
  ["*"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      fold_exp(exp, "number", exp.left.value * exp.right.value)
    end
  end,
  ["/"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      fold_exp(exp, "number", exp.left.value / exp.right.value)
    end
  end,
  ["%"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      fold_exp(exp, "number", exp.left.value % exp.right.value)
    end
  end,
  ["^"] = function(exp)
    if exp.left.token == "number" and exp.right.token == "number" then
      fold_exp(exp, "number", exp.left.value ^ exp.right.value)
    end
  end,
  ["<"] = function(exp)
    -- matching types, number or string
    if exp.left.token == exp.right.token and
      (exp.left.token == "number" or exp.left.token == "string") then
      local res =  exp.left.value < exp.right.value
      fold_exp(exp, tostring(res), res)
    end
  end,
  ["<="] = function(exp)
    -- matching types, number or string
    if exp.left.token == exp.right.token and
      (exp.left.token == "number" or exp.left.token == "string") then
        local res =  exp.left.value <= exp.right.value
        fold_exp(exp, tostring(res), res)
    end
  end,
  [">"] = function(exp)
    -- matching types, number or string
    if exp.left.token == exp.right.token and
      (exp.left.token == "number" or exp.left.token == "string") then
        local res =  exp.left.value > exp.right.value
        fold_exp(exp, tostring(res), res)
    end
  end,
  [">="] = function(exp)
    -- matching types, number or string
    if exp.left.token == exp.right.token and
      (exp.left.token == "number" or exp.left.token == "string") then
        local res =  exp.left.value >= exp.right.value
        fold_exp(exp, tostring(res), res)
    end
  end,
  ["=="] = function(exp)
    -- any type
    if exp.left.token == exp.right.token and is_const_token[exp.left.token] then
      local res =  exp.left.value == exp.right.value
      fold_exp(exp, tostring(res), res)
    elseif is_const_token[exp.left.token] and is_const_token[exp.right.token] then
      -- different types of constants
      fold_exp(exp, "false", false)
    end
  end,
  ["~="] = function(exp)
    -- any type
    if exp.left.token == exp.right.token and is_const_token[exp.left.token] then
      local res =  exp.left.value ~= exp.right.value
      fold_exp(exp, tostring(res), res)
    elseif is_const_token[exp.left.token] and is_const_token[exp.right.token] then
      -- different types of constants
      fold_exp(exp, "true", true)
    end
  end,
  ["and"] = function(exp)
    -- any type
    if exp.left.token == "nil" or exp.left.token == "false" then
      local sub = exp.left
      fold_exp(exp, sub.token, sub.value, sub)
    elseif is_const_token[exp.left.token] then
      -- the constants that failed the first test are all truthy
      local sub = exp.right
      fold_exp(exp, sub.token, sub.value, sub)
    end
  end,
  ["or"] = function(exp)
    -- any type
    if exp.left.token == "nil" or exp.left.token == "false" then
      local sub = exp.right
      fold_exp(exp, sub.token, sub.value, sub)
    elseif is_const_token[exp.left.token] then
      -- the constants that failed the first test are all truthy
      local sub = exp.left
      fold_exp(exp, sub.token, sub.value, sub)
    end
  end,
}
local function fold_const_exp(exp)
  walk_exp(exp,nil,function(exp)
    if exp.token == "unop" then
      fold_unop[exp.op](exp)
    elseif exp.token == "binop" then
      fold_binop[exp.op](exp)
    elseif exp.token == "concat" then
      -- combine adjacent number or string
      local new_exp_list = {}
      local combining = {}
      local combining_pos
      for _,sub in ipairs(exp.exp_list) do
        if sub.token == "string" or sub.token == "number" then
          if not combining[1] then
            combining_pos = {line = sub.line, column = sub.column}
          end
          combining[#combining+1] = sub.value
        else
          if #combining == 1 then
            new_exp_list[#new_exp_list+1] = {
              token = "string",
              line = combining_pos.line, column = combining_pos.column,
              value = combining[1],
              folded = true
            }
            combining = {}
            combining_pos = nil
          elseif #combining > 1 then
            new_exp_list[#new_exp_list+1] = {
              token = "string",
              line = combining_pos.line, column = combining_pos.column,
              value = table.concat(combining),
              folded = true
            }
            combining = {}
            combining_pos = nil
            exp.folded = true
          end
          new_exp_list[#new_exp_list+1] = sub
        end
      end
      if #combining == 1 then
        new_exp_list[#new_exp_list+1] = {
          token = "string",
          line = combining_pos.line, column = combining_pos.column,
          value = combining[1],
          folded = true
        }
      elseif #combining > 1 then
        new_exp_list[#new_exp_list+1] = {
          token = "string",
          line = combining_pos.line, column = combining_pos.column,
          value = table.concat(combining),
          folded = true
        }
        exp.folded = true
      end

      exp.exp_list = new_exp_list

      if #exp.exp_list == 1 then
        -- fold a single string away entirely, if possible
        local sub = exp.exp_list[1]
        fold_exp(exp,sub.token,sub.value,sub)
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
    if token.condition then -- if,while,repeat
      fold_const_exp(token.condition)
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
    if token.exp_list then -- localstat, return
      for _,exp in ipairs(token.exp_list) do
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