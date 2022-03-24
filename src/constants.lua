
return {
  ---how many fields SETLIST sets at once. I don't believe it is a hard limit, but considering
  ---the start index gets shifted by c * fields_per_flush it makes sense to stick to this limit
  fields_per_flush = 50,

  ---Phobos debug symbol signature
  phobos_signature = "\x1bPho\x10\x42\xff",
  phobos_debug_symbol_version = 0,

  lua_header_bytes = {
    0x1b, 0x4c, 0x75, 0x61, -- LUA_SIGNATURE
    0x52, 0x00, -- lua version
    -- lua config parameters: LE, 4 byte int, 8 byte size_t, 4 byte instruction, 8 byte LuaNumber, number is double
    0x01, 0x04, 0x08, 0x04, 0x08, 0x00,
    0x19, 0x93, 0x0d, 0x0a, 0x1a, 0x0a, -- magic
  },

  lua_signature_str = "\x1bLua",

  -- Lua Signature: "\x1bLua"
  -- byte version = "\x52"
  -- byte format = 0 (official)
  -- byte endianness = 1
  -- byte sizeof(int) = 4
  -- byte sizeof(size_t) = 8
  -- byte sizeof(Instruction) = 4
  -- byte sizeof(luaNumber) = 8
  -- byte lua_number is int? = 0
  -- magic "\x19\x93\r\n\x1a\n"
  lua_header_str = "\x1bLua\x52\0\1\4\8\4\8\0\x19\x93\r\n\x1a\n",

  unnamed_register_name = "(unnamed)",

  action_enum = {
    compile = 0,
    copy = 1,
    delete = 2,
  },
  action_name_lut = {
    [0] = "compile",
    [1] = "copy",
    [2] = "delete",
  },

  phobos_extension = ".pho",
  lua_extension = ".lua",
}
