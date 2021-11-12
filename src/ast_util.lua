
local nodes = require("nodes")
local ill = require("indexed_linked_list")

local ast = {}

function ast.get_start_index(local_def)
  return local_def.start_at.stat_elem.index + local_def.start_offset
end

function ast.get_stat_elem(node)
  return node.stat_elem
end

---@param name string
---@return AstLocalDef
function ast.create_local_def(name)
  return {
    def_type = "local",
    name = name,
    child_defs = {},
    refs = {},
  }
end

---@param ident_token Token
---@return AstLocalDef def
---@return AstLocalReference ref
function ast.create_local(ident_token, stat_elem)
  local local_def = ast.create_local_def(ident_token.value)

  local ref = nodes.new_local_ref{
    stat_elem = stat_elem,
    position = ident_token,
    name = ident_token.value,
    reference_def = local_def,
  }
  return local_def, ref
end

do
  ---@param scope AstScope|AstFunctionDef
  ---@param name string
  ---@param in_scope_at_index number
  ---@return AstLocalDef|AstUpvalDef|nil
  local function try_get_def(scope, name, in_scope_at_index)
    local found_local_def
    local found_start_index
    for i = #scope.locals, 1, -1 do
      local local_def = scope.locals[i]
      if local_def.name == name then
        if local_def.whole_block then
          found_local_def = found_local_def or local_def
        else
          local start_index = ast.get_start_index(local_def)
          if start_index <= in_scope_at_index
            and ((not found_start_index) or start_index > found_start_index)
          then
            found_local_def = local_def
            found_start_index = start_index
          end
        end
      end
    end
    if found_local_def then
      return found_local_def
    end

    if scope.node_type == "functiondef" then
      for _, upval in ipairs(scope.upvals) do
        if upval.name == name then
          return upval
        end
      end
    end

    if scope.node_type ~= "env_scope" then
      assert(scope.parent_scope)
      local def = try_get_def(scope.parent_scope, name, ast.get_stat_elem(scope).index)
      if def then
        if scope.upvals then
          local new_def = {
            def_type = "upval",
            name = name,
            scope = scope,
            parent_def = def,
            child_defs = {},
            refs = {},
          }
          def.child_defs[#def.child_defs+1] = new_def
          if name == "_ENV" then
            -- always put _ENV first so that `load`'s mangling will be correct
            table.insert(scope.upvals, 1, new_def)
          else
            scope.upvals[#scope.upvals+1] = new_def
          end
          return new_def
        else
          return def
        end
      end
    end
  end

  ---@param scope AstScope
  ---@param stat_elem ILLNode<nil,AstStatement> @
  ---used for the reference nodes being created, and to determine
  ---at which point the given name has to be in scope within the given scope
  ---@param name string
  ---@param node_for_position? AstNode
  ---@return AstUpvalReference|AstLocalReference
  function ast.get_ref(scope, stat_elem, name, node_for_position)
    node_for_position = node_for_position or {}
    local def = try_get_def(scope, name, stat_elem.index)
    if def then
      -- `local_ref` or `upval_ref`
      local ref = (def.def_type == "local" and nodes.new_local_ref or nodes.new_upval_ref){
        stat_elem = stat_elem,
        name = name,
        reference_def = def,
      }
      nodes.set_position(ref, node_for_position)
      def.refs[#def.refs+1] = ref
      return ref
    end

    local suffix = nodes.new_string{
      stat_elem = stat_elem,
      value = name,
      src_is_ident = true,
    }
    nodes.set_position(suffix, node_for_position)

    local node = nodes.new_index{
      stat_elem = stat_elem,
      ex = ast.get_ref(scope, stat_elem, "_ENV", node_for_position),
      suffix = suffix,
      src_ex_did_not_exist = true,
    }

    return node
  end
end

do
  local function call_callback(stat_elem, callback)
    stat_elem.value = assert(callback(stat_elem), "The callback must return the created statement")
    return stat_elem.value
  end

  function ast.prepend_stat(scope, callback)
    return call_callback(ill.prepend(scope.body), callback)
  end

  function ast.append_stat(scope, callback)
    return call_callback(ill.append(scope.body), callback)
  end

  function ast.insert_after_stat(stat, callback)
    return call_callback(ill.insert_after(stat.stat_elem), callback)
  end

  function ast.insert_before_stat(stat, callback)
    return call_callback(ill.insert_before(stat.stat_elem), callback)
  end
end

return ast
