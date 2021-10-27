
-- TODO: make a proper cmd tool for this

local disassembler = require("disassembler")
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
Path.use_forward_slash_as_main_separator_on_windows()
local constants = require("constants")

if not Path.new("temp"):exists() then
  lfs.mkdir("temp")
end

local show_keys_in_disassembly = false

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
    -- TODO: fix this api. god it's awful
    disassembler.get_disassembly(func, function(description)
      local line = get_line(func.line_defined)
      line[#line+1] = "-- "..(description:gsub("\n", "\n-- "))
    end, function(line_num, column_num, instruction_index, padded_opcode, description, description_with_keys, raw_values)
      description = show_keys_in_disassembly and description_with_keys or description
      local line = get_line(line_num)
      local min_description_len = 50
      line[#line+1] = string.format("-- %s %3d: %2df %4d  %s  %s%s  %s",
        format_line_num(line_num or 0),
        column_num or 0,
        func_id,
        instruction_index,
        padded_opcode,
        description,
        (min_description_len - #description > 0) and string.rep(" ", min_description_len - #description) or "",
        raw_values
      )
    end)

    for _, inner_func in ipairs(func.inner_functions) do
      add_func_to_lines_recursive(inner_func)
    end
  end

  -- TODO: make a proper function for getting bytecode from a potentially phobos compiled file
  local bytecode
  local file = assert(io.open(filename, "rb"))
  if file:read(4) == constants.lua_signature_str then
    assert(file:seek("set"))
    bytecode = file:read("*a")
    assert(file:close())
  else -- not a bytecode file? It might have been generated with `--use-load`
    -- check string constants in main chunk for a bytecode string
    assert(lfs.setmode(file, "text"))
    assert(file:seek("set"))
    local contents = file:read("*a")
    assert(file:close())
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
  file = assert(io.open(output_filename, "w"))
  file:write(table.concat(result, "\n"))
  file:close()
end

for i, filename in ipairs{...} do
  disassemble_file(filename, i ~= 1 and i or nil)
end
