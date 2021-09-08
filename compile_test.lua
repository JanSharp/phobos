
-- args to manually run this:
-- compile_test.lua
-- or if the cache file was created using debug_compile_test_create_cache.lua:
-- compile_test.lua -c temp/debug_test_filename_cache.lua

local arg_parser = require("lib.LuaArgParser.arg_parser")
local args_config = {
  options = {
    {
      field = "cache_filename",
      long = "cache-filename",
      short = "c",
      description = "Relative path to a cache file containing the list of files to compile",
      single_param = true,
      type = "string",
      optional = true,
    },
    {
      field = "test_disassembler",
      long = "test-disassembler",
      short = "d",
      description = "Ensure get_disassembly doesn't throw errors with freshly\n\z
        compiled data nor disassembled data. Also ensure disassembled\n\z
        and then dumped bytecode is the same as the original bytecode",
      flag = true,
    },
    {
      field = "ensure_clean_data",
      long = "ensure-clean",
      short = "e",
      description = "Ensure the compiler doesn't leave the ast in a modified state",
      flag = true,
    },
    {
      field = "diff_files",
      long = "diff-files",
      short = "f",
      description = "Create files to be diffed for disassembler or compiler issues\n\z
        Files would be at `E:/Temp/.Compare/temp1.txt` and `E:/Temp/.Compare/temp2.txt`",
      flag = true,
    },
  },
}

local args
do
  local err
  args, err = arg_parser.parse({...}, args_config)
  if (not args) or args.help then
    if not args then
      print(err)
      print()
    end
    print(arg_parser.get_help_string(args_config))
    return
  end
end

local phobos_env = {}
for k, v in pairs(_G) do
  phobos_env[k] = v
end
phobos_env.arg = nil

local compiled_modules
local cached_modules = {}
function phobos_env.require(module)
  if cached_modules[module] then
    return cached_modules[module]
  end
  local original_module = module
  if module:find("/") then
    if not module:find("%.lua$") then
      module = module..".lua"
    end
  else
    module = module:gsub("%.", "/")..".lua"
  end

  local chunk = assert(compiled_modules[module], "No module '"..module.."'.")
  local result = {chunk()}
  cached_modules[original_module] = result[1] == nil and true or result[1]
  return table.unpack(result)
end

local parser
local jump_linker
local fold_const
local phobos
local dump
local disassembler

local compiled
local raw_compiled

local req

local function init()
  parser = req("parser")
  jump_linker = req("jump_linker")
  fold_const = req("optimize.fold_const")
  phobos = req("phobos")
  dump = req("dump")
  disassembler = req("disassembler")
end

local serpent = require("serpent")

local function compile(filename)
  local file = assert(io.open(filename,"r"))
  local text = file:read("*a")
  file:close()

  local ast = parser(text, "@"..filename)
  jump_linker(ast)
  fold_const(ast)
  local prev_ast_str
  if args.ensure_clean_data then
    prev_ast_str = serpent.block(ast)
  end
  local compiled_data = phobos(ast)
  if args.ensure_clean_data then
    local ast_str = serpent.block(ast)
    if ast_str ~= prev_ast_str then
      if args.diff_files then
        assert(io.open("E:/Temp/.Compare/temp1.txt", "w"))
          :write(prev_ast_str)
          :close()
        assert(io.open("E:/Temp/.Compare/temp2.txt", "w"))
          :write(ast_str)
          :close()
      end
      error("Compiler left a mess behind.")
    end
  end
  local bytecode = dump(compiled_data)
  if args.test_disassembler then
    local disassembled = disassembler.disassemble(bytecode)
    disassembler.get_disassembly(compiled_data, function() end, function() end)
    disassembler.get_disassembly(disassembled, function() end, function() end)
    if bytecode ~= dump(disassembled) then
      if args.diff_files then
        assert(io.open("E:/Temp/.Compare/temp1.txt", "w"))
          :write(serpent.block(compiled_data))
          :close()
        assert(io.open("E:/Temp/.Compare/temp2.txt", "w"))
          :write(serpent.block(disassembled))
          :close()
      end
      error("Disassembler has different output.")
    end
  end
  compiled[filename] = assert(load(bytecode, nil, "b", phobos_env))
  raw_compiled[filename] = bytecode
end

local function pcall_with_one_result(f, ...)
  local success, result = pcall(f, ...)
  if success then
    return result
  else
    return nil, result
  end
end

local filenames = {}
if args.cache_filename then
  filenames = assert(pcall_with_one_result(assert(loadfile(args.cache_filename, "t", {}))))
else
  filenames = require("debug_util").find_lua_source_files()
end

local function main()
  for _, filename in ipairs(filenames) do
    print(filename)
    compile(filename)
  end
end

print("compiling using phobos compiled by regular lua:")
local start_time = os.clock()

compiled = {}
raw_compiled = {}
req = require
init()
main()
local lua_result = compiled
local lua_raw_result = raw_compiled

print("compilation time ~ "..(os.clock() - start_time).."s")
print("--------")
print("compiling using phobos compiled by phobos:")
start_time = os.clock()

compiled_modules = lua_result
compiled = {}
raw_compiled = {}
req = phobos_env.require
init()
main()
local pho_result = compiled
local pho_raw_result = raw_compiled

print("compilation time ~ "..(os.clock() - start_time).."s")
print("--------")

-- a _lot_ of copy paste from main.lua

local unsafe = false
local print_progress = true
local use_regular_lua_compiler = true
local use_phobos_compiler = true
local do_fold_const = true
local eval_instruction_count = true
local eval_byte_count = true
local create_disassembly = true
local show_keys_in_disassembly = false
local load_and_run_compiled_funcs = false
local run_count = 1

local total_inst_diff = 0
local total_byte_diff = 0

local success = true
for k, v in pairs(pho_raw_result) do
  if v ~= lua_raw_result[k] then
    print("Bytecode differs for "..k..".")
    success = false
    if k == "test.lua" then
      local file = assert(io.open(k,"r"))
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
        lines[1][1] = "-- < line  compiler :  func_id  line  pc  opcode  description  params >\n"
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
            end, function(line_num, instruction_index, padded_opcode, description, description_with_keys, raw_values)
              description = show_keys_in_disassembly and description_with_keys or description
              local line = get_line(line_num)
              local min_description_len = 50
              line[#line+1] = string.format("-- %s  %s: %2df  %4d  %s  %s%s  %s",
              format_line_num(line_num),
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
          local out_file = io.open("E:/Temp/phobos/"..prefix..".txt", "w")
          out_file:write(serpent.block(func))
          out_file:close()
          func_id = 0
          add_func_to_lines_recursive(prefix, func)
        end
      end

      local lua_dumped = lua_raw_result[k]
      local pho_dumped = pho_raw_result[k]

      add_func_to_lines("lua", disassembler.disassemble(lua_dumped))
      add_func_to_lines("pho", disassembler.disassemble(pho_dumped))

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
          total_byte_diff = total_inst_diff + diff
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
  end
end
if success then
  print("No differences between compilation results - Success!")
end
