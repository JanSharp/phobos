
local phobos_consts = require("constants")
local binary = require("binary_serializer")
---@type BinarySerializer
local serializer

local function dump_phobos_debug_symbols(func)
  -- open string constant
  serializer:write_raw("\4") -- a "string" constant
  local string_size_reserve = serializer:reserve{length = serializer.use_int32 and 4 or 8}
  local start_length = serializer:get_length()

  -- signature
  serializer:write_raw(phobos_consts.phobos_signature)

  -- version
  do
    local version = phobos_consts.phobos_debug_symbol_version
    while true do
      if version >= 255 then
        serializer:write_raw("\xff")
        version = version - 255
      else
        serializer:write_uint8(version)
        break
      end
    end
  end

  -- uint32 column_defined (0 for unknown or main chunk)
  serializer:write_uint32(func.column_defined or 0)
  -- uint32 last_column_defined (0 for unknown or main chunk)
  serializer:write_uint32(func.last_column_defined or 0)

  -- uint32 num_instruction_positions (always same as num_instructions)
  -- uint32[] column (columns of each instruction)
  serializer:write_uint32(#func.instructions)
  for _, inst in ipairs(func.instructions) do
    serializer:write_uint32(inst.column or 0) -- 0 for unknown
  end

  -- uint32 num_sources
  serializer:write_uint32(0)
  -- string[] source (all sources used in this function)

  -- uint32 num_sections
  serializer:write_uint32(0)
  -- (uint32 instruction_index, uint32 file_index)[]

  -- close string constant
  serializer:write_raw("\0")
  serializer:write_to_reserved(string_size_reserve, function()
    serializer:write_size_t(serializer:get_length() - start_length)
  end)
end

---outputs locals that start after they end.
---those locals should be ignored when processing the data further\
---output indexes are one based including excluding
local function get_local_debug_symbols(func)
  local locals = {} -- output debug symbols
  local reg_stack = {} -- **zero based** array
  local top_reg = -1 -- **zero based**
  local function next_reg()
    return top_reg + 1
  end
  local function replace_reg_stack_entry(reg, new_entry)
    assert(reg < top_reg, "\z
      Attempt to replace entry in stack at register at or above top. \z
      Impossible as long as all debug registers have valid start and stop indexes \z
      (start_at <= stop_at, start_at and stop_at are 1 based including-including).\z
    ")
    local popped = {}
    for j = reg + 1, top_reg do
      popped[#popped+1] = reg_stack[j]
      -- stop just before the new one starts
      reg_stack[j].stop_at = new_entry.start_at - 1
    end
    -- stop just before the new one starts
    reg_stack[reg].stop_at = new_entry.start_at - 1
    reg_stack[reg] = new_entry
    locals[#locals+1] = new_entry
    for j, popped_entry in ipairs(popped) do
      local entry = {
        unnamed = popped_entry.unnamed,
        name = popped_entry.name,
        start_at = new_entry.start_at,
      }
      reg_stack[reg + j] = entry
      locals[#locals+1] = entry
    end
  end

  local start_at_lut = {}
  local stop_at_lut = {}

  local function add_to_lut(lut, index, reg)
    local regs = lut[index]
    if not regs then
      regs = {}
      lut[index] = regs
    end
    regs[#regs+1] = reg
  end

  for _, reg in ipairs(func.debug_registers) do
    -- TODO: The il compiler is outputting registers that stop before they start. Either fix that or [...]
    -- change the error message a little bit above to not complain about this issue, since the if condition
    -- below now prevents that error from happening
    if reg.name and reg.start_at <= reg.stop_at then
      add_to_lut(start_at_lut, reg.start_at, reg)
      add_to_lut(stop_at_lut, reg.stop_at, reg)
    end
  end

  for i = 1, #func.instructions do
    local regs = start_at_lut[i]
    if regs then
      for _, reg in ipairs(regs) do
        if reg.index >= next_reg() then
          for j = next_reg(), reg.index - 1 do
            local entry = {
              unnamed = true,
              name = phobos_consts.unnamed_register_name,
              start_at = reg.start_at,
            }
            reg_stack[j] = entry
            locals[#locals+1] = entry
          end
          top_reg = reg.index
          local entry = {
            name = reg.name,
            start_at = reg.start_at,
          }
          reg_stack[top_reg] = entry
          locals[#locals+1] = entry
        else -- live.index < next_reg()
          replace_reg_stack_entry(reg.index, {
            name = reg.name,
            start_at = reg.start_at,
          })
        end
      end
    end

    -- processing of registers that stopped has to be done
    -- _after_ **all** registers that started have been processed
    regs = stop_at_lut[i]
    if regs then
      for _, reg in ipairs(regs) do
        if reg.index ~= top_reg then
          replace_reg_stack_entry(reg.index, {
            unnamed = true,
            name = phobos_consts.unnamed_register_name,
            -- + 1 because this is for the new unnamed entry, not the actual one we are "stopping"
            start_at = reg.stop_at + 1
          })
        else
          reg_stack[top_reg].stop_at = reg.stop_at
          top_reg = top_reg - 1
          for j = top_reg, 0, -1 do
            if not reg_stack[j].unnamed then
              break
            end
            reg_stack[j].stop_at = reg.stop_at
            top_reg = j - 1
          end
        end
      end
    end
  end
  return locals
end

---@param func CompiledFunc
local function dump_function(func)
  -- int line_defined (0 for unknown or main chunk)
  serializer:write_uint32(func.line_defined or 0)
  -- int last_line_defined (0 for unknown or main chunk)
  serializer:write_uint32(func.last_line_defined or 0)
  assert(func.num_params)
  assert(func.max_stack_size >= 2)
  serializer:write_raw(string.char(
    func.num_params,           -- byte num_params
    func.is_vararg and 1 or 0, -- byte is_vararg
    func.max_stack_size        -- byte max_stack_size, min of 2, reg0/1 always valid
  ))

  -- [code]
  -- int num_instructions
  serializer:write_uint32(#func.instructions)
  -- Instruction[] instructions
  for _,instruction in ipairs(func.instructions) do
    local inst_int = instruction.op.id
    if instruction.ax then
      inst_int = inst_int + bit32.lshift(instruction.ax, 6)
    else
      if instruction.a then
        inst_int = inst_int + bit32.lshift(instruction.a, 6)
      end
      if instruction.bx then
        inst_int = inst_int + bit32.lshift(instruction.bx, 14)
      elseif instruction.sbx then
        inst_int = inst_int + bit32.lshift(instruction.sbx + 0x1ffff, 14)
      else
        if instruction.b then
          inst_int = inst_int + bit32.lshift(instruction.b, 23)
        end
        if instruction.c then
          inst_int = inst_int + bit32.lshift(instruction.c, 14)
        end
      end
    end
    serializer:write_uint32(inst_int)
  end


  -- [constants]
  -- int num_consts
  serializer:write_uint32(#func.constants + 1) -- + 1 for Phobos debug symbols
  -- TValue[] consts
  for _,constant in ipairs(func.constants) do
    serializer:write_lua_constant(constant)
  end

  -- when adding an option to disable these ensure to add an extra unused `nil` constant
  -- instead if the last constant happens to look just like Phobos debug symbols
  dump_phobos_debug_symbols(func)

  -- [func_protos]
  -- int num_funcs
  serializer:write_uint32(#func.inner_functions)
  -- dump_function[] funcs
  for _,f in ipairs(func.inner_functions) do
    dump_function(f)
  end

  -- [upvals]
  -- int num_upvals
  serializer:write_uint32(#func.upvals)
  -- upvals[] upvals
  for _,upval in ipairs(func.upvals) do
    -- byte in_stack (is a local in parent scope, else upvalue in parent scope)
    -- byte idx
    serializer:write_raw(string.char(
      upval.in_stack and 1 or 0,
      upval.in_stack and upval.local_idx or upval.upval_idx
    ))
  end

  -- [debug]
  -- string source
  -- considering stripped Lua bytecode has `null` source
  -- we don't need to have some default for when `func.source` is `nil`
  serializer:write_lua_string(func.source)

  -- int num_lines (always same as num_instructions)
  -- int[] lines (line number per instruction)
  serializer:write_uint32(#func.instructions)
  for i, instruction in ipairs(func.instructions) do
    serializer:write_uint32(instruction.line or 0)
  end

  -- int num_locals
  -- local_desc[] locals
  --   string name
  --   int start_pc
  --   int end_pc
  do
    local num_locals_reserve = serializer:reserve{length = 4}
    local num_locals = 0
    for _, loc in ipairs(get_local_debug_symbols(func)) do
      if loc.start_at <= loc.stop_at then
        num_locals = num_locals + 1
        ---cSpell:ignore getlocalname
        -- these must not be null. get_local_debug_symbols ensures that already
        -- Lua blindly dereferences this pointer when getting local names in `luaF_getlocalname`
        serializer:write_lua_string(loc.name)
        -- convert from one based including including
        -- to zero based including excluding
        serializer:write_uint32(loc.start_at - 1)
        serializer:write_uint32(loc.stop_at)
      end
    end
    serializer:write_to_reserved(num_locals_reserve, function()
      serializer:write_uint32(num_locals)
    end)
  end

  -- int num_upvals
  serializer:write_uint32(#func.upvals)
  -- string[] upvals
  for _,u in ipairs(func.upvals) do
    -- stripped Lua bytecode ultimately also ends up loading `null` for upval names
    -- so dumping `null` (`nil`) as the name should be fine
    serializer:write_lua_string(u.name)
  end
end

local function dump_lua_header()
  serializer:write_raw(serializer.use_int32
    and phobos_consts.lua_header_str_int32
    or phobos_consts.lua_header_str)
end

---@param main CompiledFunc
---@param options Options?
local function dump_main(main, options)
  serializer = binary.new_serializer(options)
  dump_lua_header()
  dump_function(main)
  local result = serializer:tostring()
  serializer = (nil)--[[@as BinarySerializer]] -- Free memory.
  return result
end

return dump_main
