local function DumpInt(i)
  -- int is 4 bytes
  return string.char(
    bit32.band(             i    ,0xff),
    bit32.band(bit32.rshift(i,8 ),0xff),
    bit32.band(bit32.rshift(i,16),0xff),
    bit32.band(bit32.rshift(i,24),0xff)
  )
end

local function DumpSize(s)
  -- size_t is 8 bytes
  -- but i really only support 32bit for now, so just write four extra zeros
  -- maybe expand this one day to 48bit? maybe all the way to 53?
  -- If i'm compiling a program with >4gb strings, something has gone horribly wrong anyway
  return DumpInt(s) .. "\0\0\0\0"
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
    [1/0] = "\3\x7f\xf0\0\0\0\0\0\0",
    [-1/0] = "\3\xff\xf0\0\0\0\0\0\0",
  }
  function DumpDouble(d)
    if d ~= d then
      -- nan
      return "\3\x7f\xff\xff\xff\xff\xff\xff\xff"
    elseif double_cache[d] then
      return double_cache[d]
    else
      local double_str = string.dump(load(([[return %a]]):format(d))):sub(s,e)
      double_cache[d] = double_str
      return double_str
    end
  end
end

---all strings can be nil, except in the constant table
local function DumpString(str)
  -- typedef string:
  -- size_t length (including trailing \0, 0 for nil)
  -- char[] value (not present for nil)
  if not str then
    return DumpSize(0)
  else
    return DumpSize(#str + 1) .. str .. "\0"
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
local function DumpConstant(val)
  return dumpConstantByType[type(val)](val)
end

---@param func GeneratedFunc
local function DumpFunction(func)
  local dump = {}
  -- int line_defined (0 for main chunk)
  dump[#dump+1] = DumpInt(func.line)
  -- int last_line_defined (0 for main chunk)
  dump[#dump+1] = DumpInt(func.end_line)
  dump[#dump+1] = string.char(
    func.n_params or 0,        -- byte n_params
    func.is_vararg and 1 or 0, -- byte is_vararg
    func.max_stack_size or 2    -- byte max_stack_size, min of 2, reg0/1 always valid
  )

  -- [Code]
  -- int n_instructions
  dump[#dump+1] = DumpInt(#func.instructions)
  -- Instruction[] instructions
  for _,instruction in ipairs(func.instructions) do
    local opcode = instruction.op
    if instruction.ax then
      opcode = opcode + bit32.lshift(instruction.ax, 6)
    else
      if instruction.a then
        opcode = opcode + bit32.lshift(instruction.a, 6)
      end
      if instruction.bx then
        opcode = opcode + bit32.lshift(instruction.bx, 14)
      elseif instruction.sbx then
        opcode = opcode + bit32.lshift(instruction.sbx + 0x1ffff, 14)
      else
        if instruction.b then
          opcode = opcode + bit32.lshift(instruction.b, 23)
        elseif instruction.bk then ---@diagnostic disable-line: undefined-field -- TODO: remove
          error()
        end
        if instruction.c then
          opcode = opcode + bit32.lshift(instruction.c, 14)
        elseif instruction.ck then ---@diagnostic disable-line: undefined-field -- TODO: remove
          error()
        end
      end
    end
    dump[#dump+1] = DumpInt(opcode)
  end


  -- [Constants]
  -- int n_consts
  dump[#dump+1] = DumpInt(#func.constants)
  -- TValue[] consts
  for _,constant in ipairs(func.constants) do
    dump[#dump+1] = DumpConstant(constant)
  end

  -- [func_protos]
  -- int n_funcs
  dump[#dump+1] = DumpInt(#func.func_protos)
  -- DumpFunction[] funcs
  for _,f in ipairs(func.func_protos) do
    dump[#dump+1] = DumpFunction(f)
  end

  -- [Upvals]
  -- int n_upvals
  dump[#dump+1] = DumpInt(#func.upvals)
  -- upvals[] upvals
  for _,u in ipairs(func.upvals) do
    -- byte in_stack (is a local in parent scope, else upvalue in parent scope)
    -- byte idx
    dump[#dump+1] = string.char(u.parent_def.def_type == "local" and 1 or 0, u.parent_def.index or 0)
  end

  -- [Debug]
  -- string source
  dump[#dump+1] = DumpString(func.source or "(unknown phobos source)")

  -- int n_lines (always same as n_instructions?)
  -- int[] lines (line number per instruction?)
  dump[#dump+1] = DumpInt(#func.instructions)
  for i, instruction in ipairs(func.instructions) do
    dump[#dump+1] = DumpInt(instruction.line or 0)
  end

  -- int n_locals
  -- local_desc[] locals
  --   string name
  --   int start_pc
  --   int end_pc
  -- TODO: since there can be gaps in live_regs[i].reg this actually requires some data transformation
  -- the right solution is most likely to perform this transformation at the end of compilation
  -- and only store the raw "locals" info in the generated function
  dump[#dump+1] = DumpInt(#func.live_regs)
  for _, live in ipairs(func.live_regs) do
    dump[#dump+1] = DumpString(live.name)
    -- TODO: i'm not sure about these, but zero based including to excluding would be the most natural
    -- so that's how it is for now
    dump[#dump+1] = DumpInt(live.start_at - 1)
    dump[#dump+1] = DumpInt(live.stop_at)
  end

  -- int n_upvals
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
  -- int n_branches

  return table.concat(dump)
end

local function DumpHeader()
  -- Lua Signature: "\x1bLua"
  -- byte version = "\x52"
  -- byte format = 0 (official)
  -- byte endianness = 1
  -- byte sizeof(int) = 4
  -- byte sizeof(size_t) = 8
  -- byte sizeof(Instruction) = 4
  -- byte sizeof(luaNumber) = 8
  -- byte lua_number is int? = 0
  -- magic "\x19\x93\r\n\x1a\n"
  return "\x1bLua\x52\0\1\4\8\4\8\0\x19\x93\r\n\x1a\n"
end

local function DumpMain(main)
  return DumpHeader() .. DumpFunction(main)
end

return DumpMain
