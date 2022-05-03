
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes
local phobos_consts = require("constants")
local util = require("util")

local get_function_label
do
  local function get_position(line, column)
    return (line or 0)..(column and ":"..column or "")
  end

  function get_function_label(func)
    ---cSpell:ignore addinfo, chunkid
    -- in Lua's `addinfo` it defaults to "?", otherwise uses `luaO_chunkid` to format the function source
    -- TODO: write a proper function similar to `luaO_chunkid` to format the function source in a readable way
    return (func.source or "?")..":"
      ..get_position(func.line_defined, func.column_defined).."-"
      ..get_position(func.last_line_defined, func.last_column_defined)
  end
end

local get_instruction_label
do
  local func, pc, constant_labels, display_keys, current, next_inst
  -- pc is **one based** to work best with func.debug_registers

  local function get_register_label(key, idx)
    idx = idx or current[key]
    for _, reg in ipairs(func.debug_registers) do
      if reg.index == idx and reg.start_at <= pc and reg.stop_at >= pc then
        return "R("..(display_keys and (key..": ") or "")..idx..(reg.name and ("|"..reg.name) or "")..")"
      end
    end
    return "R("..(display_keys and (key..": ") or "")..idx..")"
  end

  local function get_constant_label(key, idx)
    idx = idx or current[key]
    -- this key is pretty "in the way", but it says here (commented out) to know where and how to add it if needed
    return constant_labels[idx + 1]--.." ("..key..")"
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

  local function get_label(key, idx)
    idx = idx or current[key]
    return (display_keys and (key..": ") or "")..idx
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
      return "NEWTABLE", get_register_label("a").." := {} size("
        ..get_label("b", util.floating_byte_to_number(current.b))..", "
        ..get_label("c", util.floating_byte_to_number(current.c))..")"
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
      return "JMP", "-> "..(pc + current.sbx + 1).." (pc += "..get_label("sbx")..")"
        ..(current.a ~= 0 and ("; close all upvals >= "..get_register_label("a-1", current.a - 1)) or "")
    end,
    [opcodes.eq] = function()
      return "EQ", "if ("..get_register_or_constant_label("b").." "..(current.a ~= 0 and "~=" or "==").." "
        ..get_register_or_constant_label("c")..") then pc++"
    end,
    [opcodes.lt] = function()
      return "LT", "if ("..get_register_or_constant_label("b").." "..(current.a ~= 0 and ">=" or "<").." "
        ..get_register_or_constant_label("c")..") then pc++"
    end,
    [opcodes.le] = function()
      return "LE", "if ("..get_register_or_constant_label("b").." "..(current.a ~= 0 and ">" or "<=").." "
        ..get_register_or_constant_label("c")..") then pc++"
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
      return "RETURN", "return "..(current.b ~= 0 and (current.b - 1) or "var")
        .." results starting at "..get_register_label("a")
    end,

    [opcodes.forloop] = function()
      return "FORLOOP", get_register_label("a").." += "..get_register_label("a+2", current.a + 2).."; "
        .."if "..get_register_label("a").." (step < 0 ? >= : <=) "..get_register_label("a+1", current.a + 1).." then { "
        .."-> "..(pc + current.sbx + 1).." (pc += "..get_label("sbx").."); "
        ..get_register_label("a+3", current.a + 3).." := "..get_register_label("a")
        .." }"
    end,
    [opcodes.forprep] = function()
      return "FORPREP", get_register_label("a").." -= "..get_register_label("a+2", current.a + 2).."; "
        .."-> "..(pc + current.sbx + 1).." (pc += "..get_label("sbx")..")"
    end,
    [opcodes.tforcall] = function()
      return "TFORCALL", get_register_label("a+3", current.a + 3)..", ..., "..get_register_label("a+2+c", current.a + 2 + current.c).." := "
        ..get_register_label("a").."(2 args: "..get_register_label("a+1", current.a + 1)..", "..get_register_label("a+2", current.a + 2)..")"
    end,
    [opcodes.tforloop] = function()
      return "TFORLOOP", "if "..get_register_label("a+1", current.a + 1).." ~= nil then { "
        ..get_register_label("a").." := "..get_register_label("a+1", current.a + 1).."; "
        .."-> "..(pc + current.sbx + 1).." (pc += "..get_label("sbx")..")"
        .." }"
    end,

    [opcodes.setlist] = function()
      local c = (current.c ~= 0 and current.c or next_inst.ax) - 1
      return "SETLIST", get_register_label("a").."["..(c * phobos_consts.fields_per_flush + 1)..", ..."
        ..(current.b ~= 0 and (", "..(c * phobos_consts.fields_per_flush + current.b)) or "").."] := "
        ..get_register_label("a+1", current.a + 1)..", ..., "..(current.b ~= 0 and get_register_label("a+b", current.a + current.b) or "top")
    end,
    [opcodes.closure] = function()
      local inner_func = func.inner_functions[current.bx + 1]
      return "CLOSURE", get_register_label("a").." := closure("..get_function_label(inner_func)..")"
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
  function get_instruction_label(_func, _pc, _constant_labels, _display_keys)
    func = _func
    pc = _pc
    constant_labels = _constant_labels
    display_keys = not not _display_keys
    current = func.instructions[pc]
    next_inst = func.instructions[pc + 1]
    return (
      instruction_label_getter_lut[current.op]
      or function()
        return "UNKNOWN", "OP("..current.op..")"
      end
    )()
  end
