
local phobos_consts = require("constants")

---@return string dumped_integer
---@return integer byte_count
local function DumpInt(i)
  -- int is 4 bytes
  -- **little endian**
  return string.char(
    bit32.band(             i    ,0xff),
    bit32.band(bit32.rshift(i,8 ),0xff),
    bit32.band(bit32.rshift(i,16),0xff),
    bit32.band(bit32.rshift(i,24),0xff)
  ), 4
end

---@return string dumped_size
---@return integer byte_count
local function DumpSize(s)
  -- size_t is 8 bytes
  -- but i really only support 32bit for now, so just write four extra zeros
  -- maybe expand this one day to 48bit? maybe all the way to 53?
  -- If i'm compiling a program with >4gb strings, something has gone horribly wrong anyway
  return DumpInt(s) .. "\0\0\0\0", 8
end

local DumpDouble
do
  local s , e = string.dump(load[[return 523123.123145345]])
                      :find("\3\54\208\25\126\204\237\31\65")
  if s == nil then
    error("Unable to set up double to bytes conversion")
  end
  local double_cache = {
    -- these two don't print %a correctly, so preload the cache with them
    -- **little endian**
    [1/0] = "\3\0\0\0\0\0\0\xf0\x7f",
    [-1/0] = "\3\0\0\0\0\0\0\xf0\xff",
  }
  function DumpDouble(d)
    if d ~= d then
      -- nan
      return "\3\xff\xff\xff\xff\xff\xff\xff\xff"
    elseif double_cache[d] then
      return double_cache[d]
    else
      local double_str = string.dump(load(([[return %a]]):format(d))):sub(s,e)
      double_cache[d] = double_str
      return double_str
    end
  end
end

