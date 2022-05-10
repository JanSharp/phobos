
local util = require("util")

---@class ILTypeBaseParams
---@field inferred boolean

---@param type_id ILTypeId
---@param params ILTypeBaseParams
---@return ILType|ILClass
local function new_il_type(type_id, params)
  return {
    type_id = type_id,
    inferred = params.inferred or false,
  }
end

---@class ILAnyParams : ILTypeBaseParams

---@param params ILAnyParams
---@return ILType
local function new_any(params)
  local il_type = new_il_type("any", params)
  return il_type
end

---@class ILEmptyParams : ILTypeBaseParams

---@param params ILEmptyParams
---@return ILType
local function new_empty(params)
  local il_type = new_il_type("empty", params)
  return il_type
end

---@class ILNilParams : ILTypeBaseParams

---@param params ILNilParams
---@return ILType
local function new_nil(params)
  local il_type = new_il_type("nil", params)
  return il_type
end

---@class ILStringParams : ILTypeBaseParams

---@param params ILStringParams
---@return ILType
local function new_string(params)
  local il_type = new_il_type("string", params)
  return il_type
end

---@class ILLiteralStringParams : ILTypeBaseParams
---@field value string

---@param params ILLiteralStringParams
---@return ILType
local function new_literal_string(params)
  local il_type = new_il_type("literal_string", params)
  il_type.value = params.value
  return il_type
end

---@class ILNumberParams : ILTypeBaseParams

---@param params ILNumberParams
---@return ILType
local function new_number(params)
  local il_type = new_il_type("number", params)
  return il_type
end

---@class ILLiteralNumberParams : ILTypeBaseParams
---@field value number

---@param params ILLiteralNumberParams
---@return ILType
local function new_literal_number(params)
  local il_type = new_il_type("literal_number", params)
  il_type.value = params.value
  return il_type
end

---@class ILBooleanParams : ILTypeBaseParams

---@param params ILBooleanParams
---@return ILType
local function new_boolean(params)
  local il_type = new_il_type("boolean", params)
  return il_type
end

---@class ILLiteralBooleanParams : ILTypeBaseParams
---@field value boolean

---@param params ILLiteralBooleanParams
---@return ILType
local function new_literal_boolean(params)
  local il_type = new_il_type("literal_boolean", params)
  il_type.value = params.value
  return il_type
end

---@class ILFunctionParams : ILTypeBaseParams

---@param params ILFunctionParams
---@return ILType
local function new_function(params)
  local il_type = new_il_type("function", params)
  return il_type
end

---@class ILLiteralFunctionParams : ILTypeBaseParams
---@field func ILFunction @ -- TODO: identify func

---@param params ILLiteralFunctionParams
---@return ILType
local function new_literal_function(params)
  local il_type = new_il_type("function", params)
  il_type.func = util.assert_params_field(params, "func")
  return il_type
end

---@class ILUserdataParams : ILTypeBaseParams

---@param params ILUserdataParams
---@return ILType
local function new_userdata(params)
  local il_type = new_il_type("userdata", params)
  return il_type
end

---@class ILThreadParams : ILTypeBaseParams

---@param params ILThreadParams
---@return ILType
local function new_thread(params)
  local il_type = new_il_type("thread", params)
  return il_type
end

---@class ILTableParams : ILTypeBaseParams

---@param params ILTableParams
---@return ILType
local function new_table(params)
  local il_type = new_il_type("table", params)
  return il_type
end

---@class ILClassParams : ILTypeBaseParams
---@field kvps ILClassKvp[]
---@field is_table boolean
---@field is_userdata boolean

---@param params ILClassParams
---@return ILClass
local function new_class(params)
  local il_type = new_il_type("class", params)
  il_type.kvps = params.kvps or {}
  il_type.is_table = params.is_table or false
  il_type.is_userdata = params.is_userdata or false
  return il_type
end

---@class ILUnionParams : ILTypeBaseParams
---@field inner_types ILType[]

---@param params ILUnionParams
---@return ILType
local function new_union(params)
  local il_type = new_il_type("union", params)
  if params.inner_types then
    for _, inner_type in ipairs(params.inner_types) do
      if inner_type.type_id == "union" then
        util.debug_abort("Unions must not contain unions, use the smart_union function.")
      end
    end
  end
  il_type.inner_types = params.inner_types or {}
  return il_type
