
local serpent = require("lib.serpent")
local disassembler = require("disassembler")
local io_util = require("io_util")
local Path = require("lib.path")
Path.set_main_separator("/")
local error_code_util = require("error_code_util")
local util = require("util")

local unsafe = true
local print_progress = true
local use_regular_lua_compiler = true
local use_phobos_compiler = true
local use_il = true
local do_create_inline_iife = false
local do_fold_const = true
local do_fold_control_statements = true
local eval_instruction_count = true
local eval_byte_count = true
local create_tokenizer_output = false
local create_disassembly = true
local show_keys_in_disassembly = false
local load_and_run_compiled_funcs = false
local run_count = 1

local total_lua_inst_count = 0
local total_pho_inst_count = 0
local total_lua_byte_count = 0
local total_pho_byte_count = 0

local instruction_line_format = util.parse_interpolated_string(
  "-- {line:%3d} {column:%3d} {prefix}: {func_id:%3d}f  {pc:%4d}  {op_label}  {description:%-50s}  {args}"
)
local il_instruction_line_format = util.parse_interpolated_string(
  "-- {line:%3d} {column:%3d} IL1: {func_id:%3d}f  {pc:%4d}  {label}  {block_id}  {description}"
)

-- local ill = require("indexed_linked_list")

-- local list = ill.new()

-- ill.append(list, "one")
-- ill.append(list, "two")
-- ill.append(list, "three")
-- ill.append(list, "four")

