
local serpent = require("serpent")
local disassembler = require("disassembler")

local unsafe = true
local print_progress = true
local use_regular_lua_compiler = true
local use_phobos_compiler = true
local do_fold_const = true
local do_create_inline_iife = true
local eval_instruction_count = true
local eval_byte_count = true
local create_disassembly = true
local show_keys_in_disassembly = false
local load_and_run_compiled_funcs = true
local run_count = 1

local total_inst_diff = 0
local total_byte_diff = 0

local function compile(filename)
  if print_progress then
    print("compiling '"..filename.."'...")
  end

  local file = assert(io.open(filename,"r"))
  local text = file:read("*a")

  file:seek("set")
  local lines
  if create_disassembly then
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

  if create_disassembly then
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
        disassembler.get_disassembly(func, function(description)
          local line = get_line(func.first_line)
          line[#line+1] = "-- "..prefix..": "..(description:gsub("\n", "\n-- "..prefix..": "))
        end, function(line_num, column_num, instruction_index, padded_opcode, description, description_with_keys, raw_values)
          description = show_keys_in_disassembly and description_with_keys or description
          local line = get_line(line_num)
          local min_description_len = 50
          line[#line+1] = string.format("-- %s %3d %s: %2df  %4d  %s  %s%s  %s",
            format_line_num(line_num),
            column_num or 0,
            prefix,
            func_id,
            instruction_index,
            padded_opcode,
            description,
            (min_description_len - #description > 0) and string.rep(" ", min_description_len - #description) or "",
            raw_values
          )
        end)
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

    local success, main = pcall(require("parser"), text, "@"..filename)
    if not success then print(main) goto finish end
    -- print(serpent.block(main))

    success, err = pcall(require("jump_linker"), main)
    if not success then print(err) goto finish end

    if do_fold_const then
      success, err = pcall(require("optimize.fold_const"), main)
      if not success then print(err) goto finish end
    end

    if do_create_inline_iife then
      success, err = pcall(require("optimize.create_inline_iife"), main)
      if not success then print(err) goto finish end
    end

    local compiled
    success, compiled = pcall(require("phobos"), main)
    if not success then print(compiled) goto finish end
    -- print(serpent.dump(main,{indent = '  ', sparse = true, sortkeys = false, comment=true}))

    success, pho_dumped = pcall(require("dump"), compiled)
    if not success then print(pho_dumped) goto finish end

    if eval_byte_count or create_disassembly then
      local disassembled
      success, disassembled = pcall(disassembler.disassemble, pho_dumped)
      if not success then print(disassembled) goto finish end

      add_func_to_lines("pho", disassembled)
    end

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
    if diff then
      total_inst_diff = total_inst_diff + diff
    end
  end
  if eval_byte_count then
    local lua = use_regular_lua_compiler and lua_dumped and #lua_dumped or nil
    local pho = use_phobos_compiler and pho_dumped and #pho_dumped or nil
    local diff = lua and pho and pho - lua or nil
    print(" #bytes:        "..serpent.line{lua = lua, pho = pho}
      ..(diff and (" diff: "..diff) or "")
    )
    if diff then
      total_byte_diff = total_byte_diff + diff
    end
  end

  if create_disassembly then
    local result = {}
    for _, line in ipairs(lines) do
      for _, pre in ipairs(line) do
        result[#result+1] = pre
      end
      result[#result+1] = line.line
    end

    file = io.open("E:/Temp/phobos-disassembly.lua", "w")
    file:write(table.concat(result, "\n"))
    file:close()
  end
end

for i = 1, run_count do
  for _, filename in ipairs{...} do
    compile(filename)
    if print_progress then
      print()
    end
  end
  print(os.clock() / i)
  if print_progress then
    print()
    print()
  end
end

if eval_instruction_count and use_regular_lua_compiler and use_phobos_compiler then
  print("total instruction count diff: "..total_inst_diff)
end
if eval_byte_count and use_regular_lua_compiler and use_phobos_compiler then
  print("total byte count diff:        "..total_byte_diff)
end
