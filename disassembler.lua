
local opcodes = require("opcodes")

local get_instruction_label
do
  local func, pc, display_keys, current, next_inst

  local function get_register_label(key, idx)
    idx = idx or current[key]
    local stack = 0;
    for i = 1, #func.locals do
      local loc = func.locals[i];
      if loc.start <= pc + 1 then
        if loc._end >= pc+1 then
          if stack == idx then
            return "R("..(display_keys and (key..": ") or "")..idx.."|"..loc.name..")"
          end
          stack = stack + 1
        end
      else
        break
      end
    end
    return "R("..(display_keys and (key..": ") or "")..idx..")"
  end

  local function get_constant_label(key, idx)
    idx = idx or current[key]
    return func.constants[idx + 1].label--.." ("..key..")" -- TODO: once all label getters are done check if this key is ever needed
  end

  local function get_register_or_constant_label(key, idx)
    idx = idx or current[key]
    if bit32.band(idx, 0x100) ~= 0 then
      return get_constant_label(key, bit32.band(idx, 0xff))
    else
      return get_register_label(key, idx)
    end
  end

  local function get_upval_label(key, idx)
    idx = idx or current[key]
    return "Up("..(display_keys and (key..": ") or "")..idx..(func.upvals[idx + 1] and ("|"..func.upvals[idx + 1].name) or "")..")"
  end

  local function get_label(key)
    return (display_keys and (key..": ") or "")..current[key]
  end

  local instruction_label_getter_lut = {
    [opcodes.move] = function()
      return "MOVE", get_register_label("a").." := "..get_register_label("b")
    end,
    [opcodes.loadk] = function()
      return "LOADK", get_register_label("a").." := "..get_constant_label("bx")
    end,
    [opcodes.loadkx] = function()
      return "LOADKX", get_register_label("a").." := "..get_constant_label("next.ax", next_inst.ax)
    end,
    [opcodes.loadbool] = function()
      return "LOADBOOL", get_register_label("a").." := "..(tostring(current.b ~= 0))..(current.c ~= 0 and " pc++" or "")
    end,
    [opcodes.loadnil] = function()
      return "LOADNIL", get_register_label("a")..", ..., "..get_register_label("a+b", current.a + current.b).." := nil"
    end,

    [opcodes.getupval] = function()
      return "GETUPVAL", get_register_label("a").." := "..get_upval_label("b")
    end,
    [opcodes.gettabup] = function()
      return "GETTABUP", get_register_label("a").." := "..get_upval_label("b").."["..get_register_or_constant_label("c").."]"
    end,
    [opcodes.gettable] = function()
      return "GETTABLE", get_register_label("a").." := "..get_register_label("b").."["..get_register_or_constant_label("c").."]"
    end,
    [opcodes.settabup] = function()
      return "SETTABUP", get_upval_label("a").."["..get_register_or_constant_label("b").."] := "..get_register_or_constant_label("c")
    end,
    [opcodes.setupval] = function()
      return "SETUPVAL", get_upval_label("b").." := "..get_register_label("a")
    end,
    [opcodes.settable] = function()
      return "SETTABLE", get_register_label("a").."["..get_register_or_constant_label("b").."] := "..get_register_or_constant_label("c")
    end,

    [opcodes.newtable] = function()
      return "NEWTABLE", get_register_label("a").." := {} size("..get_label("b")..", "..get_label("c")..")"
    end,
    [opcodes.self] = function()
      return "SELF", get_register_label("a+1", current.a + 1).." := "..get_register_label("b").."; "
        ..get_register_label("a").." := "..get_register_label("b").."["..get_register_or_constant_label("c").."]"
    end,

    [opcodes.add] = function()
      return "ADD", get_register_label("a").." := "..get_register_or_constant_label("b").." + "..get_register_or_constant_label("c")
    end,
    [opcodes.sub] = function()
      return "SUB", get_register_label("a").." := "..get_register_or_constant_label("b").." - "..get_register_or_constant_label("c")
    end,
    [opcodes.mul] = function()
      return "MUL", get_register_label("a").." := "..get_register_or_constant_label("b").." * "..get_register_or_constant_label("c")
    end,
    [opcodes.div] = function()
      return "DIV", get_register_label("a").." := "..get_register_or_constant_label("b").." / "..get_register_or_constant_label("c")
    end,
    [opcodes.mod] = function()
      return "MOD", get_register_label("a").." := "..get_register_or_constant_label("b").." % "..get_register_or_constant_label("c")
    end,
    [opcodes.pow] = function()
      return "POW", get_register_label("a").." := "..get_register_or_constant_label("b").." ^ "..get_register_or_constant_label("c")
    end,
    [opcodes.unm] = function()
      return "UNM", get_register_label("a").." := -"..get_register_or_constant_label("b")
    end,
    [opcodes["not"]] = function()
      return "NOT", get_register_label("a").." := not "..get_register_or_constant_label("b")
    end,
    [opcodes.len] = function()
      return "LEN", get_register_label("a").." := length of "..get_register_or_constant_label("b")
    end,

    [opcodes.concat] = function()
      return "CONCAT", get_register_label("a").." := "..get_register_label("b")..".. ... .."..get_register_label("c")
    end,

    [opcodes.jmp] = function()
      return "JMP", "pc += "..get_label("sbx")
        ..(current.a ~= 0 and ("; close all upvals >= "..get_register_label("a-1", current.a - 1)) or "")
    end,
    [opcodes.eq] = function()
      return "EQ", "if ("..get_register_or_constant_label("b").." "..(current.a ~= 0 and "~=" or "==").." "
        ..get_register_or_constant_label("c")..") then pc++" -- TODO: maybe add info about a, but probably not
    end,
    [opcodes.lt] = function()
      return "LT", "if ("..get_register_or_constant_label("b").." "..(current.a ~= 0 and ">=" or "<").." "
        ..get_register_or_constant_label("c")..") then pc++" -- TODO: maybe add info about a, but probably not
    end,
    [opcodes.le] = function()
      return "LE", "if ("..get_register_or_constant_label("b").." "..(current.a ~= 0 and ">" or "<=").." "
        ..get_register_or_constant_label("c")..") then pc++" -- TODO: maybe add info about a, but probably not
    end,

    [opcodes.test] = function()
      return "TEST", "if "..(current.c ~= 0 and "not " or "")..get_register_label("a").." then pc++"
    end,
    [opcodes.testset] = function()
      return "TESTSET", "if "..(current.c ~= 0 and "" or "not ")..get_register_label("b").." then "
        ..get_register_label("a").." := "..get_register_label("b").." else pc++"
    end,

    [opcodes.call] = function()
      return "CALL", get_register_label("a").."("..(current.b ~= 0 and (current.b - 1) or "var").." args, "
        ..(current.c ~= 0 and (current.c - 1) or "var").." returns)"
    end,
    [opcodes.tailcall] = function()
      return "TAILCALL", "return "..get_register_label("a").."("..(current.b ~= 0 and (current.b - 1) or "var").." args)"
    end,
    [opcodes["return"]] = function()
      return "RETURN", "return "..(current.b ~= 0 and (current.b - 1) or "var").." results"
        ..(current.b > 1 and (" starting at "..get_register_label("a")) or "")
    end,

    [opcodes.forloop] = function()
      return "FORLOOP", get_register_label("a").." += "..get_register_label("a+2", current.a + 2).."; "
        .."if "..get_register_label("a").." (step < 0 ? >= : <=) "..get_register_label("a+1", current.a + 1).." then { "
        .."pc += "..get_label("sbx").."; "
        ..get_register_label("a+3", current.a + 3).." := "..get_register_label("a")
        .." }"
    end,
    [opcodes.forprep] = function()
      return "FORPREP", get_register_label("a").." -= "..get_register_label("a+2", current.a + 2).."; "
        .."pc += "..get_label("sbx")
    end,
    [opcodes.tforcall] = function()
      return "TFORCALL", get_register_label("a+3", current.a + 3)..", ..., "..get_register_label("a+2+c", current.a + 2 + current.c).." := "
        ..get_register_label("a").."(2 args: "..get_register_label("a+1", current.a + 1)..", "..get_register_label("a+2", current.a + 2)..")"
    end,
    [opcodes.tforloop] = function()
      return "TFORLOOP", "if "..get_register_label("a+1", current.a + 1).." ~= nil then { "
        ..get_register_label("a").." := "..get_register_label("a+1", current.a + 1).."; "
        .."pc += "..get_label("sbx")
        .." }"
    end,

    [opcodes.setlist] = function()
      local c = (current.c ~= 0 and current.c or next_inst.ax) - 1
      local fields_per_flush = 50
      -- TODO: maybe add display keys
      return "SETLIST", get_register_label("a").."["..(c * fields_per_flush + 1)..", ..., "..(c * fields_per_flush + current.b).."] := "
        ..get_register_label("a+1", current.a + 1)..", ..., "..get_register_label("a+b", current.a + current.b)
    end,
    [opcodes.closure] = function()
      local inner_func = func.inner_functions[current.bx + 1]
      return "CLOSURE", get_register_label("a").." := closure("..inner_func.source..":"..inner_func.first_line.."-"..inner_func.last_line..")"
    end,
    [opcodes.vararg] = function()
      return "VARARG", get_register_label("a")..", ..., "
        ..(current.b ~= 0 and get_register_label("a+b-2", current.a + current.b - 2) or "top")
        .." := vararg"
    end,
    [opcodes.extraarg] = function()
      return "EXTRAARG", "."
    end,
  }
  function get_instruction_label(_func, _pc, _display_keys)
    func = _func
    pc = _pc
    display_keys = not not _display_keys
    current = func.instructions[pc]
    next_inst = func.instructions[pc + 1]
    return (
      instruction_label_getter_lut[current.op]
      or function()
        local _
        _ = current.a
        _ = current.b
        _ = current.c
        _ = current.ax
        _ = current.bx
        _ = current.sbx
        return "UNKNOWN", "OP("..current.op..")"
      end
    )()
  end
