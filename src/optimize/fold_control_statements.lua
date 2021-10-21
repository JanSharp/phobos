
local ast_walker = require("ast_walker")
local util = require("util")

local function check_delete_func_base_node(node, scope)
  local func_def = scope
  local to_delete = func_def.to_delete
  while func_def.node_type ~= "functiondef" do
    func_def = func_def.parent_scope
    to_delete = to_delete or func_def.to_delete
  end
  if to_delete then
    for i, func_proto in ipairs(func_def.func_protos) do
      if func_proto == node.func_def then
        table.remove(func_def.func_protos, i)
        goto removed
      end
    end
    assert(false, "Unable to find node.func_def in func_protos of parent func_def")
    ::removed::
    -- just to save the ast walker some unnecessary work
    node.func_def.body = {}
  end
end

local function convert_repeatstat(node, do_jump_back)
  node.node_type = "loopstat"
  node.do_jump_back = do_jump_back
  node.open_token = node.repeat_token
  node.repeat_token = nil
  node.close_token = node.until_token
  node.until_token = nil
  node.condition = nil
end

local on_open = {
  whilestat = function(node, scope)
    if util.is_falsy(node.condition) then -- falsy
      node.to_delete = true
    elseif util.is_const_node(node.condition) then -- truthy
      node.node_type = "loopstat"
      node.do_jump_back = true
      node.open_token = node.while_token
      node.while_token = nil
      node.condition = nil
      node.do_token = nil
      node.close_token = node.end_token
      node.end_token = nil
    end
  end,

  repeatstat = function(node, scope)
    if util.is_falsy(node.condition) then -- falsy
      convert_repeatstat(node, true)
    elseif util.is_const_node(node.condition) then -- truthy
      convert_repeatstat(node, false)
    end
  end,

  ifstat = function(node, scope)
    -- local func_def = scope
    -- while func_def.node_type ~= "functiondef" do
    --   func_def = func_def.parent_scope
    -- end
    for i, testblock in ipairs(node.ifs) do
      if util.is_falsy(testblock.condition) then -- falsy
        testblock.to_delete = true
      elseif util.is_const_node(testblock.condition) then -- truthy
        for j = i + 1, #node.ifs do
          node.ifs[j].to_delete = true
        end
        if node.elseblock then
          node.elseblock.to_delete = true
        end
        table.remove(node.ifs, i)
        testblock.node_type = "dostat"
        testblock.condition = nil
        if testblock.if_token then
          testblock.do_token = testblock.if_token
          testblock.do_token.value = "do"
          testblock.if_token = nil
        end
        testblock.then_token = nil
        testblock.end_token = node.end_token
        node.insert_after = {testblock}
        break
      end
    end
  end,

  funcstat = check_delete_func_base_node,
  localfunc = check_delete_func_base_node,
  func_proto = check_delete_func_base_node,
}

local on_close = {
  ifstat = function(node, scope)
    if not node.ifs[1] then
      if node.elseblock then
        local elseblock = node.elseblock
        elseblock.node_type = "dostat"
        if elseblock.else_token then
          elseblock.do_token = elseblock.else_token
          elseblock.do_token.value = "do"
          elseblock.else_token = nil
        end
        elseblock.end_token = node.end_token

        node.replace_with = elseblock
      else
        node.replace_with = {node_type = "empty"}
      end
    end
  end,
}

local function fold(main)
  ast_walker(main, on_open, on_close)
end

return fold
