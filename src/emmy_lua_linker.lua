
local util = require("util")

local function add_alias(emmy_lua, alias)
  if emmy_lua.all_types_lut[alias.type_name] then
    util.abort("Duplicate class "..alias.type_name..".")
  end
  emmy_lua.aliases[#emmy_lua.aliases+1] = alias
  emmy_lua.all_types_lut[alias.type_name] = alias
end

local function add_class(emmy_lua, class)
  if emmy_lua.all_types_lut[class.type_name] then
    util.abort("Duplicate class "..class.type_name..".")
  end
  emmy_lua.classes[#emmy_lua.classes+1] = class
  emmy_lua.all_types_lut[class.type_name] = class
end

local function seed_classes(emmy_lua)
  local function add(name)
    add_class(emmy_lua, {
      description = name.." primitive",
      type_name = name,
      fields = {},
      base_classes = {},
    })
  end
  add("string")
  add("number")
  add("integer")
  add("boolean")
  add("table")
  add("function")
  add("nil")
  add("any")
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

local function resolve_references(emmy_lua, type, must_be_class)
  if must_be_class and type.type_type ~= "reference" then
    util.debug_abort("Expected a reference to a class (not an alias).")
  end
  (({
    ["literal"] = function()
      -- doesn't have references
    end,
    ["dictionary"] = function()
      resolve_references(emmy_lua, type.key_type)
      resolve_references(emmy_lua, type.value_type)
    end,
    ["function"] = function()
      for _, param in ipairs(type.params) do
        resolve_references(emmy_lua, param.param_type)
      end
      for _, ret in ipairs(type.returns) do
        resolve_references(emmy_lua, ret.return_type)
      end
    end,
    ["reference"] = function()
      type.reference_type = emmy_lua.all_types_lut[type.type_name]
      if not type.reference_type then
        util.debug_abort("Unable to resolve reference to type "..type.type_name..".")
      end
      if must_be_class and type.reference_type.sequence_type ~= "class" then
        util.debug_abort("Expected a reference to a class (not an alias). type_name: "
          ..type.type_name.."."
        )
      end
    end,
    ["array"] = function()
      resolve_references(emmy_lua, type.value_type)
    end,
    ["union"] = function()
      for _, union_type in ipairs(type.union_types) do
        resolve_references(emmy_lua, union_type)
      end
    end,
  })[type.type_type] or function()
    util.debug_abort("Unknown emmy lua type type_type '"..tostring(type.type_type).."'.")
  end)()
end

local function link(parsed_sequences)
  local emmy_lua = new_emmy_lua_data()

  -- add all classes and aliases

  local funcs = {}
  for _, sequence in ipairs(parsed_sequences) do
    if sequence.sequence_type == "class" then
      add_class(emmy_lua, sequence)
    elseif sequence.sequence_type == "alias" then
      add_alias(emmy_lua, sequence)
    elseif sequence.sequence_type == "function" then
      funcs[#funcs+1] = sequence
    else
      -- nothing to do for "none", throw away
    end
  end

  -- resolve all references

  for _, alias in ipairs(emmy_lua.aliases) do
    resolve_references(emmy_lua, alias.aliased_type)
  end

  for _, class in ipairs(emmy_lua.classes) do
    for _, base_class in ipairs(class.base_classes) do
      resolve_references(emmy_lua, base_class, true)
    end
    for _, field in ipairs(class.fields) do
      resolve_references(emmy_lua, field.field_type)
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
    resolve_references(emmy_lua, func)
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
              description = {}, -- TODO: should this be the func.description?
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

  return emmy_lua
end

return {
  link = link,
}