end

local instruction_meta
do
  local instruction_part_getter_lut = {
    a = function(raw) return bit32.band(bit32.rshift(raw, 6), 0xff) end,
    b = function(raw) return bit32.band(bit32.rshift(raw, 23), 0x1ff) end,
    c = function(raw) return bit32.band(bit32.rshift(raw, 14), 0x1ff) end,
    ax = function(raw) return bit32.band(bit32.rshift(raw, 6), 0x3ffffff) end,
    bx = function(raw) return bit32.band(bit32.rshift(raw, 14), 0x3ffff) end,
    sbx = function(raw) return bit32.band(bit32.rshift(raw, 14), 0x3ffff) - 0x1ffff end,
  }
  instruction_meta = {
    __index = function(inst, k)
      local getter = instruction_part_getter_lut[k]
      if not getter then
        return nil
      end
      inst[k] = getter(inst.raw)
      return getter(inst.raw)
    end,
  }
end

local function new_instruction(raw)
  return setmetatable({raw = raw, op = bit32.band(raw, 0x3f)}, instruction_meta)
end

local header_bytes = {
  0x1b, 0x4c, 0x75, 0x61, -- LUA_SIGNATURE
	0x52, 0x00, -- lua version
	0x01, 0x04, 0x08, 0x04, 0x08, 0x00, -- lua config parameters: LE, 4 byte int, 8 byte size_t, 4 byte instruction, 8 byte LuaNumber, number is double
	0x19, 0x93, 0x0d, 0x0a, 0x1a, 0x0a, -- magic
}
local header_str = string.char(table.unpack(header_bytes))
local header_length = #header_str

