
local opcodes = {}
for i,op in ipairs{
  "move", "loadk", "loadkx", "loadbool", "loadnil",

  "getupval", "gettabup", "gettable",
  "settabup", "setupval", "settable",

  "new_table", "self",

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
