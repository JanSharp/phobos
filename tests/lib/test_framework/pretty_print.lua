
local serpent = require("lib.serpent")

---@type table<string, fun(value: any, serpent_opts: table): string>
local default_pretty_printers = {
  ["number"] = function(value)
    if value ~= value then
      return "0/0"
    end
    if value == 1/0 then
      return "1/0"
    end
    if value == -1/0 then
      return "-1/0"
    end
    return tostring(value)
  end,
  ["string"] = function(value)
    return (string.format("%q", value):gsub("\r", [[\r]]))
  end,
  ["boolean"] = function(value)
    return tostring(value)
  end,
  ["nil"] = function(value)
    return "nil"
  end,
  ["table"] = function(value, serpent_opts)
    return serpent.block(value, serpent_opts)
  end,
  ["function"] = function(value)
    local info = debug.getinfo(value, "S")
    return "<"..tostring(value).." ("..info.short_src..")>"
  end,
  ["userdata"] = function(value)
    return tostring(value)
  end,
  ["thread"] = function(value)
    return tostring(value)
  end,
}

---@type table<string, fun(value: any, serpent_opts: table): string>
local custom_pretty_printers = {}

local function pretty_print(value, serpent_opts)
  local type = type(value)
  return (custom_pretty_printers[type] or default_pretty_printers[type])(value, serpent_opts)
end

local function default_pretty_print(value, serpent_opts)
  return default_pretty_printers[type(value)](value, serpent_opts)
end

return {
  custom_pretty_printers = custom_pretty_printers,
  pretty_print = pretty_print,
  default_pretty_print = default_pretty_print,
}
