
local util = require("util")
local ast = require("ast_util")
local error_code_util = require("error_code_util")

local function get_position(node)
  local position = ast.get_main_position(node)
  return (position and position.line or "0")..":"..(position and position.column or "0")
end

local loop_node_types = util.invert{"whilestat", "fornum", "forlist", "repeatstat", "loopstat"}

local error_code_insts

local function add_error(func, error_code, position_node, message_args)
  error_code_insts[#error_code_insts+1] = error_code_util.new_error_code{
    error_code = error_code,
    position = ast.get_main_position(position_node),
    location_str = " at "..get_position(position_node),
    source = func.source,
    message_args = message_args,
  }
end

---@param func AstFunctionDef
local function link(func)
  local gotos = {}
  local label_stack = {}
  ---any elements in `label_stack` with a higher index than
  ---this number are considered popped/no longer visible
  local visible_label_count = 0

  local loop_stack = {}
  ---similar story as `visible_label_count`
  local loop_count = 0

  local function walk_body(body, level)
    ---any goto defined before the latest new local in this block would
    ---jump into the scope of said local which is not allowed.\
    ---this does of course not affect goto statements defined in lower levels,
    ---since they don't look for labels in the current body
    local latest_new_local_stat_elem
    ---used to pop all labels defined in the current body off the label_stack when leaving the body
    local label_stack_top = visible_label_count

    local function walk_goto(elem, goto_stat)
      gotos[#gotos+1] = {
        stat = goto_stat,
        lowest_level = level,
        lowest_level_stat_elem = elem,
        label_is_in_scope_but_jump_is_invalid = nil,
      }

      -- solve backwards references
      for j = visible_label_count, 1, -1 do
        local label = label_stack[j]
        if label.name == goto_stat.target_name then
          goto_stat.linked_label = label
          label.linked_gotos[#label.linked_gotos+1] = goto_stat
          break
        end
      end
    end

    local function walk_label(stat_elem, label_stat)
      label_stat.linked_gotos = {}
      visible_label_count = visible_label_count + 1
      label_stack[visible_label_count] = label_stat

      local is_end_of_body
      do
        local end_of_body
        function is_end_of_body()
          if end_of_body == nil then
            -- repeatstat is special because variables may still be used past the end of the body
            -- because the condition is inside the scope
            if body.scope.node_type == "repeatstat" then
              end_of_body = false
              return end_of_body
            end
            end_of_body = true
            local elem = stat_elem.next
            while elem do
              if elem.value.node_type ~= "label" and elem.value.node_type ~= "empty" then
                end_of_body = false
                break
              end
              elem = elem.next
            end
          end
          return end_of_body
        end
      end

      -- solve forward references
      for _, go in ipairs(gotos) do
        if (not go.stat.linked_label)
          and go.lowest_level == level
          and go.stat.target_name == label_stat.name
        then
          if not latest_new_local_stat_elem
            or go.lowest_level_stat_elem.index > latest_new_local_stat_elem.index
            or is_end_of_body()
          then
            go.stat.linked_label = label_stat
            label_stat.linked_gotos[#label_stat.linked_gotos+1] = go.stat
          else
            local local_stat = latest_new_local_stat_elem.value
            local local_ref = local_stat.node_type == "localfunc" and local_stat.name
              or local_stat.node_type == "localstat" and local_stat.lhs[#local_stat.lhs]
              or error("Impossible `local_stat.node_type` '"..local_stat.node_type.."'.")
            go.label_is_in_scope_but_jump_is_invalid = true
            add_error(
              func,
              error_code_util.codes.jump_to_label_in_scope_of_new_local,
              go.stat,
              {go.stat.target_name, get_position(label_stat), local_ref.name, get_position(local_ref)}
            )
          end
        end
      end
    end

    local function walk_break(_, break_stat)
      if loop_count ~= 0 then
        local loop = loop_stack[loop_count]
        break_stat.linked_loop = loop
        loop.linked_breaks = loop.linked_breaks or {}
        loop.linked_breaks[#loop.linked_breaks+1] = break_stat
      else
        add_error(func, error_code_util.codes.break_outside_loop, break_stat)
      end
    end

    local function walk_inner_body(stat_elem, inner_body)
      local goto_count = #gotos
      walk_body(inner_body, level + 1)
      for i = goto_count + 1, #gotos do
        -- any new gotos defined in that body get treated as if they were defined in
        -- the current body at the location of the inner body.
        -- however it also has to keep track of the lowest level a goto was ever in
        -- in order not to link gotos with labels that are on the same level but there
        -- was a step in the levels down in between the label and goto statements
        gotos[i].lowest_level_stat_elem = stat_elem
        gotos[i].lowest_level = level
      end
    end

    local elem = body.first
    while elem do
      local stat = elem.value
      if stat.node_type == "gotostat" then
        walk_goto(elem, stat)
      elseif stat.node_type == "label" then
        walk_label(elem, stat)
      elseif stat.node_type == "breakstat" then
        walk_break(elem, stat)
      elseif loop_node_types[stat.node_type] then
        loop_count = loop_count + 1
        loop_stack[loop_count] = stat
        walk_inner_body(elem, stat.body)
        loop_count = loop_count - 1
      elseif stat.body then
        walk_inner_body(elem, stat.body)
      elseif stat.node_type == "ifstat" then
        for _, ifstat in ipairs(stat.ifs) do
          walk_inner_body(elem, ifstat.body)
        end
        if stat.elseblock then
          walk_inner_body(elem, stat.elseblock.body)
        end
      elseif stat.node_type == "localstat" or stat.node_type == "localfunc" then
        latest_new_local_stat_elem = elem
      end
      elem = elem.next
    end

    -- pop all new labels (from this body) off the stack.
    -- they stay in the table but are never used again
    visible_label_count = label_stack_top
  end

  walk_body(func.body, 1)

  -- all gotos without a label at the end of the function are unlinked and an error
  for _, go in ipairs(gotos) do
    if not go.stat.linked_label and not go.label_is_in_scope_but_jump_is_invalid then
      add_error(func, error_code_util.codes.no_visible_label, go.stat, {go.stat.target_name})
    end
  end
end

---@param func AstFunctionDef
local function link_recursive(func)
  link(func)
  for _, inner_func in ipairs(func.func_protos) do
    link_recursive(inner_func)
  end
end

---@param func AstFunctionDef
return function(func)
  error_code_insts = {}
  local result_error_code_insts = error_code_insts
  link_recursive(func)
  error_code_insts = nil
  return result_error_code_insts
end
