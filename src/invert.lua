--- Invert an array of keys to be a set of key=true
---@param t table<number,any>
---@return table<any,boolean>
local function invert(t)
    local tt = {}
    for _,s in pairs(t) do
      tt[s] = true
    end
    return tt
end
return invert