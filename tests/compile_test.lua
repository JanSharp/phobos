
local arg_parser = require("lib.LuaArgParser.arg_parser")

local args = arg_parser.parse_and_print_on_error_or_help({...}, {
  options = {
    {
      field = "use_filename_cache",
      long = "use-filename-cache",
      short = "c",
      description = "Use `temp/compile_test_filename_cache.lua` \z
        instead of using LFS to find all files to compile.",
      single_param = true,
      type = "string",
      optional = true,
    },
    {
      field = "create_filename_cache",
      long = "create-filename-cache",
      short = "m",
      description = "Create `temp/compile_test_filename_cache.lua` for future runs to use.",
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
      field = "test_formatter",
      long = "test-formatter",
      short = "r",
      description = "Ensure code => AST => code conversion preserves code structure",
      flag = true,
    },
    {
      field = "diff_files",
      long = "diff-files",
      short = "f",
      description = "Create files to be diffed for disassembler or compiler or generated bytecode issues\n\z
        Files would be at `temp/before.txt` and `temp/after.txt`",
      flag = true,
    },
  },
})
if not args then return end

local Path = require("lib.LuaPath.path")
if not Path.new("temp"):exists() then
  assert(require("lfs").mkdir("temp"))
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

  local chunk = assert(
    compiled_modules[module] or compiled_modules["src/"..module],
    "No module '"..module.."'."
  )
  local result = {chunk()}
  cached_modules[original_module] = result[1] == nil and true or result[1]
  return table.unpack(result)
end

local parser
local jump_linker
local fold_const
local fold_control_statements
local compiler
local dump
local disassembler
local formatter

local compiled
local raw_compiled

local req

local function init()
  parser = req("parser")
  jump_linker = req("jump_linker")
  fold_const = req("optimize.fold_const")
  fold_control_statements = req("optimize.fold_control_statements")
  compiler = req("compiler")
  dump = req("dump")
  disassembler = req("disassembler")
  formatter = req("formatter")
end

local serpent = require("lib.serpent")

local function compile(filename)
  local file = assert(io.open(filename,"r"))
  local text = file:read("*a")
  file:close()

  local ast = parser(text, "@"..filename)

  if args.test_formatter then
    local formatted = formatter(ast)
    if text ~= formatted then
      if args.diff_files then
        assert(io.open("temp/before.txt", "w"))
          :write(text)
          :close()
        assert(io.open("temp/after.txt", "w"))
          :write(formatted)
          :close()
      end
      error("Formatter has different output.")
    end
  end

  jump_linker(ast)
  fold_const(ast)
  fold_control_statements(ast)
  local prev_ast_str
  if args.ensure_clean_data then
    prev_ast_str = serpent.block(ast)
  end
  local compiled_data = compiler(ast)

  if args.ensure_clean_data then
    local ast_str = serpent.block(ast)
    if ast_str ~= prev_ast_str then
      if args.diff_files then
        assert(io.open("temp/before.txt", "w"))
          :write(prev_ast_str)
          :close()
        assert(io.open("temp/after.txt", "w"))
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
        assert(io.open("temp/before.txt", "w"))
          :write(serpent.block(compiled_data))
          :close()
        assert(io.open("temp/after.txt", "w"))
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
if args.use_filename_cache then
  filenames = assert(pcall_with_one_result(assert(loadfile("temp/compile_test_filename_cache.lua", "t", {}))))
else
  filenames = require("debugging.util").find_lua_source_files()
  if args.create_filename_cache then
    local cache_file = assert(io.open("temp/compile_test_filename_cache.lua", "w"))
    cache_file:write(serpent.dump(filenames))
    assert(cache_file:close())
  end
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

local success = true
for k, v in pairs(pho_raw_result) do
  if v ~= lua_raw_result[k] then
    print("Bytecode differs for "..k..".")
    success = false
    if args.diff_files then
      assert(io.open("temp/before.txt", "w"))
        :write(serpent.block(require("disassembler").disassemble(lua_raw_result[k])))
        :close()
      assert(io.open("temp/after.txt", "w"))
        :write(serpent.block(require("disassembler").disassemble(v)))
        :close()
    end
  end
end

if success then
  print("No differences between compilation results - Success!")
else
  error("Bytecode differed for some files.")
end
