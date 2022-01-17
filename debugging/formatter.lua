
local parse = require("parser")
local format = require("formatter")

local function run(filename)
  print(filename)
  local file = assert(io.open(filename, "r"))
  local text = file:read("*a")
  assert(file:close())

  -- assert(assert(assert(
  --   io.open("temp/formatted_src.lua", "w"))
  --     :write(text))
  --     :close())

  local ast, invalid_nodes = parse(text, "@"..filename)
  if invalid_nodes[1] then
    local msgs = {}
    for i, invalid_node in ipairs(invalid_nodes) do
      msgs[i] = invalid_node.error_message
    end
    error((#invalid_nodes).." syntax errors in "
      ..filename..":\n"..table.concat(msgs, "\n")
    )
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
  filenames = require("debugging.util").find_lua_source_files()
end

local start_time = os.clock()
for _, filename in ipairs(filenames) do
  run(filename)
end
print(os.clock() - start_time)
