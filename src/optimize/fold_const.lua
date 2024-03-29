
local ast_walker = require("ast_walker")
local ast = require("ast_util")

local clear_exp_field_lut = {
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
    exp.src_ex_did_not_exist = nil
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
  exp.concat_src_paren_wrappers = nil
  exp.force_single_result = nil -- we only output constant nodes where this never matters
  clear_exp_field_lut[exp.node_type](exp)
end

---only for constant `node_type`s
local function fold_exp(parent_exp,node_type,position,value)
  assert(ast.is_const_node_type(node_type))
  clear_exp_fields(parent_exp)
  parent_exp.node_type = node_type
  parent_exp.value = value
  parent_exp.line = position.line
  parent_exp.column = position.column
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

local fold_unop = {
  ["-"] = function(exp)
    -- number
    if exp.ex.node_type == "number" then
      fold_exp(exp, "number", exp.op_token, -exp.ex.value)
    end
  end,
  ["not"] = function(exp)
    -- boolean
    if ast.is_const_node(exp.ex) then
      fold_exp(exp, "boolean", exp.op_token, ast.is_falsy(exp.ex))
    end
  end,
  ["#"] = function(exp)
    -- table or string
    if exp.ex.node_type == "string" then
      fold_exp(exp, "number", exp.op_token, #exp.ex.value)
    elseif exp.ex.node_type == "constructor" then

    end
  end,
}

local fold_binop = {
  ["+"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left, exp.left.value + exp.right.value)
    end
  end,
  ["-"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left, exp.left.value - exp.right.value)
    end
  end,
  ["*"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left, exp.left.value * exp.right.value)
    end
  end,
  ["/"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left, exp.left.value / exp.right.value)
    end
  end,
  ["%"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left, exp.left.value % exp.right.value)
    end
  end,
  ["^"] = function(exp)
    if exp.left.node_type == "number" and exp.right.node_type == "number" then
      fold_exp(exp, "number", exp.left, exp.left.value ^ exp.right.value)
    end
  end,
  ["<"] = function(exp)
    -- matching types, number or string
    if exp.left.node_type == exp.right.node_type and
      (exp.left.node_type == "number" or exp.left.node_type == "string") then
      local res =  exp.left.value < exp.right.value
      fold_exp(exp, "boolean", exp.left, res)
    end
  end,
  ["<="] = function(exp)
    -- matching types, number or string
    if exp.left.node_type == exp.right.node_type and
      (exp.left.node_type == "number" or exp.left.node_type == "string") then
        local res =  exp.left.value <= exp.right.value
        fold_exp(exp, "boolean", exp.left, res)
    end
  end,
  [">"] = function(exp)
    -- matching types, number or string
    if exp.left.node_type == exp.right.node_type and
      (exp.left.node_type == "number" or exp.left.node_type == "string") then
        local res =  exp.left.value > exp.right.value
        fold_exp(exp, "boolean", exp.left, res)
    end
  end,
  [">="] = function(exp)
    -- matching types, number or string
    if exp.left.node_type == exp.right.node_type and
      (exp.left.node_type == "number" or exp.left.node_type == "string") then
        local res =  exp.left.value >= exp.right.value
        fold_exp(exp, "boolean", exp.left, res)
    end
  end,
  ["=="] = function(exp)
    -- any type
    if exp.left.node_type == exp.right.node_type and ast.is_const_node(exp.left) then
      local res = exp.left.value == exp.right.value
      fold_exp(exp, "boolean", exp.left, res)
    elseif ast.is_const_node(exp.left) and ast.is_const_node(exp.right) then
      -- different types of constants
      fold_exp(exp, "boolean", exp.left, false)
    end
  end,
  ["~="] = function(exp)
    -- any type
    if exp.left.node_type == exp.right.node_type and ast.is_const_node(exp.left) then
      local res = exp.left.value ~= exp.right.value
      fold_exp(exp, "boolean", exp.left, res)
    elseif ast.is_const_node(exp.left) and ast.is_const_node(exp.right) then
      -- different types of constants
      fold_exp(exp, "boolean", exp.left, true)
    end
  end,
  ["and"] = function(exp)
    -- any type
    if ast.is_falsy(exp.left) then
      fold_exp_merge(exp, exp.left)
    elseif ast.is_const_node(exp.left) then
      -- the constants that failed the first test are all truthy
      fold_exp_merge(exp, exp.right)
    end
  end,
  ["or"] = function(exp)
    -- any type
    if ast.is_falsy(exp.left) then
      fold_exp_merge(exp, exp.right)
    elseif ast.is_const_node(exp.left) then
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
  ---@param node AstConcat
  concat = function(node)
    -- combine adjacent number or string
    local new_exp_list = {}
    local combining = {} ---@type (string|number)[]
    local combining_pos ---@type Position
    for _,sub in ipairs(node.exp_list) do
      if sub.node_type == "string" or sub.node_type == "number" then
        ---@cast sub AstString|AstNumber
        if not combining[1] then
          combining_pos = {line = sub.line, column = sub.column}
        end
        combining[#combining+1] = sub.value
      else
        if #combining == 1 then
          new_exp_list[#new_exp_list+1] = {
            node_type = "string",
            line = combining_pos.line, column = combining_pos.column,
            value = tostring(combining[1]),
            folded = true,
          }
          combining = {}
        elseif #combining > 1 then
          new_exp_list[#new_exp_list+1] = {
            node_type = "string",
            line = combining_pos.line, column = combining_pos.column,
            value = table.concat(combining),
            folded = true,
          }
          combining = {}
          node.folded = true
        end
        new_exp_list[#new_exp_list+1] = sub
      end
    end
    if #combining == 1 then
      new_exp_list[#new_exp_list+1] = {
        node_type = "string",
        line = combining_pos.line, column = combining_pos.column,
        value = tostring(combining[1]),
        folded = true,
      }
    elseif #combining > 1 then
      new_exp_list[#new_exp_list+1] = {
        node_type = "string",
        line = combining_pos.line, column = combining_pos.column,
        value = table.concat(combining),
        folded = true,
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

---@param main AstMain
---@param options Options?
local function fold_const(main, options)
  if options and options.use_int32 then
    error("Constant folding is not supported when using int32 because accurately emulating an int32 machine is difficult.")
  end
  ast_walker.walk_scope(main, ast_walker.new_context(nil, on_close))
end

return fold_const
