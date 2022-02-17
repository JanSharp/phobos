
local ast_walker = require("ast_walker")
local ill = require("indexed_linked_list")
local ast = require("ast_util")

local remove_func_defs_in_scope
do
  local function delete_func_base_node(node, context)
    -- save the ast walker some unnecessary work
    node.func_def.body = ill.new()
    local func_def = context.parent_func_def
    for i, func_proto in ipairs(func_def.func_protos) do
      if func_proto == node.func_def then
        table.remove(func_def.func_protos, i)
        return
      end
    end
    error("Unable to find node.func_def in func_protos of parent func_def indicating malformed AST. \z
      Every functiondef should be in the func_protos of the parent functiondef"
    )
  end

  local on_open = {
    funcstat = delete_func_base_node,
    localfunc = delete_func_base_node,
    func_proto = delete_func_base_node,
  }

  function remove_func_defs_in_scope(parent_func_def, scope)
    ast_walker.walk_scope(scope, {on_open = on_open, parent_func_def = parent_func_def})
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
  whilestat = function(node, context, _, stat_elem)
    if ast.is_falsy(node.condition) then -- falsy
      local func_def = context.scope
      while func_def.node_type ~= "functiondef" do
        func_def = func_def.parent_scope
      end
      remove_func_defs_in_scope(func_def, node)
      ill.remove(stat_elem) -- remove is the last operation on the ill
    elseif ast.is_const_node(node.condition) then -- truthy
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

  repeatstat = function(node)
    if ast.is_falsy(node.condition) then -- falsy
      convert_repeatstat(node, true)
    elseif ast.is_const_node(node.condition) then -- truthy
      convert_repeatstat(node, false)
    end
  end,

  ifstat = function(node, context, _, stat_elem)
    local func_def = context.scope
    while func_def.node_type ~= "functiondef" do
      func_def = func_def.parent_scope
    end
    local i = 1
    local c = #node.ifs
    while i <= c do
      local testblock = node.ifs[i]
      if ast.is_falsy(testblock.condition) then -- falsy
        remove_func_defs_in_scope(func_def, testblock)
        table.remove(node.ifs, i)
        i = i - 1
        c = c - 1
      elseif ast.is_const_node(testblock.condition) then -- truthy
        for j = #node.ifs, i + 1, -1 do
          remove_func_defs_in_scope(func_def, node.ifs[j])
          node.ifs[j] = nil
        end
        if node.elseblock then
          remove_func_defs_in_scope(func_def, node.elseblock)
          node.elseblock = nil
        end
        -- convert this testblock to a dostat just after this ifstat
        node.ifs[i] = nil
        testblock.node_type = "dostat"
        testblock.condition = nil
        if testblock.if_token then
          testblock.do_token = testblock.if_token
          testblock.do_token.value = "do"
          testblock.if_token = nil
        end
        testblock.then_token = nil
        testblock.end_token = node.end_token
        ill.insert_after(stat_elem, testblock)
        break
      end
      i = i + 1
    end

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
        stat_elem.value = elseblock -- replace
      else
        ill.remove(stat_elem) -- remove is the last operation on the ill
      end
    end
  end,
}

local function fold(main)
  ast_walker.walk_scope(main, {on_open = on_open})
end

return fold