end

---@class ILIntersectionParams : ILTypeBaseParams
---@field inner_types ILType[]

---@param params ILIntersectionParams
---@return ILType
local function new_intersection(params)
  local il_type = new_il_type("intersection", params)
  if params.inner_types then
    for _, inner_type in ipairs(params.inner_types) do
      if inner_type.type_id == "intersection" then
        util.debug_abort("Intersections must not contain intersections, use the smart_intersection function.")
      end
    end
  end
  il_type.inner_types = params.inner_types or {}
  return il_type
end

local types_containing_other_types_lut = util.invert{
  "class",
  "union",
  "intersection",
  "inverted",
}

---@class ILInvertedParams : ILTypeBaseParams
---@field inverted_type ILType

---@param params ILInvertedParams
---@return ILType
local function new_inverted(params)
  local il_type = new_il_type("inverted", params)
  il_type.inverted_type = params.inverted_type
  if types_containing_other_types_lut[params.inverted_type.type_id] then
    util.debug_abort("Inverted types of types that contain other types is not supported. \z
      There are several reasons for this like intersecting them requiring removal of types \z
      from other types, but that removing might involve removing inverted types from types. \z
      Determining if such types are contained in other types is either really hard or impossible. \z
      I could not think of a way to do it. Just all in all they complicate things so much while \z
      you can just use inverted types of 'basic' types and then create unions and intersections \z
      of those. I mean an inverted union really is just an intersection of inverted types, for example."
    )
  end
  return il_type
end

local function copy_type(reg_type)
  -- there are some cases where a full deep copy is not the correct solution,
  -- the only case I can think of is function types with the reference to actual functions
  -- other than that I think a generic copy is fine
  if reg_type.type_id == "literal_function" then
    return new_literal_function{
      inferred = reg_type.inferred,
      func = reg_type.func,
    }
  end
  return util.copy(reg_type)
end

---@return ILType
local function make_type_from_ptr(state, ptr)
  return (({
    ["reg"] = function()
      return copy_type(state.reg_types[ptr])
    end,
    ["vararg"] = function()
      util.debug_abort("-- TODO: I hate vararg.")
    end,
    ["number"] = function()
      return new_literal_number{value = ptr.value}
    end,
    ["string"] = function()
      return new_literal_string{value = ptr.value}
    end,
    ["boolean"] = function()
      return new_literal_boolean{value = ptr.value}
    end,
    ["nil"] = function()
      return new_nil{}
    end,
  })[ptr.ptr_type] or function()
    util.debug_abort("Unknown IL ptr_type '"..ptr.ptr_type.."'.")
  end)()
end

-- Alright, comparing types is even harder than intersecting and contains
-- I think I need to normalize types before I can compare them for equality
-- there are just too many formats to represent the same type
-- but honestly that is the problem
-- there being multiple ways to represent the same type
-- that needs to be disallowed
-- simply impossible
-- but how
-- maybe intersections are the problem
-- i mean inverted types have already caused lots of trouble
-- but intersections haven't made my life particularly easy either
-- so what are the alternatives?
-- what other way is there to represent types in a way where I can exclude specific types
-- well, lets think about it:
--[[

types which when excluded can still be represented as a union of other types or some other type in general:
"any"
"empty"
"nil"
"string"
"number"
"boolean"
"function"
"userdata"
"thread"
"table"
future ones like less than, greater than

special
"literal_string"
"literal_number"
"literal_boolean"
"literal_function"
future special ones like integral, function identity, table identity

very special. so special that I don't like them anymore
-- "class"
"union"
-- "intersection"
-- "inverted"

I could add a list of excluded types to unions
which would cover the special ones, but not the very special ones
with that we could nuke both intersection and inverted
with intersection and inverted nuked, we're left with classes
but we only really need to be able to exclude table identity, which is not a class pre se
so i'm pretty sure we could simply disallow classes as being "excluded"

]]

