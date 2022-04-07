
local parse = require("parser")
local format = require("formatter")
local error_code_util = require("error_code_util")
local io_util = require("io_util")

local function run(filename)
  print(filename)
  local text = io_util.read_file(filename)

  local ast, invalid_nodes = parse(text, "@"..filename)
  if invalid_nodes[1] then
    local msgs = {}
    for i, invalid_node in ipairs(invalid_nodes) do
      msgs[i] = error_code_util.get_message(invalid_node.error_code_inst)
    end
    print((#invalid_nodes).." syntax errors in "
      ..filename..":\n"..table.concat(msgs, "\n")
    )
  end
  text = format(ast)

  -- ast = parse(text, "@"..filename)
  -- if text ~= format(ast) then
  --   print("Parsing the formatted code and formatting again had a different result!")
  -- end

  io_util.write_file("temp/formatted.lua", text)
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
