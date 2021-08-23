
local serpent = require("serpent")

local filename = ... or "phobos.lua"
local file = io.open(filename,"r")
local text = file:read("*a")
file:seek("set")
local lines = {}
for line in file:lines() do
  lines[#lines+1] = {line = line}
end
-- add trailing line because :lines() doesn't return that one if it's empty
-- (since regardless of if the previous character was a newline,
-- the current one is eof which returns nil)
if text:sub(#text) == "\n" then
  lines[#lines+1] = {line = ""}
end
file:close()

if not lines[1] then -- empty file edge case
  lines[1] = {line = ""}
end

local disassembler = require("disassembler")

lines[1][1] = "-- < line  compiler :  func_id  line  pc  opcode  description  params >\n"

local function format_line_num(line_num)
  -- this didn't work (getting digit count): (math.ceil((#lines) ^ (-10))), so now i cheat:
  local h = ("%"..(#tostring(#lines)).."d")
  local f = string.format("%"..(#tostring(#lines)).."d", line_num)
  return string.format("%"..(#tostring(#lines)).."d", line_num)
end

local function get_line(line)
  return assert(lines[line] or lines[1])
end

local add_func_to_lines
do
  local func_id
  local function add_func_to_lines_recursive(prefix, func)
    func_id = func_id + 1
    disassembler.get_disassembly(func, function(description)
      local line = get_line(func.first_line)
      line[#line+1] = "-- "..prefix..": "..(description:gsub("\n", "\n-- "..prefix..": "))
    end, function(line_num, instruction_index, padded_opcode, description, description_with_keys, raw_values)
      -- description = description_with_keys
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

    for _, inner_func in ipairs(func.inner_functions) do
      add_func_to_lines_recursive(prefix, inner_func)
    end
  end
  function add_func_to_lines(prefix, func)
    func_id = 0
    add_func_to_lines_recursive(prefix, func)
  end
end

local lua_func, err = loadfile(filename)
if lua_func then
  add_func_to_lines("lua", disassembler.disassemble(string.dump(lua_func)))
else
  print(err)
end

-- for _, token in require("tokenize")(text) do
--   print(serpent.block(token))
-- end

do
  -- i added this because the debugger was not breaking on error inside a pcall
  -- and now it suddenly does break even with this set to false.
  -- i don't understand
  local unsafe = false
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

  success, err = pcall(require("optimize.fold_const"), main)
  if not success then print(err) goto finish end

  success, err = pcall(require("phobos"), main)
  if not success then print(err) goto finish end
  -- print(serpent.dump(main,{indent = '  ', sparse = true, sortkeys = false, comment=true}))

  local dumped
  success, dumped = pcall(require("dump"), main)
  if not success then print(dumped) goto finish end

  local disassembled
  success, disassembled = pcall(disassembler.disassemble, dumped)
  if not success then print(disassembled) goto finish end

  add_func_to_lines("pho", disassembled)

  local pho_func
  pho_func, err = load(dumped)
  if not pho_func then print(err) goto finish end

  if lua_func then
    print("----------")
    print("lua:")

    success, err = pcall(lua_func)
    if not success then print(err) goto finish end
  end

  print("----------")
  print("pho:")

  success, err = pcall(pho_func)
  if not success then print(err) goto finish end

  print("----------")
end

::finish::
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

local b