end

local create_instruction
do
  local instruction_part_getter_lut = {
    a = function(raw) return bit32.band(bit32.rshift(raw, 6), 0xff) end,
    b = function(raw) return bit32.band(bit32.rshift(raw, 23), 0x1ff) end,
    c = function(raw) return bit32.band(bit32.rshift(raw, 14), 0x1ff) end,
    ax = function(raw) return bit32.band(bit32.rshift(raw, 6), 0x3ffffff) end,
    bx = function(raw) return bit32.band(bit32.rshift(raw, 14), 0x3ffff) end,
    sbx = function(raw) return bit32.band(bit32.rshift(raw, 14), 0x3ffff) - 0x1ffff end,
  }

  function create_instruction(raw)
    local op_id = bit32.band(raw, 0x3f)
    local opcode = opcode_util.opcodes_by_id[op_id]
    local instruction = {op = opcode}
    for part in pairs(opcode.params) do
      instruction[part] = instruction_part_getter_lut[part](raw)
    end
    return instruction
  end
end

local header_length = #phobos_consts.lua_header_str

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
      local double_func, err = load(prefix..double_bytes..postfix, "=(double loader)", "b")
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
    if bytecode:sub(i, i + header_length - 1) ~= phobos_consts.lua_header_str then
      error("Invalid Lua Header.");
    end
    i = i + header_length
  end

  local function read_uint8()
    return read_bytes(1)
  end

  local function read_uint32()
    local one, two, three, four = read_bytes(4)
    return one
      + bit32.lshift(two, 8)
      + bit32.lshift(three, 16)
      + bit32.lshift(four, 24)
  end

  local function read_size()
    -- string length is defined with a UInt64, but we only support UInt32
    -- because Lua numbers are doubles making it annoying/complicated
    local size = read_uint32()
    if bytecode:sub(i, i + 4 - 1) ~= "\0\0\0\0" then
      -- error includes string because that's the only thing using size_t
      error("Unsupported to read (string) size greater than `UInt32.max_value`.")
    end
    i = i + 4
    return size
  end

  local function read_string()
    local size = read_size()
    if size == 0 then -- 0 means nil
      return nil
    else
      local result = bytecode:sub(i, i + size - 1 - 1) -- an extra -1 for the trailing \0
      i = i + size
      return result
    end
  end

  local const_lut = {
    [0] = function()
      return {node_type = "nil", value = nil}
    end,
    [1] = function()
      local value = read_uint8() ~= 0
      return {node_type = "boolean", value = value}
    end,
    [3] = function()
      local value = to_double(read_bytes_as_str(8))
      return {node_type = "number", value = value}
    end,
    [4] = function()
      local value = read_string()
      if not value then
        error("Strings in the constant table must not be `nil`.")
      end
      return {node_type = "string", value = value}
    end,
  }
  setmetatable(const_lut, {
    __index = function(_, k)
      return function()
        error("Invalid Lua constant type `"..k.."`.")
      end
    end,
  })

  local function nil_if_zero(number)
    return number ~= 0 and number or nil
  end

  local function disassemble_func()
    local func = {
      instructions = {},
      constants = {},
      inner_functions = {},
      upvals = {},
      debug_registers = {},
    }

    func.line_defined = nil_if_zero(read_uint32())
    func.last_line_defined = nil_if_zero(read_uint32())
    func.num_params = read_uint8()
    func.is_vararg = read_uint8() ~= 0
    func.max_stack_size = read_uint8()

    for j = 1, read_uint32() do
      local raw = read_uint32()
      func.instructions[j] = create_instruction(raw)
    end

    local constant_count = read_uint32()
    if constant_count > 0 then
      for j = 1, constant_count - 1 do
        func.constants[j] = const_lut[read_uint8()]()
      end

      -- check if the last constant is Phobos debug symbols
      local last_type = read_uint8()
      local original_i = i
      local are_phobos_debug_symbols = false
      local phobos_debug_symbol_version = 0
      local phobos_debug_symbols_must_end_at
      if last_type == 4 then
        local size = read_size()
        phobos_debug_symbols_must_end_at = i + size
        if read_bytes_as_str(#phobos_consts.phobos_signature) == phobos_consts.phobos_signature then
          size = size - #phobos_consts.phobos_signature
          while size > 2 do
            local byte = read_uint8()
            phobos_debug_symbol_version = phobos_debug_symbol_version + byte
            size = size - 1
            if byte ~= 0xff then
              are_phobos_debug_symbols = true
              break
            end
          end
        end
      end

      if are_phobos_debug_symbols then
        if phobos_debug_symbol_version ~= phobos_consts.phobos_debug_symbol_version then
          -- TODO: somehow warn that reading Phobos debug symbols was skipped [...]
          -- because of a version mismatch
          i = phobos_debug_symbols_must_end_at
        else
          -- column_defined
          func.column_defined = nil_if_zero(read_uint32())
          -- last_column_defined
          func.last_column_defined = nil_if_zero(read_uint32())

          -- instruction_columns
          for k = 1, read_uint32() do
            func.instructions[k].column = nil_if_zero(read_uint32())
          end

          -- sources
          local sources = {}
          for k = 1, read_uint32() do
            sources[k] = read_string()
          end

          -- sections
          do
            local current_source = nil -- nil stands for the main `source`
            local current_index = 1
            for _ = 1, read_uint32() do
              local instruction_index = read_uint32()
              local source_index = read_uint32()
              for k = current_index, (instruction_index + 1) - 1 do
                func.instructions[k].source = current_source
              end
              if source_index == 0 then
                current_source = nil
              else
                current_source = sources[source_index]
              end
            end
            for k = current_index, #func.instructions do
              func.instructions[k].source = current_source
            end
          end

          read_uint8() -- trailing \0
          if i ~= phobos_debug_symbols_must_end_at then
            error("Invalid Phobos debug symbol size.")
          end
        end
      else
        -- wasn't Phobos debug symbols
        i = original_i
        func.constants[constant_count] = const_lut[last_type]()
      end
    end

    for j = 1, read_uint32() do
      func.inner_functions[j] = disassemble_func()
    end

    for j = 1, read_uint32() do
      local in_stack = read_uint8() ~= 0
      func.upvals[j] = {
        in_stack = in_stack,
        [in_stack and "local_idx" or "upval_idx"] = read_uint8(),
      }
    end

    func.source = read_string()

    for j = 1, read_uint32() do
      func.instructions[j].line = nil_if_zero(read_uint32())
    end

    for j = 1, read_uint32() do
      func.debug_registers[j] = {
        name = read_string(),
        -- convert from zero based including excluding
        -- to one based including including
        start_at = read_uint32() + 1,
        stop_at = read_uint32(),
      }
    end

    local top = -1 -- **zero based**
    for j = 1, #func.instructions do
      local stopped = 0
      for _, reg_name in ipairs(func.debug_registers) do
        if reg_name.start_at == j then
          top = top + 1
          reg_name.index = top
        end
        if reg_name.stop_at == j then
          stopped = stopped + 1
        end
      end
      top = top - stopped
    end

    for j = #func.debug_registers, 1, -1 do
      if func.debug_registers[j].name == phobos_consts.unnamed_register_name then
        table.remove(func.debug_registers, j)
      end
    end

    for j = 1, read_uint32() do
      func.upvals[j].name = read_string()
    end

    return func
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

---@param func CompiledFunc
---called once at the beginning with general information about the function. Contains 2 newlines.
---@param func_description_callback fun(description: string)
---gets called for every instruction. instruction_index is 1-based
---@param instruction_callback fun(line?: integer, column?: integer, instruction_index: integer, padded_opcode: string, description: string, description_with_keys: string, raw_values: string)
local function get_disassembly(func, func_description_callback, instruction_callback)
  func_description_callback("function at "..get_function_label(func).."\n"
    ..(func.is_vararg and "vararg" or (func.num_params.." params")).." | "
    ..(#func.upvals).." upvals | "..func.max_stack_size.." max stack\n"
    ..(#func.instructions).." instructions | "..(#func.constants)
    .." constants | "..(#func.inner_functions).." functions")

  local constant_labels = {}
  for i, constant in ipairs(func.constants) do
    if constant.node_type == "string" then
      constant_labels[i] = string.format("%q", constant.value):gsub("\\\n", "\\n")
    elseif constant.node_type == "number" then
      constant_labels[i] = tostring(constant.value)
    elseif constant.node_type == "boolean" then
      constant_labels[i] = tostring(constant.value)
    elseif constant.node_type == "nil" then
      constant_labels[i] = "nil"
    else
      error("Invalid compiled constant type '"..constant.node_type.."'.")
    end
  end

  local instructions = func.instructions
  for i = 1, #instructions do
    local label, description = get_instruction_label(func, i, constant_labels)
    local _, description_with_keys = get_instruction_label(func, i, constant_labels, true)
    local parts = {}
    for _, key in ipairs{"a", "b", "c", "ax", "bx", "sbx"} do
      if instructions[i].op.params[key] then
        parts[#parts+1] = "["..key.." "..instructions[i][key].."]"
      end
    end
    instruction_callback(
      instructions[i].line,
      instructions[i].column,
      i,
      label..string.rep(" ", max_opcode_name_length - #label),
      description,
      description_with_keys,
      table.concat(parts, " ")
    )
  end
end

return {
  disassemble = disassemble,
  get_disassembly = get_disassembly,
}