local equals
do
  local equals_lut = {
    ["any"] = function(left_type, right_type)
      return right_type.type_id == "any"
    end,
    ["empty"] = function(left_type, right_type)
      return right_type.type_id == "empty"
    end,
    ["nil"] = function(left_type, right_type)
      return right_type.type_id == "nil"
    end,
    ["string"] = function(left_type, right_type)
      return right_type.type_id == "string"
    end,
    ["literal_string"] = function(left_type, right_type)
      return right_type.type_id == "literal_string" and right_type.value == left_type.value
    end,
    ["number"] = function(left_type, right_type)
      return right_type.type_id == "number"
    end,
    ["literal_number"] = function(left_type, right_type)
      return right_type.type_id == "literal_number" and right_type.value == left_type.value
    end,
    ["boolean"] = function(left_type, right_type)
      return right_type.type_id == "boolean"
    end,
    ["literal_boolean"] = function(left_type, right_type)
      return right_type.type_id == "literal_boolean" and right_type.value == left_type.value
    end,
    ["function"] = function(left_type, right_type)
      return right_type.type_id == "function"
    end,
    ["literal_function"] = function(left_type, right_type)
      return right_type.type_id == "literal_function" and right_type.func == left_type.func
    end,
    ["userdata"] = function(left_type, right_type)
      return right_type.type_id == "userdata"
    end,
    ["thread"] = function(left_type, right_type)
      return right_type.type_id == "thread"
    end,
    ["table"] = function(left_type, right_type)
      return right_type.type_id == "table"
    end,
    ["class"] = function(left_type, right_type)
      -- TODO: compare kvps
      return right_type.type_id == "class"
        and right_type.is_table == left_type.is_table
        and right_type.is_userdata == left_type.is_userdata
    end,
    ["union"] = function(left_type, right_type)
      if right_type.type_id == "intersection" then
        -- `intersection(union(string(), number()), union(string(), boolean()))` is a valid type
        -- and is equal to `string()`. And I hate it.
        -- TODO: table flip
      elseif right_type.type_id == "union" then
        -- NOTE: this whole comparison works based on the assumption [...]
        -- that a union does not contain the same type twice
        if #left_type.inner_types ~= #right_type.inner_types then
          return false
        end
        local right_lut = {} -- prevent comparing against the same right inner type twice
        for _, inner_type in ipairs(right_type.inner_types) do
          right_lut[inner_type] = true
        end
        for _, left_inner_type in ipairs(left_type.inner_types) do
          for _, right_inner_type in ipairs(right_type.inner_types) do
            if not right_lut[right_type] and equals(left_inner_type, right_inner_type) then
              right_lut[right_type] = nil
              goto got_right_match
            end
          end
          do return false end
          ::got_right_match::
        end
        return true
      elseif right_type.type_id == "inverted" then
        -- TODO: flip the table even more
      end
      -- a union of a single type does not exist, therefore this is always false at this point
      return false
    end,
    ["intersection"] = function(left_type, right_type)
      if right_type.type_id == "intersection" then
        -- TODO: impl
      elseif right_type.type_id == "inverted" then
        -- TODO: impl
      end
      return false
    end,
    ["inverted"] = function(left_type, right_type)
      if right_type.type_id == "inverted" then
        return equals(left_type.inverted_type, right_type.inverted_type)
      end
      return false -- TODO: think
    end,
  }
  function equals(left_type, right_type)
    -- prevent types that contain other types from being on the right side,
    -- unless both sides have the same type_id. and "class"es can be on the right side
    if left_type.type_id ~= right_type.type_id then
      if right_type.type_id == "union"
        or right_type.type_id == "intersection"
        or right_type.type_id == "inverted"
      then
        -- this means that "union" can have "intersection" and "inverted" as the right_type
        -- "intersection" can have "inverted" as the right_type
        -- and of course all of them can have their own type_id as the right_type
        return equals(right_type, left_type)
      end
    end
    return equals_lut[left_type.type_id](left_type, right_type)
  end
end

