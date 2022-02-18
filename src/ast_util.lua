
local util = require("util")
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
function ast.create_local_def(name, scope)
  return {
    def_type = "local",
    name = name,
    scope = scope,
    child_defs = {},
    refs = {},
  }
end

---@param ident_token Token
---@return AstLocalDef def
---@return AstLocalReference ref
function ast.create_local(ident_token, scope, stat_elem)
  local local_def = ast.create_local_def(ident_token.value, scope)

  local ref = nodes.new_local_ref{
    stat_elem = stat_elem,
    position = ident_token,
    name = ident_token.value,
    reference_def = local_def,
  }
  -- TODO: deal with `refs`
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

function ast.new_main(source)
  local env_scope = nodes.new_env_scope{}
  -- Lua emits _ENV as if it's a local in the parent scope
  -- of the file. I'll probably change this one day to be
  -- the first upval of the parent scope, since load()
  -- clobbers the first upval anyway to be the new _ENV value
  local def = ast.create_local_def("_ENV", env_scope)
  def.whole_block = true
  env_scope.locals[1] = def

  local main = ast.append_stat(env_scope, function(stat_elem)
    local main = nodes.new_functiondef{
      stat_elem = stat_elem,
      is_main = true,
      source = source,
      parent_scope = env_scope,
      is_vararg = true,
    }
    return main
  end)
  return main
end

---@param upval_def AstUpvalDef
function ast.upval_is_in_stack(upval_def)
  return upval_def.parent_def.def_type == "local"
end

function ast.is_falsy(node)
  return node.node_type == "nil" or (node.node_type == "boolean" and node.value == false)
end

local const_node_type_lut = util.invert{"string","number","boolean","nil"}
function ast.is_const_node(node)
  return const_node_type_lut[node.node_type]
end
function ast.is_const_node_type(node_type)
  return const_node_type_lut[node_type]
end

local vararg_node_type_lut = util.invert{"vararg", "call"}
function ast.is_vararg_node(node)
  return vararg_node_type_lut[node.node_type] and (not node.force_single_result)
end
function ast.is_vararg_node_type(node_type)
  return vararg_node_type_lut[node_type]
end

function ast.is_single_result_node_type(node_type)
  return not ast.is_vararg_node_type(node_type) and node_type ~= "nil"
end
function ast.is_single_result_node(node)
  return node.force_single_result or ast.is_single_result_node_type(node.node_type)
end

local get_main_position
do
  local getter_lut = {
    ["env_scope"] = function(node)
      error("node_type 'env_scope' is purely fake and therefore has no main position")
      return nil
    end,
    ["functiondef"] = function(node)
      return node.function_token
    end,
    ["token"] = function(node)
      return node
    end,
    ["empty"] = function(node)
      return node.semi_colon_token
    end,
    ["ifstat"] = function(node)
      return get_main_position(node.ifs[1])
    end,
    ["testblock"] = function(node)
      return node.if_token
    end,
    ["elseblock"] = function(node)
      return node.else_token
    end,
    ["whilestat"] = function(node)
      return node.while_token
    end,
    ["dostat"] = function(node)
      return node.do_token
    end,
    ["fornum"] = function(node)
      return node.for_token
    end,
    ["forlist"] = function(node)
      return node.for_token
    end,
    ["repeatstat"] = function(node)
      return node.repeat_token
    end,
    ["funcstat"] = function(node)
      return get_main_position(node.func_def)
    end,
    ["localstat"] = function(node)
      return node.local_token
    end,
    ["localfunc"] = function(node)
      return node.local_token
    end,
    ["label"] = function(node)
      return node.open_token
    end,
    ["retstat"] = function(node)
      return node.return_token
    end,
    ["breakstat"] = function(node)
      return node.break_token
    end,
    ["gotostat"] = function(node)
      return node.goto_token
    end,
    ["call"] = function(node)
      if node.is_selfcall then
        return node.colon_token
      else
        return node.open_paren_token
      end
    end,
    ["assignment"] = function(node)
      return node.eq_token
    end,
    ["local_ref"] = function(node)
      return node
    end,
    ["upval_ref"] = function(node)
      return node
    end,
    ["index"] = function(node)
      if node.suffix.node_type == "string" and node.suffix.src_is_ident then
        if node.src_ex_did_not_exist then
          return node.suffix
        else
          return node.dot_token
        end
      else
        return node.suffix_open_token
      end
    end,
    ["unop"] = function(node)
      return node.op_token
    end,
    ["binop"] = function(node)
      return node.op_token
    end,
    ["concat"] = function(node)
      return node.op_tokens and node.op_tokens[1]
    end,
    ["number"] = function(node)
      return node
    end,
    ["string"] = function(node)
      return node
    end,
    ["nil"] = function(node)
      return node
    end,
    ["boolean"] = function(node)
      return node
    end,
    ["vararg"] = function(node)
      return node
    end,
    ["func_proto"] = function(node)
      return get_main_position(node.func_def)
    end,
    ["constructor"] = function(node)
      return node.open_token
    end,
    ["inline_iife_retstat"] = function(node)
      return node.return_token
    end,
    ["loopstat"] = function(node)
      return node.open_token
    end,
    ["inline_iife"] = function(node)
      -- TODO: when refactoring inline_iife add some main position
      return node.body.first and get_main_position(node.body.first.value)
    end,
  }
  function ast.get_main_position(node)
    return getter_lut[node.node_type](node)
  end
  get_main_position = ast.get_main_position
end

return ast
