
local ast = require("ast_util")

local test_source = "=(test)"

local function append_stat(scope, stat)
  ast.append_stat(scope, function(stat_elem)
    return stat
  end)
end

local function wrap_nodes_constructors(nodes, stat_elem)
  local wrapped_nodes = {}
  for name, func in pairs(nodes) do
    if name == "set_position"
      or name == "new_env_scope"
      or name == "new_token"
      or name == "new_invalid"
    then
      wrapped_nodes[name] = func
    else
      wrapped_nodes[name] = function(param)
        param.stat_elem = param.stat_elem or stat_elem
        return func(param)
      end
    end
  end
  return wrapped_nodes
end

return {
  test_source = test_source,
  append_stat = append_stat,
  wrap_nodes_constructors = wrap_nodes_constructors,
}
