
local walker = require("ast_walker")
local invert = require("invert")

local clear_exp_field_lut = {
  ["selfcall"] = function(exp)
    exp.ex = nil
    exp.suffix = nil
    exp.args = nil
    exp.args_comma_tokens = nil
    exp.colon_token = nil
    exp.open_paren_token = nil
    exp.close_paren_token = nil
  end,
  ["call"] = function(exp)
    exp.ex = nil
    exp.args = nil
    exp.args_comma_tokens = nil
    exp.open_paren_token = nil
    exp.close_paren_token = nil
  end,
  ["local_ref"] = function(exp)
    exp.name = nil
    exp.reference_def = nil
  end,
  ["upval_ref"] = function(exp)
    exp.name = nil
    exp.reference_def = nil
  end,
  ["index"] = function(exp)
    exp.ex = nil
    exp.suffix = nil
    exp.dot_token = nil
    exp.suffix_open_token = nil
    exp.suffix_close_token = nil
    exp.scr_ex_did_not_exist = nil
  end,
  ["string"] = function(exp)
    exp.value = nil
    exp.src_is_ident = nil
    exp.src_is_block_str = nil
    exp.src_quote = nil
    exp.src_value = nil
    exp.src_has_leading_newline = nil
    exp.src_pad = nil
  end,
  ["ident"] = function(exp)
    exp.value = nil
  end,
  ["unop"] = function(exp)
    exp.op = nil
    exp.ex = nil
    exp.op_token = nil
  end,
  ["binop"] = function(exp)
    exp.op = nil
    exp.left = nil
    exp.right = nil
    exp.op_token = nil
  end,
  ["concat"] = function(exp)
    exp.exp_list = nil
    exp.op_tokens = nil
  end,
  ["number"] = function(exp)
    exp.value = nil
    exp.src_value = nil
  end,
  ["nil"] = function(exp)
  end,
  ["boolean"] = function(exp)
    exp.value = nil
  end,
  ["vararg"] = function(exp)
  end,
  ["func_proto"] = function(exp)
    exp.func_def = nil
  end,
  ["constructor"] = function(exp)
    exp.fields = nil
    exp.open_token = nil
    exp.comma_tokens = nil
    exp.close_token = nil
  end,
}

local function clear_exp_fields(exp)
  -- fields every expression have
  exp.src_paren_wrappers = nil
  -- TODO: how to deal with force_single_result when folding expression?
  clear_exp_field_lut[exp.node_type](exp)
end

local is_const_node = invert{"string","number","boolean","nil"}
---only for constant `node_type`s
local function fold_exp(parent_exp,node_type,value)
  assert(is_const_node[node_type])
  clear_exp_fields(parent_exp)
  parent_exp.node_type = node_type
  parent_exp.value = value
  parent_exp.folded = true
end

---parent_exp becomes child_node, but keeping `parent_exp`'s table
local function fold_exp_merge(parent_exp, child_node)
  clear_exp_fields(parent_exp)
  for k, v in pairs(child_node) do
    parent_exp[k] = v
  end
  parent_exp.folded = true
end

local function is_falsy(node)
  return node.node_type == "nil" or (node.node_type == "boolean" and node.value == false)
end

