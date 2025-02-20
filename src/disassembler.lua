
local opcode_util = require("opcode_util")
local opcodes = opcode_util.opcodes
local phobos_consts = require("constants")
local binary = require("binary_serializer")
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

local get_instruction_description
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
    -- this key is pretty "in the way", but it stays here (commented out)
    -- to know where and how to add it if needed
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
    return "Up("..(display_keys and (key..": ") or "")..idx
      ..(func.upvals[idx + 1] and ("|"..func.upvals[idx + 1].name) or "")..")"
  end

  local function get_label(key, idx)
    idx = idx or current[key]
    return (display_keys and (key..": ") or "")..idx
  end

  local instruction_description_getter_lut = {
    [opcodes.move] = function()
      return get_register_label("a").." := "..get_register_label("b")
    end,
    [opcodes.loadk] = function()
      return get_register_label("a").." := "..get_constant_label("bx")
    end,
    [opcodes.loadkx] = function()
      return get_register_label("a").." := "..get_constant_label("next.ax", next_inst.ax)
    end,
    [opcodes.loadbool] = function()
      return get_register_label("a").." := "..(tostring(current.b ~= 0))..(current.c ~= 0 and " pc++" or "")
    end,
    [opcodes.loadnil] = function()
      return get_register_label("a")..", ..., "..get_register_label("a+b", current.a + current.b).." := nil"
    end,

    [opcodes.getupval] = function()
      return get_register_label("a").." := "..get_upval_label("b")
    end,
    [opcodes.gettabup] = function()
      return get_register_label("a").." := "..get_upval_label("b")
        .."["..get_register_or_constant_label("c").."]"
    end,
    [opcodes.gettable] = function()
      return get_register_label("a").." := "..get_register_label("b")
        .."["..get_register_or_constant_label("c").."]"
    end,
    [opcodes.settabup] = function()
      return get_upval_label("a").."["..get_register_or_constant_label("b").."] := "
        ..get_register_or_constant_label("c")
    end,
    [opcodes.setupval] = function()
      return get_upval_label("b").." := "..get_register_label("a")
    end,
    [opcodes.settable] = function()
      return get_register_label("a").."["..get_register_or_constant_label("b").."] := "
        ..get_register_or_constant_label("c")
    end,

    [opcodes.newtable] = function()
      return get_register_label("a").." := {} size("
        ..get_label("b", util.floating_byte_to_number(current.b))..", "
        ..get_label("c", util.floating_byte_to_number(current.c))..")"
    end,
    [opcodes.self] = function()
      return get_register_label("a+1", current.a + 1).." := "..get_register_label("b").."; "
        ..get_register_label("a").." := "..get_register_label("b")
        .."["..get_register_or_constant_label("c").."]"
    end,

    [opcodes.add] = function()
      return get_register_label("a").." := "..get_register_or_constant_label("b")
        .." + "..get_register_or_constant_label("c")
    end,
    [opcodes.sub] = function()
      return get_register_label("a").." := "..get_register_or_constant_label("b")
        .." - "..get_register_or_constant_label("c")
    end,
    [opcodes.mul] = function()
      return get_register_label("a").." := "..get_register_or_constant_label("b")
        .." * "..get_register_or_constant_label("c")
    end,
    [opcodes.div] = function()
      return get_register_label("a").." := "..get_register_or_constant_label("b")
        .." / "..get_register_or_constant_label("c")
    end,
    [opcodes.mod] = function()
      return get_register_label("a").." := "..get_register_or_constant_label("b")
        .." % "..get_register_or_constant_label("c")
    end,
    [opcodes.pow] = function()
      return get_register_label("a").." := "..get_register_or_constant_label("b")
        .." ^ "..get_register_or_constant_label("c")
    end,
    [opcodes.unm] = function()
      return get_register_label("a").." := -"..get_register_or_constant_label("b")
    end,
    [opcodes["not"]] = function()
      return get_register_label("a").." := not "..get_register_or_constant_label("b")
    end,
    [opcodes.len] = function()
      return get_register_label("a").." := length of "..get_register_or_constant_label("b")
    end,

    [opcodes.concat] = function()
      return get_register_label("a").." := "..get_register_label("b")..".. ... .."..get_register_label("c")
    end,

    [opcodes.jmp] = function()
      return "-> "..(pc + current.sbx + 1).." (pc += "..get_label("sbx")..")"
        ..(current.a ~= 0 and ("; close all upvals >= "..get_register_label("a-1", current.a - 1)) or "")
    end,
    [opcodes.eq] = function()
      return "if ("..get_register_or_constant_label("b").." "..(current.a ~= 0 and "~=" or "==").." "
        ..get_register_or_constant_label("c")..") then pc++"
    end,
    [opcodes.lt] = function()
      return "if ("..get_register_or_constant_label("b").." "..(current.a ~= 0 and ">=" or "<").." "
        ..get_register_or_constant_label("c")..") then pc++"
    end,
    [opcodes.le] = function()
      return "if ("..get_register_or_constant_label("b").." "..(current.a ~= 0 and ">" or "<=").." "
        ..get_register_or_constant_label("c")..") then pc++"
    end,

    [opcodes.test] = function()
      return "if "..(current.c ~= 0 and "not " or "")..get_register_label("a").." then pc++"
    end,
    [opcodes.testset] = function()
      return "if "..(current.c ~= 0 and "" or "not ")..get_register_label("b").." then "
        ..get_register_label("a").." := "..get_register_label("b").." else pc++"
    end,

    [opcodes.call] = function()
      return get_register_label("a").."("..(current.b ~= 0 and (current.b - 1) or "var").." args, "
        ..(current.c ~= 0 and (current.c - 1) or "var").." returns)"
    end,
    [opcodes.tailcall] = function()
      return "return "..get_register_label("a").."("..(current.b ~= 0 and (current.b - 1) or "var").." args)"
    end,
    [opcodes["return"]] = function()
      return "return "..(current.b ~= 0 and (current.b - 1) or "var")
        .." results "..(current.b ~= 1 and ("starting at "..get_register_label("a")) or "")
    end,

    [opcodes.forloop] = function()
      return get_register_label("a").." += "..get_register_label("a+2", current.a + 2).."; "
        .."if "..get_register_label("a").." (step < 0 ? >= : <=) "
        ..get_register_label("a+1", current.a + 1).." then { "
        .."-> "..(pc + current.sbx + 1).." (pc += "..get_label("sbx").."); "
        ..get_register_label("a+3", current.a + 3).." := "..get_register_label("a")
        .." }"
    end,
    [opcodes.forprep] = function()
      return get_register_label("a").." -= "..get_register_label("a+2", current.a + 2).."; "
        .."-> "..(pc + current.sbx + 1).." (pc += "..get_label("sbx")..")"
    end,
    [opcodes.tforcall] = function()
      return get_register_label("a+3", current.a + 3)..", ..., "
        ..get_register_label("a+2+c", current.a + 2 + current.c).." := "
        ..get_register_label("a").."(2 args: "..get_register_label("a+1", current.a + 1)..", "
        ..get_register_label("a+2", current.a + 2)..")"
    end,
    [opcodes.tforloop] = function()
      return "if "..get_register_label("a+1", current.a + 1).." ~= nil then { "
        ..get_register_label("a").." := "..get_register_label("a+1", current.a + 1).."; "
        .."-> "..(pc + current.sbx + 1).." (pc += "..get_label("sbx")..")"
        .." }"
    end,

    [opcodes.setlist] = function()
      local c = (current.c ~= 0 and current.c or next_inst.ax) - 1
      return get_register_label("a").."["..(c * phobos_consts.fields_per_flush + 1)..", ..."
        ..(current.b ~= 0 and (", "..(c * phobos_consts.fields_per_flush + current.b)) or "").."] := "
        ..get_register_label("a+1", current.a + 1)..", ..., "
        ..(current.b ~= 0 and get_register_label("a+b", current.a + current.b) or "top")
    end,
    [opcodes.closure] = function()
      local inner_func = func.inner_functions[current.bx + 1]
      return get_register_label("a").." := closure("..get_function_label(inner_func)..")"
    end,
    [opcodes.vararg] = function()
      return get_register_label("a")..", ..., "
        ..(current.b ~= 0 and get_register_label("a+b-2", current.a + current.b - 2) or "top")
        .." := vararg"
    end,
    [opcodes.extraarg] = function()
      return "."
    end,
  }
  function get_instruction_description(_func, _pc, _constant_labels, _display_keys)
    func = _func
    pc = _pc
    constant_labels = _constant_labels
    display_keys = not not _display_keys
    current = func.instructions[pc]
    next_inst = func.instructions[pc + 1]
    return (
      instruction_description_getter_lut[current.op]
        or util.debug_abort("Missing disassembly formatter for opcode '"..current.op.name.."'.")
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

---@type BinaryDeserializer
local deserializer

local function read_header()
  local header = deserializer:read_raw(header_length)
  if header == phobos_consts.lua_header_str then
    return
  end
  if header == phobos_consts.lua_header_str_int32 then
    deserializer:set_use_int32(true)
    return
  end
  util.abort("Invalid or Unknown Lua Header.")
end

local function nil_if_zero(number)
  return number ~= 0 and number or nil
end

---@param func CompiledFunc
local function try_read_phobos_debug_symbols(func)
  -- check if the last constant is Phobos debug symbols
  local last_type = deserializer:read_uint8()
  local are_phobos_debug_symbols = false
  local phobos_debug_symbol_version = 0
  local phobos_debug_symbols_must_end_at
  if last_type == 4 then
    local size = deserializer:read_size_t()
    phobos_debug_symbols_must_end_at = deserializer:get_index() + size
    if deserializer:read_raw(#phobos_consts.phobos_signature) == phobos_consts.phobos_signature then
      size = size - #phobos_consts.phobos_signature
      while size > 2 do
        local byte = deserializer:read_uint8()
        phobos_debug_symbol_version = phobos_debug_symbol_version + byte
        size = size - 1
        if byte ~= 0xff then
          are_phobos_debug_symbols = true
          break
        end
      end
    end
  end

  if not are_phobos_debug_symbols then return false end

  if phobos_debug_symbol_version ~= phobos_consts.phobos_debug_symbol_version then
    -- TODO: somehow warn that reading Phobos debug symbols was skipped [...]
    -- because of a version mismatch
    deserializer:set_index(phobos_debug_symbols_must_end_at)
    return true
  end

  -- column_defined
  func.column_defined = nil_if_zero(deserializer:read_uint32())
  -- last_column_defined
  func.last_column_defined = nil_if_zero(deserializer:read_uint32())

  -- instruction_columns
  for k = 1, deserializer:read_uint32() do
    func.instructions[k].column = nil_if_zero(deserializer:read_uint32())
  end

  -- sources
  local sources = {}
  for k = 1, deserializer:read_uint32() do
    sources[k] = deserializer:read_lua_string()
  end

  -- sections
  do
    local current_source = nil -- nil stands for the main `source`
    local current_index = 1
    for _ = 1, deserializer:read_uint32() do
      local instruction_index = deserializer:read_uint32()
      local source_index = deserializer:read_uint32()
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

  deserializer:read_uint8() -- trailing \0
  if deserializer:get_index() ~= phobos_debug_symbols_must_end_at then
    util.abort("Invalid Phobos debug symbol size.")
  end

  return true
end

local function disassemble_func()
  ---@type CompiledFunc
  local func = {
    instructions = {},
    constants = {},
    inner_functions = {},
    upvals = {},
    debug_registers = {},
  }

  func.line_defined = nil_if_zero(deserializer:read_uint32())
  func.last_line_defined = nil_if_zero(deserializer:read_uint32())
  func.num_params = deserializer:read_uint8()
  func.is_vararg = deserializer:read_uint8() ~= 0
  func.max_stack_size = deserializer:read_uint8()

  for i = 1, deserializer:read_uint32() do
    local raw = deserializer:read_uint32()
    func.instructions[i] = create_instruction(raw)
  end

  local constant_count = deserializer:read_uint32()
  if constant_count > 0 then
    for i = 1, constant_count - 1 do
      func.constants[i] = deserializer:read_lua_constant()
    end
    local original_index = deserializer:get_index()
    if not try_read_phobos_debug_symbols(func) then
      -- wasn't Phobos debug symbols
      deserializer:set_index(original_index)
      func.constants[constant_count] = deserializer:read_lua_constant()
    end
  end

  for i = 1, deserializer:read_uint32() do
    func.inner_functions[i] = disassemble_func()
  end

  for i = 1, deserializer:read_uint32() do
    local in_stack = deserializer:read_uint8() ~= 0
    func.upvals[i] = {
      in_stack = in_stack,
      [in_stack and "local_idx" or "upval_idx"] = deserializer:read_uint8(),
    }
  end

  func.source = deserializer:read_lua_string()

  for i = 1, deserializer:read_uint32() do
    func.instructions[i].line = nil_if_zero(deserializer:read_uint32())
  end

  for i = 1, deserializer:read_uint32() do
    func.debug_registers[i] = {
      name = deserializer:read_lua_string()--[[@as string]],
      -- convert from zero based including excluding
      -- to one based including including
      start_at = deserializer:read_uint32() + 1,
      stop_at = deserializer:read_uint32(),
    }
  end

  local top = -1 -- **zero based**
  for i = 1, #func.instructions do
    local stopped = 0
    for _, reg_name in ipairs(func.debug_registers) do
      if reg_name.start_at == i then
        top = top + 1
        reg_name.index = top
      end
      if reg_name.stop_at == i then
        stopped = stopped + 1
      end
    end
    top = top - stopped
  end

  for i = #func.debug_registers, 1, -1 do
    if func.debug_registers[i].name == phobos_consts.unnamed_register_name then
      table.remove(func.debug_registers, i)
    end
  end

  for i = 1, deserializer:read_uint32() do
    func.upvals[i].name = deserializer:read_lua_string()--[[@as string]]
  end

  return func
end

---@param bytecode string
local function disassemble(bytecode)
  deserializer = binary.new_deserializer(bytecode)
  read_header()
  local result = disassemble_func()
  deserializer = (nil)--[[@as BinaryDeserializer]] -- Free memory.
  return result
end

local max_opcode_name_length = 0
for opcode_name in pairs(opcodes) do
  if #opcode_name > max_opcode_name_length then
    max_opcode_name_length = #opcode_name
  end
end

---@class DisassemblyInstructionData : Position
---@field line integer @ 0 for unknown (overridden to remove `nil`)
---@field column integer @ 0 for unknown (overridden to remove `nil`)
---@field pc integer @ process counter, 1 based
---@field op_label string @ padded with spaces on the right to always have the same length
---@field description string @ description for the instruction, unknown length
---@field args string @ contains raw values for the instruction arguments (a, b, c, ax, bx, sbx)

---@param func CompiledFunc
---@param func_description_callback fun(description: string) @
---called once at the beginning with general information about the function. Contains 2 newlines.
---@param instruction_callback fun(inst_data: DisassemblyInstructionData) @
---gets called for every instruction. The instance of this table gets reused every iteration\
---intended to be used in combination with `util.format_interpolated`
local function get_disassembly(func, func_description_callback, instruction_callback, display_keys)
  local description = "function at "..get_function_label(func).."\n"
    ..(func.is_vararg and "vararg" or (func.num_params.." params")).." | "
    ..(#func.upvals).." upvals | "..func.max_stack_size.." max stack\n"
    ..(#func.instructions).." instructions | "..(#func.constants)
    .." constants | "..(#func.inner_functions).." functions"

  for i, upval in pairs(func.upvals) do
    description = description.."\nUp("..(i - 1)..(upval.name and ("|"..upval.name) or "")..") of parent "
      ..(upval.in_stack and "local" or "upval")..", index: "
      ..string.format("%d", upval.in_stack and upval.local_idx or upval.upval_idx)
  end

  func_description_callback(description)

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
      util.debug_abort("Invalid constant type '"..constant.node_type.."'.")
    end
  end

  local instructions = func.instructions
  local data = {}
  for i = 1, #instructions do
    local label = instructions[i].op.label
    local description = get_instruction_description(func, i, constant_labels, display_keys)
    local parts = {}
    for _, key in ipairs{"a", "b", "c", "ax", "bx", "sbx"} do
      if instructions[i].op.params[key] then
        parts[#parts+1] = "["..key.." "..instructions[i][key].."]"
      end
    end
    local args = table.concat(parts, " ")
    data.line = instructions[i].line or 0
    data.column = instructions[i].column or 0
    data.pc = i
    data.op_label = label..string.rep(" ", max_opcode_name_length - #label)
    data.description = description
    data.args = args
    instruction_callback(data)
  end
end

return {
  disassemble = disassemble,
  get_disassembly = get_disassembly,
}
