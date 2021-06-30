
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

-- for _, token in require("tokenize")(text) do
--   print(serpent.block(token))
-- end

local main = require("parser")(text,"=("..filename..")")

require("optimize.fold_const")(main)

generate_code(main)

-- print(serpent.dump(main,{indent = '  ', sparse = true, sortkeys = false, comment=true}))

local dumped = require("dump")(main)
file = io.open("E:/Temp/test.lua", "w")
file:write(dumped)
file:close()

-- local foo = {string.byte(dumped, 1, #dumped)}
-- for i = 1, #foo do
--   foo[i] = "\\"..foo[i]
-- end
-- print('"'..table.concat(foo)..'"')
-- -- print(string.format("%q", dumped))

local out = {}
for _, instruction in ipairs(main.instructions) do
  instruction.op = opcodes[instruction.op + 1]
  if instruction.ck then
    instruction.c = instruction.ck
    instruction.ck = main.constants[(instruction.ck - 0xff) + 1] or ("! "..((instruction.ck - 0xff) + 1).." !")
  end
  out[#out+1] = serpent.line(instruction)
end

print("upvalues: "..serpent.block(main.upvals, {comment = false}))
print()
print("locals: "..serpent.block(main.locals, {comment = false}))
print()
print("constants: "..serpent.block(main.constants))
print()
print("instructions:")
print(table.concat(out, "\n"))

local b

--foo
