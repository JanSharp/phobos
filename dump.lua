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
  -- If i'm compiling a program with >4gb strings, somethign has gone horribly wrong anyway
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
      local dstr = string.dump(load(([[return %a]]):format(d))):sub(s,e)
      double_cache[d] = dstr
      return dstr
    end
  end
end

local function DumpString(str)
  -- typedef string:
  -- size_t length (including trailing null, 0 for empty string)
  -- char[] value (not present for empty string)
  if #str == 0 then
    return "\0"
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

local function DumpFunction(func)
  local dump = {}
  -- int linedefined (0 for main chunk)
  dump[#dump+1] = DumpInt(func.line)
  -- int lastlinedefined (0 for main chunk)
  dump[#dump+1] = DumpInt(func.endline)
  dump[#dump+1] = string.char(
    func.nparams or 0,        -- byte nparams
    func.isvararg and 1 or 0, -- byte isvararg
    func.maxstacksize or 2    -- byte maxstacksize, min of 2, reg0/1 always valid
  )

  -- [Code]
  -- int ninstructions
  dump[#dump+1] = DumpInt(#func.instructions)
  -- Instruction[] instructions
  for _,instruction in ipairs(func.instructions) do
    dump[#dump+1] = DumpInt(instruction)
  end


  -- [Constants]
  -- int nconsts
  dump[#dump+1] = DumpInt(#func.constants)
  -- TValue[] consts
  for _,constant in ipairs(func.constants) do
    dump[#dump+1] = DumpConstant(constant)
  end

  -- [Funcprotos]
  -- int nfuncs
  dump[#dump+1] = DumpInt(#func.funcprotos)
  -- DumpFunction[] funcs
  for _,f in ipairs(func.funcprotos) do
    dump[#dump+1] = DumpFunction(f)
  end

  -- [Upvals]
  -- int nupvals
  dump[#dump+1] = DumpInt(#func.upvals)
  -- upvals[] upvals
  for _,u in ipairs(func.upvals) do
    -- byte instack (is a local in parent scope, else upvalue in parent)
    -- byte idx
    dump[#dump+1] = string.char(u.updepth==1, u.ref.index or 0)
  end

  -- [Debug]
  -- string source
  dump[#dump+1] = DumpFunction(func.source or "(unknown source)")

  -- int nlines (always same as ninstructions?)
  -- int[] lines (line number per instruction?)

  -- int nlocs
  -- localdesc[] locs
  --   string name
  --   int startpc
  --   int endpc

  -- int nups
  dump[#dump+1] = DumpInt(#func.upvals)
  -- string[] ups
  for _,u in ipairs(func.upvals) do
    dump[#dump+1] = DumpString(u.name.value)
  end

  -- lua will stop reading here
  -- extra phobos debug sections:
  -- Phobos signature: "\x1bPhobos"
  -- byte version = "\x01"
  -- [branch annotations]
  -- int nbranches

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
