
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
      local str = string.format("%q", value):gsub("[\r\n]", {["\r"] = "\\r", ["\n"] = "\\n"})
      if #str > 32 then
        return str:sub(1, 16).."..."..str:sub(-16, -1)
          .." (showing 32 of "..#str.." characters)"
      end
      return str
    end,
    ["boolean"] = function()
      return tostring(value)
    end,
    ["nil"] = function()
      return "nil"
    end,
    ["table"] = function()
      return "<table>"
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