-- local function pretty_print()
--   local out = {}
--   for i = list.first.index, list.last.index do
--     if list.lookup[i] then
--       out[#out+1] = list.lookup[i].value
--     else
--       out[#out+1] = "."
--     end
--     out[#out+1] = " "
--   end
--   print(table.concat(out))
-- end

-- local last_index = list.last.index
-- local i = 0
-- local target = list.first.next
-- repeat
--   pretty_print()
--   i = i + 1
--   -- ill.insert_before(list, list.last.prev, i)
--   -- ill.insert_after(list, list.first.next, i)
--   target = ill.insert_after(list, target, i)
-- until list.last.index ~= last_index

-- print()
-- pretty_print()

-- do return end

io_util.mkdir_recursive("temp")

local function compile(filename)
  if print_progress then
    print("compiling '"..filename.."'...")
  end

  local file = assert(io.open(filename,"r"))
  local text = file:read("*a")

  local lines
  if create_disassembly or use_il then
    file:seek("set")
    lines = {}
    for line in file:lines() do
      lines[#lines+1] = {line = line}
    end
    -- add trailing line because :lines() doesn't return that one if it's empty
    -- (since regardless of if the previous character was a newline,
    -- the current one is eof which returns nil)
    if text:sub(#text) == "\n" then
      lines[#lines+1] = {line = ""}
    end
  end

  file:close()

  if create_disassembly or use_il then
    if not lines[1] then -- empty file edge case
      lines[1] = {line = ""}
    end
    lines[1][1] = "-- < line column compiler :  func_id  pc  opcode  description  params >\n"
  end

  local function format_line_num(line_num)
    -- this didn't work (getting digit count): (math.ceil((#lines) ^ (-10))), so now i cheat:
    -- local h = ("%"..(#tostring(#lines)).."d")
    -- local f = string.format("%"..(#tostring(#lines)).."d", line_num)
    return string.format("%"..(#tostring(#lines)).."d", line_num)
  end

  local function get_line(line)
    return assert(lines[line] or lines[1])
  end

  local instruction_count
  if eval_instruction_count then
    instruction_count = {}
  end

  local add_func_to_lines
  do
    local func_id
    local function add_func_to_lines_recursive(prefix, func)
      if eval_instruction_count then
        instruction_count[prefix] = instruction_count[prefix] or 0
        instruction_count[prefix] = instruction_count[prefix] + #func.instructions
      end

      if create_disassembly then
        func_id = func_id + 1
        disassembler.get_disassembly(
          func,
          function(description)
            local line = get_line(func.line_defined)
            line[#line+1] = "-- "..prefix..": "..(description:gsub("\n", "\n-- "..prefix..": "))
          end,
          function(data)
            data.prefix = prefix
            data.func_id = func_id
            local line = get_line(data.line)
            line[#line+1] = util.format_interpolated(instruction_line_format, data)
          end,
          show_keys_in_disassembly
        )
      end

      for _, inner_func in ipairs(func.inner_functions) do
        add_func_to_lines_recursive(prefix, inner_func)
      end
    end
    function add_func_to_lines(prefix, func)
      func_id = 0
      add_func_to_lines_recursive(prefix, func)
    end
  end

  local lua_func, lua_dumped
  local err

  if use_regular_lua_compiler then
    lua_func, err = loadfile(filename)
    if lua_func then
      lua_dumped = string.dump(lua_func)
      add_func_to_lines("lua", disassembler.disassemble(lua_dumped))
    else
      print(err)
    end
  end

  -- for _, token in require("tokenize")(text) do
  --   print(serpent.block(token))
  -- end

  local pho_dumped
  do
    local pcall = pcall
    -- i added this because the debugger was not breaking on error inside a pcall
    -- and now it suddenly does break even with this set to false.
    -- i don't understand
    if unsafe then
      pcall = function(f, ...)
        return true, f(...)
      end
    end

    if create_tokenizer_output then
      local tokens = {}
      for _, token in require("tokenize")(text) do
        tokens[#tokens+1] = token
      end
      io_util.write_file("temp/tokens.lua", serpent.dump(tokens, {indent = "  ", sortkeys = true}))
    end

    local success, main, parser_errors = pcall(require("parser"), text, "@"..filename)
    if not success then print(main) goto finish end
    -- print(serpent.block(main))
    if parser_errors[1] then
      error(error_code_util.get_message_for_list(parser_errors, "syntax errors"))
    end

    success, err = pcall(require("jump_linker"), main)
    if not success then print(err) goto finish end
    if err--[[@as table]][1] then
      error(error_code_util.get_message_for_list(err, "syntax errors"))
    end

    if use_il then
      local il
      success, il = pcall(require("intermediate_language"), main)
      if not success then print(il) goto finish end

      success, err = pcall(require("il_blocks"), il)
      if not success then print(err) goto finish end

      success, err = pcall(require("il_types"), il)
      if not success then print(err) goto finish end

      success, err = pcall(function()
        local il_func_id = 0
        local pretty_print = require("il_pretty_print")
        local block_ids = {}
        local next_block_id = 0
        local function il_add_func_lines(func)
          il_func_id = il_func_id + 1
          -- "-- < line column compiler :  func_id  pc  opcode  description  params >\n"
          pretty_print(func, function(data)
            data.line = format_line_num(data.inst.position and data.inst.position.line or 0)
            data.column = data.inst.position and data.inst.position.column or 0
            data.func_id = il_func_id
            local block_id = block_ids[data.inst.block]
            if not block_id then
              block_id = next_block_id
              next_block_id = next_block_id + 1
              block_ids[data.inst.block] = block_id
            end
            data.block_id = block_id
            local line = get_line(data.inst.position and data.inst.position.line)
            line[#line+1] = util.format_interpolated(il_instruction_line_format, data)
          end)
          for _, inner_func in ipairs(func.inner_functions) do
            il_add_func_lines(inner_func)
          end
        end
        il_add_func_lines(il)
      end)
      if not success then print(err) goto finish end

      -- local compiled
      -- success, compiled = pcall(require("il_compiler"), il)
      -- if not success then print(compiled) goto finish end
      -- add_func_to_lines("ILR", compiled)
    end

    if do_fold_const then
      success, err = pcall(require("optimize.fold_const"), main)
      if not success then print(err) goto finish end
    end

    if do_fold_control_statements then
      success, err = pcall(require("optimize.fold_control_statements"), main)
      if not success then print(err) goto finish end
    end

    if do_create_inline_iife then
      success, err = pcall(require("optimize.create_inline_iife"), main)
      if not success then print(err) goto finish end
    end

    local compiled
    success, compiled = pcall(require("compiler"), main)
    if not success then print(compiled) goto finish end
    -- print(serpent.dump(main,{indent = '  ', sparse = true, sortkeys = false, comment=true}))
    if eval_byte_count or create_disassembly then
      add_func_to_lines("pho", compiled)
    end

    success, pho_dumped = pcall(require("dump"), compiled)
    if not success then print(pho_dumped) goto finish end

    local disassembled
    success, disassembled = pcall(disassembler.disassemble, pho_dumped)
    if not success then print(disassembled) goto finish end

    if load_and_run_compiled_funcs then
      local pho_func
      if use_phobos_compiler then
        pho_func, err = load(pho_dumped)
        if not pho_func then print(err) goto finish end
      end

      if use_regular_lua_compiler and lua_func then
        print("----------")
        print("lua:")
        success, err = pcall(lua_func)
        if not success then print(err) goto finish end
      end

      if use_regular_lua_compiler or use_phobos_compiler then
        print("----------")
      end

      if use_phobos_compiler then
        print("pho:")
        success, err = pcall(pho_func)
        if not success then print(err) goto finish end
        print("----------")
      end
    end
  end

  ::finish::
  if eval_instruction_count then
    local diff = instruction_count.lua and instruction_count.pho
      and instruction_count.pho - instruction_count.lua
      or nil
    print(" #instructions: "..serpent.line(instruction_count)..(diff and (" diff: "..diff) or ""))
    total_lua_inst_count = total_lua_inst_count + (instruction_count.lua or 0)
    total_pho_inst_count = total_pho_inst_count + (instruction_count.pho or 0)
  end
  if eval_byte_count then
    local lua = use_regular_lua_compiler and lua_dumped and #lua_dumped or nil
    local pho = use_phobos_compiler and pho_dumped and #pho_dumped or nil
    local diff = lua and pho and pho - lua or nil
    print(" #bytes:        "..serpent.line{lua = lua, pho = pho}
      ..(diff and (" diff: "..diff) or "")
    )
    total_lua_byte_count = total_lua_byte_count + (lua or 0)
    total_pho_byte_count = total_pho_byte_count + (pho or 0)
  end

  if create_disassembly or use_il then
    local result = {}
    for _, line in ipairs(lines) do
      for _, pre in ipairs(line) do
        result[#result+1] = pre
      end
      result[#result+1] = line.line
    end

    io_util.write_file("temp/phobos_disassembly.lua", table.concat(result, "\n"))
  end
end

local filenames
if ... then
  filenames = {...}
else
  filenames = require("debugging.debugging_util").find_lua_source_files()
end

local start_time = os.clock()
for i = 1, run_count do
  for _, filename in ipairs(filenames) do
    compile(filename)
    if print_progress then
      print()
    end
  end
  print((os.clock() - start_time) / i)
  if print_progress then
    print()
    print()
  end
end

if eval_instruction_count and use_regular_lua_compiler and use_phobos_compiler then
  print("total instruction count diff: "..(total_pho_inst_count - total_lua_inst_count)
    .." ("..total_lua_inst_count.." => "..total_pho_inst_count.."; "
    ..string.format("%.2f", (total_pho_inst_count / total_lua_inst_count) * 100).."%)"
  )
end
if eval_byte_count and use_regular_lua_compiler and use_phobos_compiler then
  print("total byte count diff: "..(total_pho_byte_count - total_lua_byte_count)
    .." ("..total_lua_byte_count.." => "..total_pho_byte_count.."; "
    ..string.format("%.2f", (total_pho_byte_count / total_lua_byte_count) * 100).."%)"
  )
end
