
local util = require("util")
local error_code_util = require("error_code_util")
local error_codes = error_code_util.codes
local el_util = require("emmy_lua_util")

local function new_error_code_inst(error_code, message_args, source, start_position, stop_position)
  return error_code_util.new_error_code{
    error_code = error_code,
    message_args = message_args,
    source = source,
    start_position = start_position,
    stop_position = stop_position,
    location_str = " at "..start_position.line..":"..start_position.column
      .." - "..stop_position.line..":"..stop_position.column
  }
end

local function add_type(emmy_lua, type_defining_sequence, error_code_insts)
  if emmy_lua.all_types_lut[type_defining_sequence.type_name] then
    local error_code_inst = new_error_code_inst(
      error_codes.el_duplicate_type_name,
      {type_defining_sequence.type_name},
      type_defining_sequence.source,
      type_defining_sequence.type_name_start_position,
      type_defining_sequence.type_name_stop_position
    )
    error_code_insts[#error_code_insts+1] = error_code_inst
    type_defining_sequence.duplicate_type_error_code_inst = error_code_inst
  else
    -- don't overwrite, the first one counts. References will resolve to this
    emmy_lua.all_types_lut[type_defining_sequence.type_name] = type_defining_sequence
  end
end

local function add_alias(emmy_lua, alias, error_code_insts)
  add_type(emmy_lua, alias, error_code_insts)
  -- add it regardless of if its a duplicate
  emmy_lua.aliases[#emmy_lua.aliases+1] = alias
end

local function add_class(emmy_lua, class, error_code_insts)
  add_type(emmy_lua, class, error_code_insts)
  -- add it regardless of if its a duplicate
  emmy_lua.classes[#emmy_lua.classes+1] = class
end

local function seed_classes(emmy_lua)
  local function add(name, custom_description)
    add_class(emmy_lua, el_util.new_class{
      description = {custom_description or ("Lua built-in "..name..".")},
      type_name = name,
      source = "=(builtin)",
      is_builtin = true,
    })
  end
  add("string")
  add("number")
  add("integer", "Actually also a Lua built-in number, but it should be integral.")
  add("boolean")
  add("table")
  add("function")
  add("nil")
  add("any", "Simply any value.")
end

local function new_emmy_lua_data()
  local emmy_lua = {
    aliases = {},
    classes = {},
    all_types_lut = {},
  }
  seed_classes(emmy_lua)
  return emmy_lua
end

local function resolve_references(emmy_lua, source, error_code_insts, type, is_base_class_ref)
  if is_base_class_ref and type.type_type ~= "reference" then
    error_code_insts[#error_code_insts+1] = new_error_code_inst(
      error_codes.el_expected_reference_to_class,
      {type.type_type, ""},
      source,
      type.start_position,
      type.stop_position
    )
  end
  (({
    ["literal"] = function()
      -- doesn't have references
    end,
    ["dictionary"] = function()
      resolve_references(emmy_lua, source, error_code_insts, type.key_type)
      resolve_references(emmy_lua, source, error_code_insts, type.value_type)
    end,
    ["function"] = function()
      for _, param in ipairs(type.params) do
        resolve_references(emmy_lua, source, error_code_insts, param.param_type)
      end
      for _, ret in ipairs(type.returns) do
        resolve_references(emmy_lua, source, error_code_insts, ret.return_type)
      end
    end,
    ["reference"] = function()
      local resolved_seq = emmy_lua.all_types_lut[type.type_name]
      type.reference_sequence = resolved_seq
      local function add_error(error_code, message_args)
        error_code_insts[#error_code_insts+1] = new_error_code_inst(
          error_code,
          message_args,
          source,
          type.start_position,
          type.stop_position
        )
      end
      if not resolved_seq then
        add_error(error_codes.el_unresolved_reference, {type.type_name})
      elseif is_base_class_ref and resolved_seq.sequence_type ~= "class" then
        add_error(
          error_codes.el_expected_reference_to_class,
          {type.type_type, " with type_name "..type.type_name}
        )
      elseif is_base_class_ref and resolved_seq.sequence_type == "class" and resolved_seq.is_builtin then
        add_error(error_codes.el_builtin_base_class, {resolved_seq.type_name, type.type_name})
      end
    end,
    ["array"] = function()
      resolve_references(emmy_lua, source, error_code_insts, type.value_type)
    end,
    ["union"] = function()
      for _, union_type in ipairs(type.union_types) do
        resolve_references(emmy_lua, source, error_code_insts, union_type)
      end
    end,
  })[type.type_type] or function()
    util.debug_abort("Unknown emmy lua type type_type '"..tostring(type.type_type).."'.")
  end)()
end

local function link(parsed_sequences)
  local emmy_lua = new_emmy_lua_data()
  local error_code_insts = {}

  -- add all classes and aliases

  local funcs = {}
  for _, sequence in ipairs(parsed_sequences) do
    if sequence.sequence_type == "class" then
      add_class(emmy_lua, sequence, error_code_insts)
    elseif sequence.sequence_type == "alias" then
      add_alias(emmy_lua, sequence, error_code_insts)
    elseif sequence.sequence_type == "function" then
      funcs[#funcs+1] = sequence
    else
      -- nothing to do for "none", throw away
    end
  end

  -- resolve all references

  for _, alias in ipairs(emmy_lua.aliases) do
    resolve_references(emmy_lua, alias.source, error_code_insts, alias.aliased_type)
  end

  for _, class in ipairs(emmy_lua.classes) do
    for _, base_class in ipairs(class.base_classes) do
      resolve_references(emmy_lua, class.source, error_code_insts, base_class, true)
    end
    for _, field in ipairs(class.fields) do
      resolve_references(emmy_lua, class.source, error_code_insts, field.field_type)
    end
    if class.node then
      util.debug_assert(class.node.node_type == "localstat", "the emmy lua parser should \z
        only ever make classes with localstat as their node, no other nodes allowed."
      )
      for _, local_ref in ipairs(class.node.lhs) do
        local_ref.reference_def.emmy_lua_class = class
      end
    end
  end

  for _, func in ipairs(funcs) do
    resolve_references(emmy_lua, func.source, error_code_insts, func)
  end

  -- add function sequences as fields to classes if we can find the class
  -- they are supposed to be apart of

  for _, func in ipairs(funcs) do
    local node = func.node
    if node.node_type == "funcstat" then
      local name = node.name
      if name.node_type == "index" then
        local ex = name.ex
        local suffix = name.suffix
        if (ex.node_type == "local_ref" or ex.node_type == "upval_ref")
          and suffix.node_type == "string" and suffix.value:find("^[a-zA-Z_][a-zA-Z_0-9]*$")
        then
          local def = ex.reference_def
          while def.def_type == "upval" do
            def = def.parent_def
          end
          local class = def.emmy_lua_class
          if class then
            class.fields[#class.fields+1] = {
              tag = "field",
              description = func.description,
              name = suffix.value,
              field_type = func,
            }
          end
        end
      end
    else
      -- localfunc doesn't add to any type, so we can't really consider it to be a field of a class
    end
  end

  -- clean up data in the ast

  for _, class in ipairs(emmy_lua.classes) do
    if class.node then
      for _, local_ref in ipairs(class.node.lhs) do
        local_ref.reference_def.emmy_lua_class = nil
      end
    end
  end

  return emmy_lua, error_code_insts
end

return link
