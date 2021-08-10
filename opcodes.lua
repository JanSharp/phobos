
local opcodes = {}
for i,op in ipairs{
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
} do
  opcodes[op] = i-1
end

return opcodes
