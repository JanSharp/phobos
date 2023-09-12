
-- TODO: make a proper cmd tool for this

local disassembler = require("disassembler")
local io_util = require("io_util")
local Path = require("lib.path")
Path.set_main_separator("/")
local constants = require("constants")
local util = require("util")

io_util.mkdir_recursive("temp")

local show_keys_in_disassembly = false
local instruction_line_format = util.parse_interpolated_string(
  "-- {line:%3d} {column:%3d}: {func_id:%3d}f  {pc:%4d}  {op_label}  {description:%-50s}  {args}"
)

local function disassemble_file(filename, output_postfix)
  local lines = {}
  if not lines[1] then -- empty file edge case
    lines[1] = {}
  end
  lines[1][1] = "-- < line column: func_id pc  opcode  description  params >\n"

  local function format_line_num(line_num)
    return string.format("%5d", line_num)
  end

  local function get_line(line)
    if line and not lines[line] then
      for i = #lines + 1, line do
        lines[i] = {}
      end
    end
    return assert(lines[line] or lines[1])
  end

  local func_id = 0
  local function add_func_to_lines_recursive(func)
    func_id = func_id + 1
    disassembler.get_disassembly(
      func,
      function(description)
        local line = get_line(func.line_defined)
        line[#line+1] = "-- "..(description:gsub("\n", "\n-- "))
      end,
      ---@param data DisassemblyInstructionData|{func_id: integer}
      function(data)
        data.func_id = func_id
        local line = get_line(data.line)
        line[#line+1] = util.format_interpolated(instruction_line_format, data)
      end,
      show_keys_in_disassembly
    )

    for _, inner_func in ipairs(func.inner_functions) do
      add_func_to_lines_recursive(inner_func)
    end
  end

  local contents = io_util.read_file(filename)

  -- TODO: make a proper function for getting bytecode from a potentially phobos compiled file
  local bytecode
  if contents:sub(1, 4) == constants.lua_signature_str then
    bytecode = contents
  else -- not a bytecode file? It might have been generated with `--use-load`
    -- check string constants in main chunk for a bytecode string
    local chunk = assert(load(contents, nil, "t"))
    local disassembled = disassembler.disassemble(string.dump(chunk))
    for _, constant in ipairs(disassembled.constants) do
      if constant.node_type == "string" and constant.value:find("^"..constants.lua_signature_str) then
        bytecode = constant.value
        goto found_bytecode
      end
    end
    error("Unable to find bytecode in file '"..filename.."'")
    ::found_bytecode::
  end

  local func = disassembler.disassemble(bytecode)
  add_func_to_lines_recursive(func)

  -- maybe add some way to load a source file, which would require both
  -- the right working directory
  -- and the `--source-name` used when generating the file
  -- or just the source filename directly, though that wouldn't work once bytecode is multi source

  local result = {}
  for _, line in ipairs(lines) do
    for _, pre in ipairs(line) do
      result[#result+1] = pre
    end
    result[#result+1] = line.line or ""
  end

  local output_filename = "temp/phobos_disassembly"..(output_postfix and "_"..output_postfix or "")..".lua"
  io_util.write_file(output_filename, table.concat(result, "\n"))
end

for i, filename in ipairs{...} do
  disassemble_file(filename, i ~= 1 and i or nil)
end