local to_double
do
  local dumped = string.dump(load[[return 523123.123145345]])
  local s, e = dumped:find("\3\54\208\25\126\204\237\31\65")
  if s == nil then
    error("Unable to set up bytes to double conversion")
  end
  local prefix = dumped:sub(1, s) -- includes number prefix (\3)
  local postfix = dumped:sub(e + 1) -- excludes the last byte of the found sequence (\65)
  local double_cache = {}

  function to_double(double_bytes)
    if double_cache[double_bytes] then
      return double_cache[double_bytes]
    else
      local double_func, err = load(prefix..double_bytes..postfix, "=(double loader)", "b", {})
      if not double_func then
        error("Unable to load double, see inner error: "..err)
      end
      local success, result = pcall(double_func)
      if not success then
        error("Unable to load double, see inner error: "..result)
      end
      return result
    end
  end
end

---@param bytecode string
local function disassemble(bytecode)
  local i = 1

  local function read_bytes_as_str(amount)
    local result = bytecode:sub(i, i + amount - 1)
    i = i + amount
    return result
  end

  local function read_bytes(amount)
    i = i + amount -- do this first because :byte() returns var results
    return bytecode:byte(i - amount, i - 1)
  end

  local function read_header()
    if bytecode:sub(i, i + header_length - 1) ~= header_str then
      error("Invalid Lua Header.");
    end
    i = i + header_length
  end

  local function read_uint32()
    local one, two, three, four = read_bytes(4)
    return one
      + bit32.lshift(two, 8)
      + bit32.lshift(three, 16)
      + bit32.lshift(four, 24)
  end

  local function read_uint8()
    return read_bytes(1)
  end

  local function read_string()
    -- string length is defined with a UInt64, but we only support UInt32
    -- because Lua numbers are doubles making it annoying/complicated
    local length = read_uint32()
    if bytecode:sub(i, i + 4 - 1) ~= "\0\0\0\0" then
      error("Unable to read string longer than `UInt32.max_value`.")
    end
    i = i + 4
    if length == 0 then
      return ""
    else
      local result = bytecode:sub(i, i + length - 1 - 1) -- an extra -1 for the extra \0
      i = i + length
      return result
    end
  end

  local const_lut = {
    [0] = function()
      return {node_type = "nil", label = "nil"}
    end,
    [1] = function()
      local value = read_uint8() ~= 0
      return {node_type = value and "true" or "false", value = value, label = tostring(value)}
    end,
    [3] = function()
      local value = to_double(read_bytes_as_str(8))
      return {node_type = "number", value = value, label = tostring(value)}
    end,
    [4] = function()
      local value = read_string()
      return {node_type = "string", value = value, label = string.format("%q", value)--[[:gsub("\\\n", "\\n")]]}
    end,
  }
  setmetatable(const_lut, {
    __index = function(_, k)
      return function()
        error("Invalid Lua constant type `"..k.."`.")
      end
    end,
  })

  local function disassemble_func()
    local source
    local n_param
    local is_vararg
    local max_stack
    local locals = {}
    local upvals = {}
    local instructions = {}
    local constants = {}
    local inner_functions = {}
    local first_line
    local last_line

    first_line = read_uint32()
    last_line = read_uint32()
    n_param = read_uint8()
    is_vararg = read_uint8() ~= 0
    max_stack = read_uint8()

    for j = 1, read_uint32() do
      local raw = read_uint32()
      instructions[j] = new_instruction(raw)
    end

    for j = 1, read_uint32() do
      constants[j] = const_lut[read_uint8()]()
    end

    for j = 1, read_uint32() do
      inner_functions[j] = disassemble_func()
    end

    for j = 1, read_uint32() do
      upvals[j] = {
        in_stack = read_uint8() ~= 0,
        idx = read_uint8(),
      }
    end

    source = read_string()

    for j = 1, read_uint32() do
      instructions[j].line = read_uint32()
    end

    for j = 1, read_uint32() do
      locals[j] = {
        name = read_string(),
        start = read_uint32(),
        _end = read_uint32(),
      }
    end

    for j = 1, read_uint32() do
      upvals[j].name = read_string()
    end

    return {
      source = source,
      n_param = n_param,
      is_vararg = is_vararg,
      max_stack = max_stack,
      locals = locals,
      upvals = upvals,
      instructions = instructions,
      constants = constants,
      inner_functions = inner_functions,
      first_line = first_line,
      last_line = last_line,
    }
  end

  read_header()
  return disassemble_func()
