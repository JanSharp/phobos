
local serpent = require("lib.serpent")

local function pretty_print(value)
  return ({
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
      return serpent.block(value, {name = "value"})
    end,
    ["userdata"] = function()
      return tostring(value)
    end,
    ["thread"] = function()
      return tostring(value)
    end,
  })[type(value)]()
end

return pretty_print