---all strings can be nil, except in the constant table\
---@return string dumped_string
---@return integer byte_count
local function DumpString(str)
  -- typedef string:
  -- size_t length (including trailing \0, 0 for nil)
  -- char[] value (not present for nil)
  if not str then
    return DumpSize(0), 8
  else
    return DumpSize(#str + 1) .. str .. "\0", 8 + #str + 1
  end
end

--   byte type={nil=0,boolean=1,number=3,string=4}
local dumpConstantByType = {
  ["nil"] = function() return "\0" end,
--   <boolean> byte value
  ["boolean"] = function(val) return val and "\1\1" or "\1\0" end,
--   <number> double value
-- DumpDouble has the \3 type tag already
  ["number"] = DumpDouble,
--   <string> string value
  ["string"] = function(val) return "\4" .. DumpString(val) end,
}
local function DumpConstant(constant)
  return dumpConstantByType[type(constant.value)](constant.value)
end

local function DumpPhobosDebugSymbols(dump, func)
  -- open string constant
  dump[#dump+1] = "\4" -- a "string" constant
  local i = #dump + 1 -- + 1 to reserve a slot for the string size
  local size_entry_index = i
  local byte_count = 0
  local function add(entry, entry_byte_count)
    i = i + 1
    byte_count = byte_count + entry_byte_count
    dump[i] = entry
  end

  -- signature
  add(phobos_consts.phobos_signature, 7)

  -- version
  do
    local version = phobos_consts.phobos_debug_symbol_version
    while true do
      if version >= 255 then
        add("\xff", 1)
        version = version - 255
      else
        add(string.char(version), 1)
        break
      end
    end
  end

  -- uint32 column_defined (0 for unknown or main chunk)
  add(DumpInt(func.column_defined or 0))
  -- uint32 last_column_defined (0 for unknown or main chunk)
  add(DumpInt(func.last_column_defined or 0))

  -- uint32 num_instruction_positions (always same as num_instructions)
  -- uint32[] column (columns of each instruction)
  add(DumpInt(#func.instructions))
  for _, inst in ipairs(func.instructions) do
    add(DumpInt(inst.column or 0)) -- 0 for unknown
  end

  -- uint32 num_sources
  add(DumpInt(0))
  -- string[] source (all sources used in this function)

  -- uint32 num_sections
  add(DumpInt(0))
  -- (uint32 instruction_index, uint32 file_index)[]

  -- close string constant
  add("\0", 1)
  dump[size_entry_index] = DumpSize(byte_count)
end

---outputs locals that start after they end.
---those locals should be ignored when processing the data further\
---output indexes are one based including excluding
local function GetLocalDebugSymbols(func)
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
    if reg.name then
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
local function DumpFunction(func)
  local dump = {}
  -- int line_defined (0 for unknown or main chunk)
  dump[#dump+1] = DumpInt(func.line_defined or 0)
  -- int last_line_defined (0 for unknown or main chunk)
  dump[#dump+1] = DumpInt(func.last_line_defined or 0)
  assert(func.num_params)
  assert(func.max_stack_size >= 2)
  dump[#dump+1] = string.char(
    func.num_params,           -- byte num_params
    func.is_vararg and 1 or 0, -- byte is_vararg
    func.max_stack_size        -- byte max_stack_size, min of 2, reg0/1 always valid
  )

  -- [Code]
  -- int num_instructions
  dump[#dump+1] = DumpInt(#func.instructions)
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
    dump[#dump+1] = DumpInt(inst_int)
  end


  -- [Constants]
  -- int num_consts
  dump[#dump+1] = DumpInt(#func.constants + 1) -- + 1 for phobos debug symbols
  -- TValue[] consts
  for _,constant in ipairs(func.constants) do
    dump[#dump+1] = DumpConstant(constant)
  end

  -- when adding an option to disable these ensure to add an extra unused `nil` constant
  -- instead if the last constant happens to look just like phobos debug symbols
  DumpPhobosDebugSymbols(dump, func)

  -- [func_protos]
  -- int num_funcs
  dump[#dump+1] = DumpInt(#func.inner_functions)
  -- DumpFunction[] funcs
  for _,f in ipairs(func.inner_functions) do
    dump[#dump+1] = DumpFunction(f)
  end

  -- [Upvals]
  -- int num_upvals
  dump[#dump+1] = DumpInt(#func.upvals)
  -- upvals[] upvals
  for _,upval in ipairs(func.upvals) do
    -- byte in_stack (is a local in parent scope, else upvalue in parent scope)
    -- byte idx
    dump[#dump+1] = string.char(
      upval.in_stack and 1 or 0,
      upval.in_stack and upval.local_idx or upval.upval_idx
    )
  end

  -- [Debug]
  -- string source
  dump[#dump+1] = DumpString(func.source --[[or "(unknown phobos source)"]]) -- TODO: how does nil behave

  -- int num_lines (always same as num_instructions)
  -- int[] lines (line number per instruction)
  dump[#dump+1] = DumpInt(#func.instructions)
  for i, instruction in ipairs(func.instructions) do
    dump[#dump+1] = DumpInt(instruction.line or 0)
  end

  -- int num_locals
  -- local_desc[] locals
  --   string name
  --   int start_pc
  --   int end_pc
  do
    dump[#dump+1] = 0 -- set later
    local num_locals_index = #dump
    local num_locals = 0
    local temp = {}
    for _, loc in ipairs(GetLocalDebugSymbols(func)) do
      if loc.start_at <= loc.stop_at then
        temp[#temp+1] = loc
        num_locals = num_locals + 1
        dump[#dump+1] = DumpString(loc.name)
        -- convert from one based including including
        -- to zero based including excluding
        dump[#dump+1] = DumpInt(loc.start_at - 1)
        dump[#dump+1] = DumpInt(loc.stop_at)
      end
    end
    dump[num_locals_index] = DumpInt(num_locals)
  end

  -- int num_upvals
  dump[#dump+1] = DumpInt(#func.upvals)
  -- string[] upvals
  for _,u in ipairs(func.upvals) do
    dump[#dump+1] = DumpString(u.name) -- TODO: how to deal with nil names?
  end

  -- lua will stop reading here
  -- extra phobos debug sections:
  -- Phobos signature: "\x1bPhobos"
  -- byte version = "\x01"
  -- [branch annotations]
  -- int num_branches

  return table.concat(dump)
end

local function DumpLuaHeader()
  return phobos_consts.lua_header_str
end

local function DumpMain(main)
  return DumpLuaHeader() .. DumpFunction(main)
end

return DumpMain
