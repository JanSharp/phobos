
local util = require("util")
local nodes = require("nodes")
local ill = require("indexed_linked_list")

local ast = {}

function ast.get_start_index(local_def)
  return local_def.start_at.index + local_def.start_offset
end

-- -- TODO: docs
-- function ast.get_statement(node)
--   if node.node_type == "functiondef" then
--     if node.is_main or node.parent_statement.node_type == "repeatstat" then
--       return nil
--     end
--     return node.parent_statement
--   else
--     return node
--   end
-- end

-- -- TODO: docs
-- function ast.get_stat_index(stat)
--   return stat and stat.index or (1/0)
-- end

---@param name string
---@return AstLocalDef
function ast.new_local_def(name, scope)
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
function ast.create_local(ident_token, scope)
  local local_def = ast.new_local_def(ident_token.value, scope)
  local ref = nodes.new_local_ref{
    position = ident_token,
    name = ident_token.value,
    reference_def = local_def,
  }
  local_def.refs[#local_def.refs+1] = ref
  return local_def, ref
end

function ast.create_upval_def(parent_def, target_scope)
  local upval_def = {
    def_type = "upval",
    name = parent_def.name,
    scope = target_scope,
    parent_def = parent_def,
    child_defs = {},
    refs = {},
  }
  parent_def.child_defs[#parent_def.child_defs+1] = upval_def
  if upval_def.name == "_ENV" then
    -- always put _ENV first so that `load`'s mangling will be correct
    table.insert(target_scope.upvals, 1, upval_def)
  else
    target_scope.upvals[#target_scope.upvals+1] = upval_def
  end
  return upval_def
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
          -- HACK: this should check for the existence of a statement stack instead of in_scope_at_index
          local start_index = in_scope_at_index == (1/0) and 0 or ast.get_start_index(local_def)
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
      local def = try_get_def(scope.parent_scope, name, 1/0)
      if def then
        if scope.upvals then
          return ast.create_upval_def(def, scope)
        else
          return def
        end
      end
    end
  end

  ---@param scope AstScope
  ---@param statement AstStatement @
  ---used to determine at which point the given name has to be in scope within the given scope
  ---when `nil` it is assumed to be at the end of the given scope
  ---@param name string
  ---@param node_for_position? AstNode
  ---@return AstUpvalReference|AstLocalReference
  function ast.get_ref(scope, statement, name, node_for_position) -- TODO: remove statement?
    node_for_position = node_for_position or {}
    local def = try_get_def(scope, name, statement and statement.index or (1/0))
    if def then
      -- `local_ref` or `upval_ref`
      local ref = (def.def_type == "local" and nodes.new_local_ref or nodes.new_upval_ref){
        name = name,
        reference_def = def,
      }
      nodes.set_position(ref, node_for_position)
      def.refs[#def.refs+1] = ref
      return ref
    end

    local suffix = nodes.new_string{
      value = name,
      src_is_ident = true,
    }
    nodes.set_position(suffix, node_for_position)

    local node = nodes.new_index{
      ex = ast.get_ref(scope, statement, "_ENV", node_for_position),
      suffix = suffix,
      src_ex_did_not_exist = true,
    }

    return node
  end
end

local function create_ref_to_local_or_upval_def(def)
  return (def.def_type == "local" and nodes.new_local_ref or nodes.new_upval_ref){
    name = def.name,
    reference_def = def,
  }
end

local function get_or_create_upval_def(parent_def, target_scope)
  for _, upval in ipairs(target_scope.upvals) do
    if upval.parent_def == parent_def then
      return upval
    end
  end
  return ast.create_upval_def(parent_def, target_scope)
end

function ast.create_ref_to(local_def, target_scope)
  local function get_def_recursive(scope)
    while scope ~= local_def.scope do
      if scope.node_type == "functiondef" then
        local def = get_def_recursive(scope.parent_scope)
        return get_or_create_upval_def(def, scope)
      end
      scope = scope.parent_scope
    end
    return local_def
  end
  local def = get_def_recursive(target_scope)
  local ref = create_ref_to_local_or_upval_def(def)
  return ref
end

function ast.prepend_stat(scope, stat)
  return ill.prepend(scope.body, stat)
end

function ast.append_stat(scope, stat)
  return ill.append(scope.body, stat)
end

ast.insert_after_stat = ill.insert_after
ast.insert_before_stat = ill.insert_before

ast.remove_stat = ill.remove

function ast.replace_stat(old, new)
  local list = old.list
  local index = old.index
  local prev = old.prev
  local next = old.next
  util.replace_table(old, new)
  old.list = list
  old.index = index
  old.prev = prev
  old.next = next
end

function ast.get_parent_scope(scope, node_type)
  while scope and scope.node_type ~= node_type do
    scope = scope.parent_scope
  end
  return scope
end

function ast.get_functiondef(scope)
  return ast.get_parent_scope(scope, "functiondef")
end

function ast.new_main(source)
  local env_scope = nodes.new_env_scope{main = true} -- prevent assert
  -- Lua emits _ENV as if it's a local in the parent scope
  -- of the file. I'll probably change this one day to be
  -- the first upval of the parent scope, since load()
  -- clobbers the first upval anyway to be the new _ENV value
  local def = ast.new_local_def("_ENV", env_scope)
  def.whole_block = true
  env_scope.locals[1] = def

  local main = nodes.new_functiondef{
    is_main = true,
    source = source,
    parent_scope = env_scope,
    is_vararg = true,
  }
  env_scope.main = main
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
