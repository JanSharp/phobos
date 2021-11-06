
local ast = {}

---@param node_type AstNodeType
function ast.new_node(node_type)
  return {node_type = node_type}
end

---@param copy_src_data boolean @ should it copy line, column and leading?
function ast.copy_node(node, new_node_type, copy_src_data)
  return {
    node_type = new_node_type,
    line = copy_src_data and node.line or nil,
    column = copy_src_data and node.column or nil,
    leading = copy_src_data and node.leading or nil,
  }
end

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

---@param ident_node AstIdent
---@return AstLocalDef def
---@return AstLocalReference ref
function ast.create_local(ident_node, stat_elem)
  local local_def = ast.create_local_def(ident_node.value)

  local ref = ast.copy_node(ident_node, "local_ref", true)
  ref.stat_elem = stat_elem
  ref.name = ident_node.value
  ref.reference_def = local_def
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

    if scope.node_type ~= "env" then
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
  ---@param ident_node AstIdent
  ---@param in_scope_at? ILLNode<nil,AstStatement>|AstStatement|AstExpression @
  ---`nil` means "defined anywhere in the scope"
  ---@return AstUpvalReference|AstLocalReference
  function ast.get_ref(scope, stat_elem, ident_node, in_scope_at)
    local def = try_get_def(
      scope,
      ident_node.value,
      in_scope_at
        and (in_scope_at.node_type and ast.get_stat_elem(in_scope_at).index or in_scope_at.index)
        or (1/0)
    )
    if def then
      -- `local_ref` or `upval_ref`
      local ref = ast.copy_node(ident_node, def.def_type.."_ref", true)
      ref.stat_elem = stat_elem
      ref.reference_def = def
      ref.name = ident_node.value
      def.refs[#def.refs+1] = ref
      return ref
    end

    local env_ident = ast.copy_node(ident_node, "ident", true)
    env_ident.leading = {} -- i'd like to have that data "duplicated"
    env_ident.value = "_ENV"

    local suffix = ast.copy_node(ident_node, "string", true)
    suffix.stat_elem = stat_elem
    suffix.value = ident_node.value
    suffix.src_is_ident = true

    local node = ast.new_node("index")
    node.stat_elem = stat_elem
    node.ex = ast.get_ref(scope, stat_elem, env_ident, in_scope_at)
    node.suffix = suffix
    node.src_ex_did_not_exist = true

    return node
  end
end

return ast
