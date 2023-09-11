
-- everything is in **little endian**
-- if we ever support big endian builds of Lua make sure to flip doubles,
-- since those are using Lua bytecode to save and load

local util = require("util")
local nodes = require("nodes")

local serializer = {}
serializer.__index = serializer

local function check_bounds(value, min, max, name)
  -- using string.format with %d to prevent use of scientific notation
  -- because it just confuses me otherwise, and doesn't look as good
  if (value % 1) ~= 0 then
    util.debug_abort(string.format("Value must be an integer: '%f'.", value))
  end
  if value < min or max <= value then
    util.debug_abort(string.format(
      "Value out of bounds for %s, expected %d <= %d < %d.",
      name, min, value, max
    ))
  end
end

function serializer:write_raw(value, length)
  self.out_c=self.out_c+1;self.out[self.out_c] = value
  self.length = self.length + (length or #value)
end

function serializer:write_uint8(value)
  check_bounds(value, 0, 2 ^ 8, "uint8")
  self:write_raw(string.char(value), 1)
end

function serializer:write_uint16(value)
  check_bounds(value, 0, 2 ^ 16, "uint16")
  self:write_raw(string.char(
    bit32.band(             value,     0xff),
    bit32.band(bit32.rshift(value, 8), 0xff)
  ), 2)
end

local function write_small(self, value, write_big)
  if value >= 0xff then
    self:write_raw("\xff", 1)
    write_big(self, value)
  else
    self:write_uint8(value)
  end
end

local function write_medium(self, value, write_big)
  if value >= 0xffff then
    self:write_raw("\xff\xff", 2)
    write_big(self, value)
  else
    self:write_uint16(value)
  end
end

function serializer:write_small_uint16(value)
  write_small(self, value, self.write_uint16)
end

function serializer:write_uint32(value)
  check_bounds(value, 0, 2 ^ 32, "uint32")
  self:write_raw(string.char(
    bit32.band(             value,         0xff),
    bit32.band(bit32.rshift(value, 8 * 1), 0xff),
    bit32.band(bit32.rshift(value, 8 * 2), 0xff),
    bit32.band(bit32.rshift(value, 8 * 3), 0xff)
  ), 4)
end

function serializer:write_small_uint32(value)
  write_small(self, value, self.write_uint32)
end

function serializer:write_medium_uint32(value)
  write_medium(self, value, self.write_uint32)
end

---More like uint53, but takes the space of an uint64.\
---I don't see myself supporting actual uint64s in the future, but to make it easier for
---other languages that do have 64 bit integers, I'm using the same size.\
---Errors if `value >= 2 ^ 53`
function serializer:write_uint64(value)
  -- technically a double can represent integral values from 0 to 2 ^ 53 including including
  -- without missing any value in between, but it would be weird to break the rule for this
  -- already weird case. We're literally just loosing 1 possible value
  check_bounds(value, 0, 2 ^ 53, "uint64 (actually uint53)")
  -- for explanations behind this logic see write_uint_space_optimized
  -- the reason it is needed is because bit32 does accept values greater than uint32
  self:write_raw(string.char(
    value % 0x100,
    math.floor(value / 2 ^ (8 * 1)) % 0x100,
    math.floor(value / 2 ^ (8 * 2)) % 0x100,
    math.floor(value / 2 ^ (8 * 3)) % 0x100,
    math.floor(value / 2 ^ (8 * 4)) % 0x100,
    math.floor(value / 2 ^ (8 * 5)) % 0x100,
    math.floor(value / 2 ^ (8 * 6)) % 0x100, -- 3 highest bits will always be 0
    0 -- math.floor(value / 2 ^ (8 * 7)) % 0x100 -- no need, always 0
  ), 8)
end

function serializer:write_small_uint64(value)
  write_small(self, value, self.write_uint64)
end

function serializer:write_medium_uint64(value)
  write_medium(self, value, self.write_uint64)
end

-- If we're compiling a program with strings longer than 9_007_199_254_740_989 (2 ^ 53 - 2) bytes,
-- so 9 petabytes, something has gone horribly wrong anyway.
-- (note: -2 because 2 ^ 53 itself is excluded for consistency,
-- and every string is 1 byte longer because of the trailing \0)

---It's just an alias, but might be useful to know all uses cases of size_t in the future
serializer.write_size_t = serializer.write_uint64

function serializer:write_uint_space_optimized(value)
  check_bounds(value, 0, 2 ^ 53, "space optimized uint (up to 53 bits)")
  repeat
    -- `value % 0x80` is effectively cutting off all bits from 8 and higher
    -- leaving the last 7 bits. just like `bit32.band(value, 0x7f))`, except that
    -- bit32.band won't work with numbers greater than uint32
    self:write_uint8(((value >= 0x80) and 0x80 or 0) + (value % 0x80))
    -- this is effectively right shifting by 7 bits
    -- and even though we have an intermediate state with fractions, we only modified the exponent
    -- which means there is no precision loss
    value = math.floor(value / 2 ^ 7)
  until value == 0
end

do
  local double_start, double_end = string.dump(load("return 523123.123145345")--[[@as function]])
    :find("\54\208\25\126\204\237\31\65")
  if not double_start then
    util.debug_abort("Unable to set up double to bytes conversion.")
  end
  ---@cast double_start -nil
  ---@cast double_end -nil
  local double_cache = {
    -- these two don't print %a correctly, so preload the cache with them
    -- **little endian** reminder
    [1/0] = "\0\0\0\0\0\0\xf0\x7f",
    [-1/0] = "\0\0\0\0\0\0\xf0\xff",
  }
  function serializer:write_double(value)
    if value ~= value then -- nan also also doesn't print %a correctly
      self:write_raw("\xff\xff\xff\xff\xff\xff\xff\xff", 8)
    elseif double_cache[value] then
      self:write_raw(double_cache[value], 8)
    else
      local double_str = string.dump(load(string.format("return %a", value))--[[@as function]])
        :sub(double_start, double_end)
      double_cache[value] = double_str
      self:write_raw(double_str, 8)
    end
  end
end

function serializer:write_string(value)
  if not value then
    self:write_medium_uint64(0)
  else
    self:write_medium_uint64(#value + 1)
    self:write_raw(value)
  end
end

---All strings can be nil, except in the constant table.
function serializer:write_lua_string(value)
  -- typedef string:
  -- size_t length (including trailing \0, 0 for nil)
  -- char[] value (not present for nil)
  if not value then
    self:write_size_t(0)
  else
    self:write_size_t(#value + 1)
    self:write_raw(value)
    self:write_raw("\0", 1)
  end
end

function serializer:write_boolean(value)
  self:write_raw(value and "\1" or "\0", 1)
end

do
  -- byte type = {nil = 0, boolean = 1, number = 3, string = 4}
  local const_lut = setmetatable({
    ["nil"] = function(self)
      self:write_raw("\0", 1)
    end,
    ["boolean"] = function(self, value)
      self:write_raw("\1", 1)
      self:write_boolean(value)
    end,
    ["number"] = function(self, value)
      self:write_raw("\3", 1)
      self:write_double(value)
    end,
    ["string"] = function(self, value)
      self:write_raw("\4", 1)
      self:write_lua_string(value)
    end,
  }, {
    __index = function(_, node_type)
      util.debug_abort("Invalid Lua constant node type '"..node_type
        .."', expected 'nil', 'boolean', 'number' or 'string'."
      )
    end
  })
  function serializer:write_lua_constant(constant_node)
    const_lut[constant_node.node_type](self, constant_node.value)
  end
end

function serializer:tostring()
  return table.concat(self.out)
end

function serializer:get_length()
  return self.length
end

local function new_serializer(initial_binary_string)
  return setmetatable({
    out = {initial_binary_string},
    out_c = initial_binary_string and 1 or 0,
    length = initial_binary_string and #initial_binary_string or 0,
  }, serializer)
end



local deserializer = {}
deserializer.__index = deserializer

local function can_read(self, byte_count)
  if self.allow_reading_past_end then return end
  if self.index + byte_count - 1 > self.length then
    error(string.format("Attempt to read %d bytes starting at index %d where binary_string length is %d.",
      byte_count, self.index, self.length
    ))
  end
end

function deserializer:read_raw(byte_count)
  can_read(self, byte_count)
  local result = self.binary_string:sub(self.index, self.index + byte_count - 1)
  self.index = self.index + byte_count
  return result
end

function deserializer:read_bytes(byte_count)
  can_read(self, byte_count)
  self.index = self.index + byte_count -- do this first because :byte() returns var results
  return self.binary_string:byte(self.index - byte_count, self.index - 1)
end

function deserializer:read_uint8()
  return self:read_bytes(1)
end

function deserializer:read_uint16()
  local one, two = self:read_bytes(2)
  return one + bit32.lshift(two, 8)
end

local function read_small(self, read_big)
  local value = self:read_uint8()
  return value == 0xff and read_big(self) or value
end

local function read_medium(self, read_big)
  local value = self:read_uint16()
  return value == 0xffff and read_big(self) or value
end

function deserializer:read_small_uint16()
  return read_small(self, self.read_uint16)
end

function deserializer:read_uint32()
  local one, two, three, four = self:read_bytes(4)
  return one
    + bit32.lshift(two, 8 * 1)
    + bit32.lshift(three, 8 * 2)
    + bit32.lshift(four, 8 * 3)
end

function deserializer:read_small_uint32()
  return read_small(self, self.read_uint32)
end

function deserializer:read_medium_uint32()
  return read_medium(self, self.read_uint32)
end

function deserializer:read_uint64()
  local one, two, three, four, five, six, seven, eight = self:read_bytes(8)
  if seven > 0x1f or eight ~= 0 then
    error("Unsupported to read uint64 (actually uint53) greater or equal to 2 ^ 53.")
  end
  -- using multiplication instead of lshift because we are exceeding the 32 bit limit of bit32
  return one
    + two * 2 ^ (8 * 1)
    + three * 2 ^ (8 * 2)
    + four * 2 ^ (8 * 3)
    + five * 2 ^ (8 * 4)
    + six * 2 ^ (8 * 5)
    + seven * 2 ^ (8 * 6)
    -- + eight * 2 ^ (8 * 7) -- always 0
end

function deserializer:read_small_uint64()
  return read_small(self, self.read_uint64)
end

function deserializer:read_medium_uint64()
  return read_medium(self, self.read_uint64)
end

---It's just an alias, but might be useful to know all uses cases of size_t in the future
deserializer.read_size_t = deserializer.read_uint64

function deserializer:read_uint_space_optimized()
  local shift = 0
  local result = 0
  repeat
    local byte = self:read_bytes(1)
    if shift == 7 * 7 --[[49]] and byte > 0x0f then
      error("Unsupported to read space optimized uint greater or equal to 2 ^ 53.")
    end
    -- again using multiplication instead of lshift
    result = result + bit32.band(byte, 0x7f) * 2 ^ shift
    shift = shift + 7
  until byte < 0x80
  return result
end

do
  local dumped = string.dump(load("return 523123.123145345")--[[@as function]])
  local double_start, double_end = dumped:find("\54\208\25\126\204\237\31\65")
  if double_start == nil then
    util.debug_abort("Unable to set up bytes to double conversion")
  end
  local prefix = dumped:sub(1, double_start - 1) -- excludes first double byte (\54)
  local postfix = dumped:sub(double_end + 1) -- excludes the last byte of the found sequence (\65)
  local double_cache = {}

  function deserializer:read_double()
    local double_bytes = self:read_raw(8)
    if double_cache[double_bytes] then
      return double_cache[double_bytes]
    else
      local double_func, err = load(prefix..double_bytes..postfix, "=(double deserializer)", "b")
      if not double_func then
        util.debug_abort("Unable to deserialize double, see inner error: "..err)
      end
      ---@cast double_func -?
      local success, result = pcall(double_func)
      if not success then
        util.debug_abort("Unable to deserialize double, see inner error: "..result)
      end
      return result
    end
  end
end

function deserializer:read_string()
  local size = self:read_medium_uint64()
  if size == 0 then
    return nil
  else
    return self:read_raw(size - 1)
  end
end

function deserializer:read_lua_string()
  local size = self:read_size_t()
  if size == 0 then -- 0 means nil
    return nil
  else
    local result = self:read_raw(size - 1)
    self:read_bytes(1) -- trailing \0
    return result
  end
end

function deserializer:read_boolean()
  return self:read_bytes(1) ~= 0
end

do
  local const_lut = {
    [0] = function()
      return nodes.new_nil{}
    end,
    [1] = function(self)
      return nodes.new_boolean{value = self:read_boolean()}
    end,
    [3] = function(self)
      return nodes.new_number{value = self:read_double()}
    end,
    [4] = function(self)
      local value = self:read_lua_string()
      if not value then
        error("Lua constant strings must not be 'nil'.")
      end
      return nodes.new_string{value = value}
    end,
  }
  setmetatable(const_lut, {
    __index = function(_, k)
      error("Invalid Lua constant type '"..k.."', expected 0 (nil), 1 (boolean), 3 (number) or 4 (string).")
    end,
  })
  function deserializer:read_lua_constant()
    return const_lut[self:read_bytes(1)](self)
  end
end

function deserializer:get_string()
  return self.binary_string
end

function deserializer:get_length()
  return self.length
end

---Gets the index of the next byte to be read.
function deserializer:get_index()
  return self.index
end

function deserializer:is_done()
  return self.index > self.length
end

---Settings this to true doesn't exactly mean reading past the end doesn't cause issues.\
---In fact you can expect every function except read_raw and read_bytes to error in some way.\
---This option purely exists to allow for weird edge cases, just in case.
function deserializer:set_allow_reading_past_end(allow_reading_past_end)
  util.debug_assert(type(allow_reading_past_end) == "boolean",
    "Expected boolean for allow_reading_past_end, got '"..tostring(allow_reading_past_end).."'."
  )
  self.allow_reading_past_end = allow_reading_past_end
end

function deserializer:get_allow_reading_past_end()
  return self.allow_reading_past_end
end

local function new_deserializer(binary_string, start_index)
  return setmetatable({
    binary_string = binary_string,
    length = #binary_string,
    index = start_index or 1,
    allow_reading_past_end = false,
  }, deserializer)
end

return {
  new_serializer = new_serializer,
  new_deserializer = new_deserializer,
}
