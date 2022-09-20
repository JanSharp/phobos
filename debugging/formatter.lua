
local parse = require("parser")
local format = require("formatter")
local error_code_util = require("error_code_util")

local function run(filename)
  print(filename)
  local file = assert(io.open(filename, "r"))
  local text = file:read("*a")
  assert(file:close())

  -- assert(assert(assert(
  --   io.open("temp/formatted_src.lua", "w"))
  --     :write(text))
  --     :close())

  local ast, errors = parse(text, "@"..filename)
  if errors[1] then
    print(error_code_util.get_message_for_list(errors, "syntax errors in "..filename))
  end
  text = format(ast)

  -- ast = parse(text, "@"..filename)
  -- if text ~= format(ast) then
  --   print("Parsing the formatted code and formatting again had a different result!")
  -- end

  assert(assert(assert(
    io.open("temp/formatted.lua", "w"))
      :write(text))
      :close())
end

local filenames
if ... then
  filenames = {...}
else
  filenames = require("debugging.debugging_util").find_lua_source_files()
end

local start_time = os.clock()
for _, filename in ipairs(filenames) do
  run(filename)
end
print(os.clock() - start_time)