end

local max_opcode_name_length = 0
for opcode_name in pairs(opcodes) do
  if #opcode_name > max_opcode_name_length then
    max_opcode_name_length = #opcode_name
  end
end

---@param func table
---called once at the beginning with general information about the function. Contains 2 newlines.
---@param func_description_callback fun(description: string)
---gets called for every instruction. instruction_index is 1-based
---@param instruction_callback fun(line?: integer, instruction_index: integer, padded_opcode: string, description: string, description_with_keys: string, raw_values: string)
local function get_disassembly(func, func_description_callback, instruction_callback)
  func_description_callback("function at "..func.source..":"..func.first_line.."-"..func.last_line.."\n"
    ..(func.is_vararg and "vararg" or (func.n_param.." params")).." | "..(#func.upvals).." upvals | "..func.max_stack.." max stack\n"
    ..(#func.instructions).." instructions | "..(#func.constants).." constants | "..(#func.inner_functions).." functions")

  local instructions = func.instructions
  for i = 1, #instructions do
    -- clear cache because that is how we know which values are used for the different instructions
    instructions[i].a = nil
    instructions[i].b = nil
    instructions[i].c = nil
    instructions[i].ax = nil
    instructions[i].bx = nil
    instructions[i].sbx = nil
  end

  for i = 1, #instructions do
    local label, description = get_instruction_label(func, i)
    local _, description_with_keys = get_instruction_label(func, i, true)
    local raw = ""
    local first = true
    local function conditionally_add_raw_value(key)
      if rawget(instructions[i], key) then -- if the value is cached in the table then it has been accessed at some point
        if first then
          first = false
        else
          raw = raw.." "
        end
        raw = raw.."["..key.." = "..instructions[i][key].."]"
      end
    end
    conditionally_add_raw_value("a")
    conditionally_add_raw_value("b")
    conditionally_add_raw_value("c")
    conditionally_add_raw_value("ax")
    conditionally_add_raw_value("bx")
    conditionally_add_raw_value("sbx")
    instruction_callback(instructions[i].line, i, label..string.rep(" ", max_opcode_name_length - #label), description, description, raw)
  end
end

return {
  disassemble = disassemble,
  get_disassembly = get_disassembly,
}
