
local serpent = require("serpent")
local generate_code = require("phobos")

local opcodes = {
  "move", "loadk", "loadkx", "loadbool", "loadnil",

  "getupval", "gettabup", "gettable",
  "settabup", "setupval", "settable",

  "newtable", "self",

  "add", "sub", "mul", "div", "mod", "pow",
  "unm", "not", "len",

  "concat",

  "jmp", "eq", "lt", "le",

  "test", "testset",

  "call", "tailcall", "return",

  "forloop", "forprep",
  "tforcall", "tforloop",

  "setlist",
  "closure",
  "vararg",
  "extraarg",
}

local filename = ... or "phobos.lua"
local file = io.open(filename,"r")
local text = file:read("*a")
file:close()

local disassembler = require("disassembler")

local function print_disassemply_recursive(func)
  print(disassembler.get_disassembly(func))
  print()
  for _, inner_func in ipairs(func.inner_functions) do
    print_disassemply_recursive(inner_func)
  end
end

print(filename..":")
print()
print(text)
print()
print("--------------------------------------------------")
print()
print("regular Lua:")
print()
print_disassemply_recursive(disassembler.disassemble(string.dump(assert(loadfile(filename)))))
print("--------------------------------------------------")
print()
print("phobos:")
print()

-- for _, token in require("tokenize")(text) do
--   print(serpent.block(token))
-- end

local main = require("parser")(text, "@"..filename)
-- print(serpent.block(main))

require("optimize.fold_const")(main)

generate_code(main)

-- print(serpent.dump(main,{indent = '  ', sparse = true, sortkeys = false, comment=true}))

local dumped = require("dump")(main)

print_disassemply_recursive(disassembler.disassemble(dumped))

local b
