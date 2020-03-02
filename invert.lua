local function invert(t)
    local tt = {}
    for _,s in pairs(t) do
      tt[s] = true
    end
    return tt
end
return invert