local fold_unop = {
  ["-"] = function(exp)
    -- number
    if exp.ex.node_type == "number" then
      fold_exp(exp,"number", -exp.ex.value)
    end
  end,
  ["not"] = function(exp)
    -- boolean
    if is_const_node[exp.ex.node_type] then
      fold_exp(exp, "boolean", not not is_falsy(exp.ex)) -- not not just to make sure it's a boolean value
    end
  end,
  ["#"] = function(exp)
    -- table or string
    if exp.ex.node_type == "string" then
      fold_exp(exp, "number", #exp.ex.value)
    elseif exp.ex.node_type == "constructor" then

    end
  end,
}

local fold_binop = {
  ["+"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left.value + exp.right.value)
    end
  end,
  ["-"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left.value - exp.right.value)
    end
  end,
  ["*"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left.value * exp.right.value)
    end
  end,
  ["/"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left.value / exp.right.value)
    end
  end,
  ["%"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left.value % exp.right.value)
    end
  end,
  ["^"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left.value ^ exp.right.value)
    end
  end,
  ["<"] = function(exp)
    -- matching types, number or string
    if exp.left.node_type == exp.right.node_type and
      (exp.left.node_type == "number" or exp.left.node_type == "string") then
      local res =  exp.left.value < exp.right.value
      fold_exp(exp, "boolean", res)
    end
  end,
  ["<="] = function(exp)
    -- matching types, number or string
    if exp.left.node_type == exp.right.node_type and
      (exp.left.node_type == "number" or exp.left.node_type == "string") then
        local res =  exp.left.value <= exp.right.value
        fold_exp(exp, "boolean", res)
    end
  end,
  [">"] = function(exp)
    -- matching types, number or string
    if exp.left.node_type == exp.right.node_type and
      (exp.left.node_type == "number" or exp.left.node_type == "string") then
        local res =  exp.left.value > exp.right.value
        fold_exp(exp, "boolean", res)
    end
  end,
  [">="] = function(exp)
    -- matching types, number or string
    if exp.left.node_type == exp.right.node_type and
      (exp.left.node_type == "number" or exp.left.node_type == "string") then
        local res =  exp.left.value >= exp.right.value
        fold_exp(exp, "boolean", res)
    end
  end,
  ["=="] = function(exp)
    -- any type
    if exp.left.node_type == exp.right.node_type and is_const_node[exp.left.node_type] then
      local res =  exp.left.value == exp.right.value
      fold_exp(exp, tostring(res), res)
    elseif is_const_node[exp.left.node_type] and is_const_node[exp.right.node_type] then
      -- different types of constants
      fold_exp(exp, "boolean", false)
    end
  end,
  ["~="] = function(exp)
    -- any type
    if exp.left.node_type == exp.right.node_type and is_const_node[exp.left.node_type] then
      local res =  exp.left.value ~= exp.right.value
      fold_exp(exp, tostring(res), res)
    elseif is_const_node[exp.left.node_type] and is_const_node[exp.right.node_type] then
      -- different types of constants
      fold_exp(exp, "boolean", true)
    end
  end,
  ["and"] = function(exp)
    -- any type
    if is_falsy(exp.left) then
      fold_exp_merge(exp, exp.left)
    elseif is_const_node[exp.left.node_type] then
      -- the constants that failed the first test are all truthy
      fold_exp_merge(exp, exp.right)
    end
  end,
  ["or"] = function(exp)
    -- any type
    if is_falsy(exp.left) then
      fold_exp_merge(exp, exp.right)
    elseif is_const_node[exp.left.node_type] then
      -- the constants that failed the first test are all truthy
      fold_exp_merge(exp, exp.left)
    end
  end,
}

local on_close = {
  unop = function(node)
    fold_unop[node.op](node)
  end,
  binop = function(node)
    fold_binop[node.op](node)
  end,
  concat = function(node)
    -- combine adjacent number or string
    local new_exp_list = {}
    local combining = {}
    local combining_pos
    for _,sub in ipairs(node.exp_list) do
      if sub.node_type == "string" or sub.node_type == "number" then
        if not combining[1] then
          combining_pos = {line = sub.line, column = sub.column}
        end
        combining[#combining+1] = sub.value
      else
        if #combining == 1 then
          new_exp_list[#new_exp_list+1] = {
            node_type = "string",
            line = combining_pos.line, column = combining_pos.column,
            value = combining[1],
            folded = true
          }
          combining = {}
          combining_pos = nil
        elseif #combining > 1 then
          new_exp_list[#new_exp_list+1] = {
            node_type = "string",
            line = combining_pos.line, column = combining_pos.column,
            value = table.concat(combining),
            folded = true
          }
          combining = {}
          combining_pos = nil
          node.folded = true
        end
        new_exp_list[#new_exp_list+1] = sub
      end
    end
    if #combining == 1 then
      new_exp_list[#new_exp_list+1] = {
        node_type = "string",
        line = combining_pos.line, column = combining_pos.column,
        value = combining[1],
        folded = true
      }
    elseif #combining > 1 then
      new_exp_list[#new_exp_list+1] = {
        node_type = "string",
        line = combining_pos.line, column = combining_pos.column,
        value = table.concat(combining),
        folded = true
      }
      node.folded = true
    end

    node.exp_list = new_exp_list

    if #node.exp_list == 1 then
      -- fold a single string away entirely, if possible
      fold_exp_merge(node, node.exp_list[1])
    end
  end,
  -- anything else?
  -- indexing of known-const tables?
  -- calling of specific known-identity, known-const functions?
}

local function fold_const(main)
  walker(main, nil, on_close)
end

return fold_const
