
local util = require("util")

local new_pos = util.new_pos
local assert_params_field = util.assert_params_field

local function new_type_internal(type, type_type, params)
  type.type_type = type_type
  type.start_position = params.start_position or new_pos(0, 0)
  type.stop_position = params.stop_position or new_pos(0, 0)
  return type
end

local function new_type(type_type, params)
  return new_type_internal({}, type_type, params)
end

local function new_function_type_internal(type, params)
  new_type_internal(type, "function", params)
  type.description = params.description or {}
  type.params = params.params or {}
  type.returns = params.returns or {}
  return type
end

local function new_sequence(sequence_type, params)
  local sequence = {sequence_type = sequence_type}
  sequence.node = params.node
  sequence.source = assert_params_field(params, "source")
  sequence.start_position = params.start_position or new_pos(0, 0)
  sequence.stop_position = params.stop_position or new_pos(0, 0)
  return sequence
end

local function new_type_defining_sequence(sequence_type, params)
  local sequence = new_sequence(sequence_type, params)
  sequence.type_name = assert_params_field(params, "type_name")
  sequence.type_name_start_position = params.type_name_start_position or new_pos(0, 0)
  sequence.type_name_stop_position = params.type_name_stop_position or new_pos(0, 0)
  sequence.duplicate_type_error_code_inst = params.duplicate_type_error_code_inst
  return sequence
end

-- end of internal functions

---@param params EmmyLuaLiteralType
local function new_literal_type(params)
  local type = new_type("literal", params)
  type.value = assert_params_field(params, "value")
  return type
end

---@param params EmmyLuaDictionaryType
local function new_dictionary_type(params)
  local type = new_type("dictionary", params)
  type.key_type = assert_params_field(params, "key_type")
  type.value_type = assert_params_field(params, "value_type")
  return type
end

---@param params EmmyLuaReferenceType
local function new_reference_type(params)
  local type = new_type("reference", params)
  type.type_name = assert_params_field(params, "type_name")
  type.reference_sequence = params.reference_sequence
  util.debug_assert(
    not type.reference_sequence
      or type.reference_sequence.sequence_type == "class"
      or type.reference_sequence.sequence_type == "alias",
    "reference types may only have a class or an alias as their reference_sequence."
  )
  return type
end

---@param params EmmyLuaFunctionType
local function new_function_type(params)
  local type = new_type("function", params)
  new_function_type_internal(type, params)
  return type
end

---@param params EmmyLuaArrayType
local function new_array_type(params)
  local type = new_type("array", params)
  type.value_type = assert_params_field(params, "value_type")
  return type
end

---@param params EmmyLuaUnionType
local function new_union_type(params)
  local type = new_type("union", params)
  type.union_types = assert_params_field(params, "union_types")
  util.debug_assert(type.union_types[1], "A union type must have at least 1 type in union_types.")
  return type
end

---@param params EmmyLuaClassSequence
local function new_class(params)
  local sequence = new_type_defining_sequence("class", params)
  util.debug_assert(not sequence.node or sequence.node.node_type == "localstat",
    "class sequences can only be associated with localstat nodes."
  )
  sequence.description = params.description or {}
  sequence.base_classes = params.base_classes or {}
  sequence.fields = params.fields or {}
  sequence.is_builtin = params.is_builtin or false
  return sequence
end

---@param params EmmyLuaAliasSequence
local function new_alias(params)
  local sequence = new_type_defining_sequence("alias", params)
  util.debug_assert(not sequence.node, "alias sequences cannot be associated with any nodes.")
  sequence.description = params.description or {}
  sequence.aliased_type = assert_params_field(params, "aliased_type")
  return sequence
end

---@param params EmmyLuaAliasSequence
local function new_function(params)
  local sequence = new_sequence("function", params)
  util.debug_assert(
    sequence.node and (sequence.node.node_type == "funcstat" or sequence.node.node_type == "localfunc"),
    "function sequences must be be associated with either a funcstat or a localfunc node."
  )
  new_function_type_internal(sequence, params)
  return sequence
end

---@param params EmmyLuaField
local function new_field(params)
  local field = {
    description = params.description or {},
    name = assert_params_field(params, "name"),
    optional = params.optional or false,
    field_type = assert_params_field(params, "field_type"),
  }
  return field
end

---@param params EmmyLuaParam
local function new_param(params)
  local field = {
    description = params.description or {},
    name = assert_params_field(params, "name"),
    optional = params.optional or false,
    param_type = assert_params_field(params, "param_type"),
  }
  return field
end

---@param params EmmyLuaReturn
local function new_return(params)
  local field = {
    description = params.description or {},
    name = params.name,
    optional = params.optional or false,
    return_type = assert_params_field(params, "return_type"),
  }
  return field
end

return {
  new_literal_type = new_literal_type,
  new_dictionary_type = new_dictionary_type,
  new_reference_type = new_reference_type,
  new_function_type = new_function_type,
  new_array_type = new_array_type,
  new_union_type = new_union_type,
  new_class = new_class,
  new_alias = new_alias,
  new_function = new_function,
  new_field = new_field,
  new_param = new_param,
  new_return = new_return,
}
