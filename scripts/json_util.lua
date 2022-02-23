
-- metatable fields
local order_field = "__json_order"
local comments_field = "__json_comments"
local array_flag = "__json_array"
local object_flag = "__json_object"

local to_json
do
  local indent
  local use_trailing_comma
  local comment_prefix
  local comment_prefix_for_empty_line
  local default_empty_table_type

  local out
  local out_count
  local function add(str)
    out_count = out_count + 1
    out[out_count] = str
  end
  local table_stack = {}
  local depth

  local force_newline_again
  local function add_indent(force_newline)
    if indent then
      add("\n")
      add(string.rep(indent, depth))
    elseif force_newline then
      add("\n")
      force_newline_again = true
    elseif force_newline_again then
      add("\n")
      force_newline_again = false
    end
  end

  local function add_comment(comment)
    if not comment then
      return
    end
    local function add_line(line)
      add_indent(true)
      add(line == "" and comment_prefix_for_empty_line or comment_prefix)
      add(line)
    end
    add_line(comment:match("^[^\n]*"))
    for line in comment:gmatch("\n([^\n]*)") do
      add_line(line)
    end
  end

  local function deal_with_trailing_commas()
    local prev_is_comma = out[out_count] == ","
    if not use_trailing_comma and prev_is_comma then
      out_count = out_count - 1
      -- the comma will be overwritten right afterwards in the calling functions
    end
    return prev_is_comma
  end

  local serialize

  local function serialize_array(value)
    add("[")
    depth = depth + 1
    local table_size = 0
    for k in pairs(value) do
      table_size = table_size + 1
      assert(type(k) == "number", "Unable to serialize table with key of type '"..type(k).."' in a json array.")
      assert(k < (1/0) and k > 0 and (k % 1) == 0, "Invalid number '"..k.."' as key in an array.")
    end
    local meta = getmetatable(value)
    local comments = meta and meta[comments_field]
    local i = 1
    local c = 0
    while c < table_size do
      add_comment(comments and comments[i])
      add_indent()
      local v = value[i]
      serialize(v)
      add(",")
      if v ~= nil then
        c = c + 1
      end
      i = i + 1
    end
    local has_or_had_comma = deal_with_trailing_commas()
    depth = depth - 1
    if has_or_had_comma then -- this check makes empty arrays look like `[]`
      add_indent()
    end
    add("]")
  end

  local function serialize_kvp(k, v)
    assert(type(k) == "string", "Unable to serialize table with key of type '"..type(k).."' in a json object.")
    add_indent()
    serialize(k)
    add(indent and ": " or ":")
    serialize(v)
    add(",")
  end

  local function serialize_object(value)
    add("{")
    depth = depth + 1
    local meta = getmetatable(value)
    local comments = meta and meta[comments_field]
    local finished_keys = {}
    if meta and meta[order_field] then
      for _, k in ipairs(meta[order_field]) do
        if value[k] then
          add_comment(comments and comments[k])
          finished_keys[k] = true
          serialize_kvp(k, value[k])
        end
      end
    end
    local leftover_keys = {}
    for k in pairs(value) do
      if not finished_keys[k] then
        leftover_keys[#leftover_keys+1] = k
      end
    end
    table.sort(leftover_keys)
    for _, k in ipairs(leftover_keys) do
      add_comment(comments and comments[k])
      serialize_kvp(k, value[k])
    end
    local has_or_had_comma = deal_with_trailing_commas()
    depth = depth - 1
    if has_or_had_comma then -- this check makes empty arrays look like `[]`
      add_indent()
    end
    add("}")
  end

  function serialize(value)
    (({
      ["string"] = function()
        add('"')
        add(value:gsub("[\n\r\t\v\"]", {
          ["\n"] = [[\n]],
          ["\r"] = [[\r]],
          ["\t"] = [[\t]],
          ["\v"] = [[\v]],
          ["\""] = [[\"]],
        }))
        add('"')
      end,
      ["number"] = function()
        add(tostring(value)) -- TODO: what number format does json use
      end,
      ["boolean"] = function()
        add(tostring(value))
      end,
      ["nil"] = function()
        add("null")
      end,
      ["table"] = function()
        if table_stack[value] then
          error("Cannot serialize recursive tables")
        end
        table_stack[value] = true
        local meta = getmetatable(value)
        if meta and meta[array_flag] then
          serialize_array(value)
        elseif meta and meta[object_flag] then
          serialize_object(value)
        else
          -- figure it out manually
          local k = next(value)
          if not k then
            if default_empty_table_type == "array" then
              serialize_array(value)
            elseif default_empty_table_type == "object" then
              serialize_object(value)
            else
              error("Cannot serialize an empty table without an array or object flag, \z
                since it could be either. Set the 'default_empty_table_type' option to either \z
                'array' or 'object' to define how empty tables should be serialized when their \z
                metatables do not have the 'array_flag' nor the 'object_flag'."
              )
            end
          elseif type(k) == "number" then
            serialize_array(value)
          else
            serialize_object(value)
          end
        end
        table_stack[value] = nil
      end,
    })[type(value)] or function()
      error("Cannot serialize value of type '"..type(value).."' to json.")
    end)()
  end

  function to_json(value, options)
    indent = options and options.indent
    use_trailing_comma = options and options.use_trailing_comma
    comment_prefix = options and options.comment_prefix or "// "
    comment_prefix_for_empty_line = options and options.comment_prefix_for_empty_line or "//"
    default_empty_table_type = options and options.default_empty_table_type
    out = {}
    out_count = 0
    depth = 0
    serialize(value)
    return table.concat(out)
  end
end

---using this is completely optional unless the table is empty.
---in that case either use this function or define the `default_empty_table_type` option when serializing
local function new_array(tab)
  return setmetatable(tab, {[array_flag] = true})
end

---using this is completely optional unless the table is empty.
---in that case either use this function or define the `default_empty_table_type` option when serializing
local function new_object(tab)
  return setmetatable(tab, {[object_flag] = true})
end

local function set_comment(tab, key, comment)
  local meta = getmetatable(tab)
  if not meta then
    meta = {}
    setmetatable(tab, meta)
  end
  meta[comments_field] = meta[comments_field] or {}
  meta[comments_field][key] = comment
end

---@param comments table<number|string, string>
local function set_comments(tab, comments)
  local meta = getmetatable(tab)
  if not meta then
    meta = {}
    setmetatable(tab, meta)
  end
  meta[comments_field] = comments
end

---only useful for json objects
---@param key_order string[]
local function set_order(tab, key_order)
  local meta = getmetatable(tab)
  if not meta then
    meta = {}
    setmetatable(tab, meta)
  end
  meta[order_field] = key_order
end

return {
  to_json = to_json,
  new_array = new_array,
  new_object = new_object,
  set_comment = set_comment,
  set_comments = set_comments,
  set_order = set_order,
}