-- how to intersect these 2:
-- union{literal_number(1), literal_number(2)}
-- literal_number(1)
-----
-- intersect literal_number(1) with literal_number(1), get literal_number(1)
-- intersect literal_number(2) with literal_number(1), get empty()
-- return union(literal_number(1), empty())
--------------------------------------------------
-- how to intersect these 2:
-- inverted(literal_number(1))
-- literal_number(2)
-----
-- intersect literal_number(1) with literal_number(2), get empty()
-- remove empty() from literal_number(2), get literal_number(2)
-- return literal_number(2)
--------------------------------------------------
-- how to intersect these 2:
-- inverted(literal_number(1))
-- inverted(literal_number(2))
-----
-- intersect literal_number(1) with inverted(literal_number(2)), get literal_number(1)
-- remove literal_number(1) from inverted(literal_number(2)),
--   get inverted(union(literal_number(2), literal_number(1)))
-- return inverted(union(literal_number(2), literal_number(1)))
-- so might as well just create an inverted union when intersecting 2 inverted types
--------------------------------------------------
-- how to intersect these 2:
-- inverted(union(literal_number(1), literal_number(2)))
-- union(literal_number(2), literal_number(3))
-----
-- intersect union(literal_number(1), literal_number(2)) with union(literal_number(2), literal_number(3)),
--   get literal_number(2)
-- remove literal_number(2) from union(literal_number(2), literal_number(3)), get literal_number(3)
-- return literal_number(3)
--------------------------------------------------
-- how to intersect these 2:
-- intersection(inverted(literal_number(1)), inverted(literal_number(2))
-- literal_number(1)
-----
-- intersect inverted(literal_number(1)) with literal_number(1), get empty()
-- intersect inverted(literal_number(2)) with literal_number(1), get literal_number(1)
-- return intersection(empty(), literal_number(1))
--------------------------------------------------
-- how to intersect an intersection type with some other type:
-- intersect each joined type individually
--------------------------------------------------
-- an intersect on an inverted type really is just removing the inverted_type from the other type

local smart_union
local smart_intersection
do
  local function smart_inner_types(types)
    local inner_types = {}
    for _, type in ipairs(types) do
      if type.type_id == "union" then
        for _, inner_type in ipairs(type.inner_types) do
          inner_types[#inner_types+1] = inner_type
        end
      else
        inner_types[#inner_types+1] = type
      end
    end
    return inner_types
  end

  ---does **not** copy `left_type` nor `right_type`
  function smart_union(types)
    if not types[1] then return nil end
    if not types[2] then return types[1] end
    return new_union{inner_types = smart_inner_types(types)}
  end

  ---does **not** copy `left_type` nor `right_type`
  function smart_intersection(types)
    if not types[1] then return nil end
    if not types[2] then return types[1] end
    return new_intersection{inner_types = smart_inner_types(types)}
  end
end

local intersect
do
  local function intersect_primitive_factory(primitive_type)
    return function(left_type, right_type)
      if right_type.type_id == primitive_type or right_type.type_id == "literal_"..primitive_type then
        return copy_type(right_type)
      end
    end
  end
  local function intersect_literal_primitive_factory(primitive_type)
    return function(left_type, right_type)
      if right_type.type_id == primitive_type
        or (right_type.type_id == ("literal_"..primitive_type) and left_type.value == right_type.value)
      then
        return copy_type(left_type)
      end
    end
  end
  local function intersect_collection(left_types, right_type)
    local result_types = {}
    for _, left_type in ipairs(left_types) do
      local intersected = intersect(left_type, right_type)
      if intersected.type_id ~= "empty" then
        result_types[#result_types+1] = intersected
      end
    end
    return result_types
  end
  ---indexed by `left_type.type_id`
  local intersect_lut = {
    ["any"] = function(left_type, right_type)
      return copy_type(right_type)
    end,
    ["empty"] = function(left_type, right_type)
    end,
    ["nil"] = function(left_type, right_type)
      if right_type.type_id == "nil" then
        return new_nil{}
      end
    end,
    ["string"] = intersect_primitive_factory("string"),
    ["literal_string"] = intersect_literal_primitive_factory("string"),
    ["number"] = intersect_primitive_factory("number"),
    ["literal_number"] = intersect_literal_primitive_factory("number"),
    ["boolean"] = intersect_primitive_factory("boolean"),
    ["literal_boolean"] = intersect_literal_primitive_factory("boolean"),
    ["function"] = intersect_primitive_factory("function"), -- it's not "primitive", it's the same logic though
    ["literal_function"] = function(left_type, right_type) -- same logic here as well, but using `func`
      if right_type.type_id == "function"
        or (right_type.type_id == "literal_function" and left_type.func == right_type.func)
      then
        return copy_type(left_type)
      end
    end,
    ["userdata"] = function(left_type, right_type)
      if right_type.type_id == "userdata"
        or (right_type.type_id == "class" and right_type.is_userdata)
      then
        return copy_type(right_type)
      end
    end,
    ["thread"] = function(left_type, right_type)
      if right_type.type_id == "thread" then
        return new_thread{}
      end
    end,
    ["table"] = function(left_type, right_type)
      if right_type.type_id == "table"
        or (right_type.type_id == "class" and right_type.is_table)
      then
        return copy_type(right_type)
      end
    end,
    ["class"] = function(left_type, right_type)
      if right_type.type_id == "class" then
        local result = new_class{
          is_table = left_type.is_table and right_type.is_table,
          is_userdata = left_type.is_userdata and right_type.is_userdata,
        }
        if not result.is_table and not result.is_userdata then
          return
        end
        for _, left_kvp in ipairs(left_type.kvps) do
          for _, right_kvp in ipairs(right_type.kvps) do
            local key = intersect(left_kvp.key_type, right_kvp.key_type)
            -- TODO: properly compare types for equality
            if key.type_id ~= "empty" then
              result.kvps[#result.kvps+1] = {
                key_type = key,
                value_type = intersect(left_kvp.value_type, right_kvp.value_type),
              }
            end
          end
        end
        return result
      elseif right_type.type_id == "table" then
        if left_type.is_table then
          return copy_type(left_type)
        end
      elseif right_type.type_id == "userdata" then
        if left_type.is_userdata then
          return copy_type(left_type)
        end
      end
    end,
    ["union"] = function(left_type, right_type)
      return smart_union(intersect_collection(left_type.inner_types, right_type))
    end,
    ["intersection"] = function(left_type, right_type)
      return smart_intersection(intersect_collection(left_type.inner_types, right_type))
    end,
    ["inverted"] = function(left_type, right_type)
      -- if right_type.type_id == "inverted" then
      --   return new_inverted{inverted_type = smart_union(
      --     copy_type(left_type.inverted_type),
      --     copy_type(right_type.inverted_type)
      --   )}
      -- end
      -- NOTE: this is the only case where intersect resorts to creating a plain intersection of 2 types
      -- TODO: really think about when this could result in an empty type. When it does it should return empty
      return smart_intersection{
        copy_type(left_type),
        copy_type(right_type),
      }
      -- return exclude(right_type, left_type.inverted_type)
    end,
  }
  ---@param left_type ILType
  ---@param right_type ILType
  function intersect(left_type, right_type)
    -- prevent types that contain other types from being on the right side,
    -- unless both sides have the same type_id. and "class"es can be on the right side
    if left_type.type_id ~= right_type.type_id then
      if right_type.type_id == "any" -- also flip any so we don't have to check for it everywhere
        or right_type.type_id == "union"
        or right_type.type_id == "intersection"
        or right_type.type_id == "inverted"
      then
        -- this means that "any" can have "union", "intersection" and "inverted" as the right_type
        -- "union" can have "intersection" and "inverted" as the right_type
        -- "intersection" can have "inverted" as the right_type
        -- and of course all of them can have their own type_id as the right_type
        return intersect(right_type, left_type)
      end
    end
    local result_type = intersect_lut[left_type.type_id](left_type, right_type) or new_empty{}
    -- NOTE: `inferred` spreads like a disease with this implementation
    result_type.inferred = left_type.inferred or right_type.inferred
    return result_type
  end
end

local contains
do
  -- right type is never a "union" nor "intersection"
  local contains_lut = {
    ["any"] = function(left_type, right_type)
      if right_type.type_id == "inverted" then
        return right_type.inverted_type.type_id == "empty"
      end
      return true
    end,
    ["empty"] = function(left_type, right_type)
      return false
    end,
    ["nil"] = function(left_type, right_type)
      if right_type.type_id == "nil" then
        return true
      end
      return false
    end,
    ["string"] = function(left_type, right_type)
      return right_type.type_id == "string" or right_type.type_id == "literal_string"
    end,
    ["literal_string"] = function(left_type, right_type)
      return right_type.type_id == "literal_string" and right_type.value == left_type.value
    end,
    ["number"] = function(left_type, right_type)
      return right_type.type_id == "number" or right_type.type_id == "literal_number"
    end,
    ["literal_number"] = function(left_type, right_type)
      return right_type.type_id == "literal_number" and right_type.value == left_type.value
    end,
    ["boolean"] = function(left_type, right_type)
      return right_type.type_id == "boolean" or right_type.type_id == "literal_boolean"
    end,
    ["literal_boolean"] = function(left_type, right_type)
      return right_type.type_id == "literal_boolean" and right_type.value == left_type.value
    end,
    ["function"] = function(left_type, right_type)
      return right_type.type_id == "function" or right_type.type_id == "literal_function"
    end,
    ["literal_function"] = function(left_type, right_type)
      return right_type.type_id == "literal_function" and right_type.func == left_type.func
    end,
    ["userdata"] = function(left_type, right_type)
      return right_type.type_id == "userdata"
        or (right_type.type_id == "table" and right_type.is_userdata)
    end,
    ["thread"] = function(left_type, right_type)
      return right_type.type_id == "thread"
    end,
    ["table"] = function(left_type, right_type)
      return right_type.type_id == "table"
        or (right_type.type_id == "table" and right_type.is_table)
    end,
    ["class"] = function(left_type, right_type)
      if right_type.type_id ~= "class"
        or (right_type.is_table and not left_type.is_table)
        or (right_type.is_userdata and not left_type.is_userdata)
      then
        return false
      end
      for _, left_kvp in ipairs(right_type.kvps) do
        for _, right_kvp in ipairs(left_type.kvps) do
          -- TODO: instead of checking contains, use intersections. When not empty, check if
          -- the right value type is contained, if yes add the current intersection to a union.
          -- then check if the current union is equal to the right key_type
          -- and only if that is true then the current right kvp is contained
          if contains(left_kvp.key_type, right_kvp.key_type) then
            if contains(left_kvp.value_type, right_kvp.value_type) then
              goto is_contained
            end
          end
        end
        do return false end
        ::is_contained::
      end
      return true
    end,
    ["union"] = function(left_type, right_type)
      for _, inner_type in ipairs(left_type.inner_types) do
        if contains(inner_type, right_type) then
          return true
        end
      end
      return false
    end,
    ["intersection"] = function(left_type, right_type)
      for _, inner_type in ipairs(left_type.inner_types) do
        if not contains(inner_type, right_type) then
          return false
        end
      end
      return true
    end,
    ["inverted"] = function(left_type, right_type)
      if right_type.type_id == "inverted" then
        return contains(right_type.inverted_type, left_type.inverted_type) -- flipped
      end
      local intersected = intersect(left_type.inverted_type, right_type)
      -- TODO: properly compare types for equality
      return intersected.type_id == "empty"
    end,
  }
  ---@param left_type ILType
  ---@param right_type ILType
  function contains(left_type, right_type)
    if right_type.type_id == "empty" then
      return true
    elseif right_type.type_id == "union" then
      for _, inner_type in ipairs(right_type.inner_types) do
        if not contains(left_type, inner_type) then
          return false
        end
      end
      return true
    elseif right_type.type_id == "intersection" then
      -- TODO: similar to a class containing another class, keep track of intersections, create a union and
      -- check if the union is equal to the current type. Although now i'm scared of type equality
      for _, inner_type in ipairs(right_type.inner_types) do
        if contains(left_type, inner_type) then
          return true
        end
      end
      return false
    end
    return contains_lut[left_type.type_id](left_type, right_type)
  end
end

-- TODO: type indexing
-- TODO: type normalization

local logical_binop_lut = util.invert{"==", "<", "<=", "~=", ">=", ">"}
local function is_logical_binop(inst)
  return logical_binop_lut[inst.op]
end

return {
  new_any = new_any,
  new_empty = new_empty,
  new_nil = new_nil,
  new_string = new_string,
  new_literal_string = new_literal_string,
  new_number = new_number,
  new_literal_number = new_literal_number,
  new_boolean = new_boolean,
  new_literal_boolean = new_literal_boolean,
  new_function = new_function,
  new_literal_function = new_literal_function,
  new_userdata = new_userdata,
  new_thread = new_thread,
  new_table = new_table,
  new_class = new_class,
  new_union = new_union,
  new_intersection = new_intersection,
  new_inverted = new_inverted,
  make_type_from_ptr = make_type_from_ptr,
  is_logical_binop = is_logical_binop,
}
