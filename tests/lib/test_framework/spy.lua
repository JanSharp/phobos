
local hook_data_lut = {}

local function hook(table, field, on_call)
  local func = table[field]
  local hook_data = {
    table = table,
    field = field,
    original_func = func,
  }
  table[field] = function(...)
    on_call(...)
    return func(...)
  end
  hook_data_lut[table] = hook_data_lut[table] or {}
  hook_data_lut[table][field] = hook_data
end

local function unhook_internal(hook_data)
  hook_data.table[hook_data.field] = hook_data.original_func
end

local function unhook(table, field)
  unhook_internal(hook_data_lut[table][field])
  hook_data_lut[table][field] = nil
  if not next(hook_data_lut[table]) then
    hook_data_lut[table] = nil
  end
end

local function unhook_all()
  for _, hook_data_for_table in pairs(hook_data_lut) do
    for _, hook_data in pairs(hook_data_for_table) do
      unhook_internal(hook_data)
    end
  end
  hook_data_lut = {}
end

return {
  hook = hook,
  unhook = unhook,
  unhook_all = unhook_all,
}
