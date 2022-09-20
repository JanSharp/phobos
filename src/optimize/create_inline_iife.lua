
local ast_walker = require("ast_walker")

local on_open = {
  ---@param node AstCall
  call = function(node, scope, is_statement)
    if node.ex.node_type == "func_proto" then
      if is_statement then
        error("-- TODO: impl inline_iife for statements.")
      end

      -- find the parent functiondef
      while scope.node_type ~= "functiondef" do
        scope = scope.parent_scope
      end

      ---@type AstFunctionDef
      local inner_func = node.ex.func_def

      if inner_func.is_vararg then
        error("Unable to inline vararg IIFE at "..scope.source..":"..node.line..":"..node.column..".")
      end

      local args = node.args
      local args_comma_tokens = node.args_comma_tokens
      node.args = nil
      node.args_comma_tokens = nil
      node.open_paren_token = nil
      node.close_paren_token = nil
      node.ex = nil
      node.node_type = "inline_iife"

      for _, upval in ipairs(inner_func.upvals) do
        if upval.parent_def.def_type == "local" then
          -- have to convert all references to local refs
          for _, ref in ipairs(upval.refs) do
            ref.node_type = "local_ref"
          end
        end
        for _, ref in ipairs(upval.refs) do
          ref.reference_def = upval.parent_def
          ref.scope = node
        end

        for i, child_def in ipairs(upval.parent_def.child_defs) do
          if child_def == upval then
            table.remove(upval.parent_def.child_defs, i)
            break
          end
        end

        for _, child_def in ipairs(upval.child_defs) do
          child_def.parent_def = upval.parent_def
          upval.parent_def.child_defs[#upval.parent_def.child_defs+1] = child_def
        end
      end

      if #inner_func.params > 0 then
        local param_local_defs = {}
        local param_local_refs = {}
        for i = 1, #inner_func.params do
          local local_def = inner_func.locals[i]
          local_def.whole_block = nil
          param_local_defs[i] = local_def
          local local_ref = {
            node_type = "local_ref",
            name = local_def.name,
            reference_def = local_def,
          }
          param_local_refs[i] = local_ref
          -- maybe insert instead to preserve correct reference order
          -- but i don't think that's needed or worth it
          local_def.refs[#local_def.refs+1] = local_ref
        end

        local param_assignment = {
          node_type = "localstat",
          lhs = param_local_refs,
          lhs_comma_tokens = inner_func.param_comma_tokens,
          rhs = args,
          rhs_comma_tokens = args_comma_tokens,
        }
        for _, def in ipairs(param_local_defs) do
          def.start_after = param_assignment
        end
        table.insert(inner_func.body, 1, param_assignment)
      elseif #args > 0 then
        error("-- TODO: impl some kind of no op stat that evals an \z
          expression list with 0 results. For args in this case."
        )
      end

      node.body = inner_func.body
      node.locals = inner_func.locals
      node.labels = inner_func.labels
      node.parent_scope = inner_func.parent_scope
      node.linked_inline_iife_retstats = {}

      node.body[#node.body+1] = {
        node_type = "retstat",
        return_token = inner_func.end_token,
      }

      node.leave_block_label = {
        node_type = "label",
        value = "(leave inline iife block)",
        linked_gotos = {},
      }
      node.body[#node.body+1] = node.leave_block_label

      -- TODO: keep a list of child scopes
      ---@type AstStatement|AstIfStat
      for _, inst in ipairs(node.body) do
        if inst.node_type == "ifstat" then
          -- ---@narrow inst AstIfStat
          for _, ifstat in ipairs(inst.ifs) do
            ifstat.parent_scope = node
          end
          if inst.elseblock then
            inst.elseblock.parent_scope = node
          end
        end
        if inst.parent_scope then
          inst.parent_scope = node
        end
      end

      for i, func_proto in ipairs(scope.func_protos) do
        if func_proto == inner_func then
          table.remove(scope.func_protos, i)
          break
        end
      end

      for _, func in ipairs(inner_func.func_protos) do
        scope.func_protos[#scope.func_protos+1] = func
        -- TODO: keep a list of child scopes
        func.parent_scope = node
      end
    end
  end,
  ---@param node AstRetStat
  retstat = function(node, scope)
    local original_scope = scope
    while scope.node_type ~= "inline_iife" do
      if scope.node_type == "functiondef" then
        return
      end
      scope = scope.parent_scope
    end

    scope.linked_inline_iife_retstats[#scope.linked_inline_iife_retstats+1] = node
    node.node_type = "inline_iife_retstat"
    node.linked_inline_iife = scope

    node.leave_block_goto = {
      node_type = "gotostat",
      goto_token = node.return_token, -- how to deal with token values in this kind of a scenario?
      target_name = "(leave inline iife block)",
      linked_label = scope.leave_block_label,
    }
    scope.leave_block_label.linked_gotos[#scope.leave_block_label.linked_gotos+1] = node.leave_block_goto

    for i, stat in ipairs(original_scope.body) do
      if stat == node then
        table.insert(original_scope.body, i + 1, node.leave_block_goto)
        return
      end
    end
    error("Unable to insert leave inline iife block goto.")
  end,
}

local function create_inline_iife(main)
  ast_walker.walk_scope(main, ast_walker.new_context(on_open, nil))
end

return create_inline_iife
