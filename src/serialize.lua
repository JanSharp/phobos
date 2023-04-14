
---cSpell:ignore kvps

local type = type
local format = string.format

local out
local c
local next_id
local table_to_id
local back_ref_kvps
local back_ref_kvps_c

-- This cache never gets cleared and making it weak would make no difference, not even for string keys.
-- See: http://www.lua.org/manual/5.2/manual.html#2.5.2
-- It might be worth exposing a clear function
local cache = {
  [1/0] = "1/0", -- %a prints inf as "inf", not "1/0"
  [-1/0] = "-1/0", -- %a prints inf as "-inf", not "-1/0"
  -- save the type check for all booleans by simply putting them in the cache
  [false] = "false",
  [true] = "true",
}

local serialize_value

local function serialize_string(value)
  local result = format("%q", value)
  cache[value] = result
  return result
end

local function serialize_number(value)
  if value ~= value then -- %a prints nan as "nan", not "0/0"
    return "0/0"
  end
  -- to hexadecimal, because I feel like that'll restore correctly more often than not
  local result = format("%a", value)
  cache[value] = result
  return result
end

local function serialize_boolean(value)
  error("Impossible because booleans are in the cache.")
  return value and "true" or "false"
end

local function serialize_table(value)
  local id = table_to_id[value]
  if id ~= nil then
    return id
  end
  table_to_id[value] = false -- false for the duration of serializing keys and values
  local array_values = {}
  local array_c
  local kvps = {}
  local kvps_c = 0
  do
    local i = 0
    while true do
      i = i + 1
      local v = value[i]
      if v == nil then
        array_c = i - 1
        break
      end
      local v_str = serialize_value(v)
      array_values[i] = v_str -- assigns the string, or false in case of a back reference. never nil
      if not v_str then
        back_ref_kvps_c=back_ref_kvps_c+1;back_ref_kvps[back_ref_kvps_c] = {
          t = value,
          k_str = serialize_number(i),
          -- k = nil, -- not needed, k_str will never be 'false'
          v_str = v_str,
          v = v,
        }
      end
    end
  end
  for k, v in next, value do
    if array_values[k] ~= nil then goto continue end
    local k_str = serialize_value(k)
    local v_str = serialize_value(v)
    if k_str and v_str then
      kvps_c=kvps_c+1;kvps[kvps_c] = {
        k = k_str,
        v = v_str,
      }
    else
      back_ref_kvps_c=back_ref_kvps_c+1;back_ref_kvps[back_ref_kvps_c] = {
        t = value,
        k_str = k_str,
        k = k,
        v_str = v_str,
        v = v,
      }
    end
    ::continue::
  end
  id = "a["..next_id.."]"
  next_id = next_id + 1
  c=c+1;out[c] = id
  c=c+1;out[c] = "={"
  for i = 1, array_c do
    local v = array_values[i]
    if v then
      c=c+1;out[c] = v
      c=c+1;out[c] = ","
    else
      c=c+1;out[c] = "nil,"
    end
  end
  for i = 1, kvps_c do
    local kvp = kvps[i]
    c=c+1;out[c] = "["
    c=c+1;out[c] = kvp.k
    c=c+1;out[c] = "]="
    c=c+1;out[c] = kvp.v
    c=c+1;out[c] = ","
  end
  c=c+1;out[c] = "}"
  table_to_id[value] = id -- done generating, set for future references to the table
  return id
end

local function serialize_nil()
  return "nil"
end

local serialize_value_lut = setmetatable({
  ["string"] = serialize_string,
  ["number"] = serialize_number,
  ["boolean"] = serialize_boolean,
  ["table"] = serialize_table,
  ["nil"] = serialize_nil,
}, {
  __index = function(_, t)
    error("Attempt to serialize value of type '"..t.."'. \z
      Supported types: string, number, boolean, table, nil."
    )
  end,
})

function serialize_value(value)
  local cached = cache[value]
  if cached then
    return cached
  end
  return serialize_value_lut[type(value)](value)
end

local function resolve_back_references()
  for i = 1, back_ref_kvps_c do
    local kvp = back_ref_kvps[i]
    c=c+1;out[c] = table_to_id[kvp.t]
    c=c+1;out[c] = "["
    c=c+1;out[c] = kvp.k_str or table_to_id[kvp.k]
    c=c+1;out[c] = "]="
    c=c+1;out[c] = kvp.v_str or table_to_id[kvp.v]
    c=c+1;out[c] = ";"
  end
end

local function serialize(value)
  out = {}
  c = 0
  next_id = 1
  table_to_id = {}
  back_ref_kvps = {}
  back_ref_kvps_c = 0
  if type(value) == "table" then
    c=c+1;out[c] = "local a={}"
  end
  local result = serialize_value(value)
  resolve_back_references()
  c=c+1;out[c] = "return "
  c=c+1;out[c] = result
  return table.concat(out)
end

return serialize
