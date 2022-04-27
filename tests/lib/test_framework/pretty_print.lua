
local serpent = require("lib.serpent")

local custom_pretty_printers = {}

local function pretty_print(value, serpent_opts)
  local type = type(value)
  return (custom_pretty_printers[type] or ({
    ["number"] = function()
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
    ["string"] = function()
      return string.format("%q", value):gsub("\r", [[\r]])
    end,
    ["boolean"] = function()
      return tostring(value)
    end,
    ["nil"] = function()
      return "nil"
    end,
    ["table"] = function()
      return serpent.block(value, serpent_opts)
    end,
    ["function"] = function()
      local info = debug.getinfo(value, "S")
      return "<"..tostring(value).." ("..info.short_src..")>"
    end,
    ["userdata"] = function()
      return tostring(value)
    end,
    ["thread"] = function()
      return tostring(value)
    end,
  })[type])(value)
end

return {
  custom_pretty_printers = custom_pretty_printers,
  pretty_print = pretty_print,
}
