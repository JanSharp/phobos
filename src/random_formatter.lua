
local ast_walker = require("ast_walker")

local function rand_leading(leading)
  if not leading[1] then
    leading[1] = {token_type = "blank", value = ""}
  end
  local need_newline = false
  for _, token in ipairs(leading) do
    if token.token_type == "blank" then
      token.value = ((need_newline or (math.random() < 0.15)) and "\n" or "")
        ..string.rep(" ", math.random(0, 5))
      -- token.value = need_newline and "\n" or ""
      need_newline = false
    elseif not token.src_is_block_str then -- not blank? it's a comment
      need_newline = true
    end
  end
end

local function rand_node(token)
  if token then
    rand_leading(token.leading)
  end
end

local function rand_nodes(tokens)
  if tokens then
    for _, token in ipairs(tokens) do
      rand_node(token)
    end
  end
end

local function functiondef(node)
  rand_nodes(node.param_comma_tokens)
  rand_node(node.open_paren_token)
  rand_node(node.close_paren_token)
  rand_node(node.function_token)
  rand_node(node.end_token)
  rand_node(node.eof_token)
end

local on_open = {
  ["empty"] = function(node)
    rand_node(node.semi_colon_token)
  end,
  ["ifstat"] = function(node)
    rand_node(node.end_token)
  end,
  ["testblock"] = function(node)
    rand_node(node.if_token)
    rand_node(node.then_token)
  end,
  ["elseblock"] = function(node)
    rand_node(node.else_token)
  end,
  ["whilestat"] = function(node)
    rand_node(node.while_token)
    rand_node(node.do_token)
    rand_node(node.end_token)
  end,
  ["dostat"] = function(node)
    rand_node(node.do_token)
    rand_node(node.end_token)
  end,
  ["fornum"] = function(node)
    rand_node(node.for_token)
    rand_node(node.eq_token)
    rand_node(node.first_comma_token)
    rand_node(node.second_comma_token)
    rand_node(node.do_token)
    rand_node(node.end_token)
  end,
  ["forlist"] = function(node)
    rand_node(node.for_token)
    rand_nodes(node.comma_tokens)
    rand_node(node.in_token)
    rand_node(node.do_token)
    rand_node(node.end_token)
  end,
  ["repeatstat"] = function(node)
    rand_node(node.repeat_token)
    rand_node(node.until_token)
  end,
  ["funcstat"] = function(node)
    functiondef(node.func_def)
  end,
  ["localstat"] = function(node)
    rand_node(node.local_token)
    rand_nodes(node.lhs_comma_tokens)
    rand_nodes(node.rhs_comma_tokens)
    rand_node(node.eq_token)
  end,
  ["localfunc"] = function(node)
    rand_node(node.local_token)
    functiondef(node.func_def)
  end,
  ["label"] = function(node)
    rand_node(node.name_token)
    rand_node(node.open_token)
    rand_node(node.close_token)
  end,
  ["retstat"] = function(node)
    rand_node(node.return_token)
    rand_nodes(node.exp_list_comma_tokens)
    rand_node(node.semi_colon_token)
  end,
  ["breakstat"] = function(node)
    rand_node(node.break_token)
  end,
  ["gotostat"] = function(node)
    rand_node(node.goto_token)
    rand_node(node.target_token)
  end,
  ["call"] = function(node)
    rand_nodes(node.args_comma_tokens)
    rand_node(node.colon_token)
    rand_node(node.open_paren_token)
    rand_node(node.close_paren_token)
  end,
  ["assignment"] = function(node)
    rand_nodes(node.lhs_comma_tokens)
    rand_node(node.eq_token)
    rand_nodes(node.rhs_comma_tokens)
  end,

  ["local_ref"] = function(node)
    rand_node(node)
  end,
  ["upval_ref"] = function(node)
    rand_node(node)
  end,
  ["index"] = function(node)
    rand_node(node.dot_token)
    rand_node(node.suffix_open_token)
    rand_node(node.suffix_close_token)
  end,
  ["unop"] = function(node)
    rand_node(node.op_token)
  end,
  ["binop"] = function(node)
    rand_node(node.op_token)
  end,
  ["concat"] = function(node)
    rand_nodes(node.op_tokens)
  end,
  ["number"] = function(node)
    rand_node(node)
  end,
  ["string"] = function(node)
    rand_node(node)
  end,
  ["nil"] = function(node)
    rand_node(node)
  end,
  ["boolean"] = function(node)
    rand_node(node)
  end,
  ["vararg"] = function(node)
    rand_node(node)
  end,
  ["func_proto"] = function(node)
    functiondef(node.func_def)
  end,
  ["constructor"] = function(node)
    for _, field in ipairs(node.fields) do
      if field.type == "rec" then
        rand_node(field.key_open_token)
        rand_node(field.key_close_token)
        rand_node(field.eq_token)
      end
    end
    rand_node(node.open_token)
    rand_nodes(node.comma_tokens)
    rand_node(node.close_token)
  end,
}

return function(main)
  ast_walker.walk_scope(main, {on_open = on_open})
end
