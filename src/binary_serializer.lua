
-- everything is in **little endian**

local util = require("util")
local nodes = require("nodes")

---@type table<number, string>
local serialized_double_cache = {}

---@class BinarySerializer
---@field use_int32 boolean @ internal
---@field out string[] @ internal
---@field out_c integer @ internal
---@field length integer @ internal
---@field locked_length integer? @ internal
---@field reserved_count integer @ internal
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

function serializer:write_int8(value)
  check_bounds(value, -2 ^ 7, 2 ^ 7, "int8")
  if value < 0 then
    value = 0x100 + value
  end
  self:write_raw(string.char(value), 1)
end

function serializer:write_uint16(value)
  check_bounds(value, 0, 2 ^ 16, "uint16")
  self:write_raw(string.char(
    bit32.band(             value,     0xff),
    bit32.band(bit32.rshift(value, 8), 0xff)
  ), 2)
end

function serializer:write_int16(value)
  check_bounds(value, -2 ^ 15, 2 ^ 15, "int16")
  if value < 0 then
    value = 0x10000 + value
  end
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

function serializer:write_int32(value)
  check_bounds(value, -2 ^ 31, 2 ^ 31, "int32")
  if value < 0 then
    value = 0x100000000 + value
  end
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

function serializer:write_size_t(value)
  if self.use_int32 then
    self:write_uint32(value)
  else
    self:write_uint64(value)
  end
end

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

function serializer:write_double(value)
  -- Little endian reminder.
  if value == 0 then
    self:write_raw(((1 / value) < 0)
      and "\x00\x00\x00\x00\x00\x00\x00\x80"
      or "\x00\x00\x00\x00\x00\x00\x00\x00", 8)
    return
  end
  if value ~= value then
    self:write_raw("\xff\xff\xff\xff\xff\xff\xff\xff", 8)
    return
  end
  if value == (1/0) then
    self:write_raw("\x00\x00\x00\x00\x00\x00\xf0\x7f", 8)
    return
  end
  if value == (-1/0) then
    self:write_raw("\x00\x00\x00\x00\x00\x00\xf0\xff", 8)
    return
  end

  if serialized_double_cache[value] then
    self:write_raw(serialized_double_cache[value], 8)
    return
  end

  local signed = value < 0
  if signed then
    value = value * -1 -- Remove sign.
  end

  local exponentOffset = 0
  if value < 1 then -- Exponent in range [-1023, -1].
    exponentOffset = -1023
    value = value * (2 ^ 1023) -- Move exponent range from [-1023, -1] to [0, 1022].
    -- Moving it up and using an offset not only reduces code duplication but it is
    -- also required because we can only check for infinity when going too big, not
    -- too small. Checking for precision loss when going too small would not reasonably
    -- be doable, if at all.
  end
  -- Binary search for the exponent in range [0, 1023].
  local lower_bound = 1 -- Inclusive.
  local upper_bound = 1024 -- Inclusive.
  while lower_bound ~= upper_bound do
    local i = math.floor((lower_bound + upper_bound) / 2);
    if (value / (2 ^ -i)) == (1/0) then -- `i` can go up to 1024, so divide.
      upper_bound = i
    else
      lower_bound = i + 1
    end
  end
  local exponent = 1024 - lower_bound + exponentOffset -- In range [-1023, 1023].
  -- An exponent of -1023 is actually treated as -1022, except that the implied leading 1 becomes a 0.

  value = value * (2 ^ (52 - (math.max(-1022, exponent) - exponentOffset)))

  exponent = exponent + 1023 -- Move it into the range [0, 2046] just for the final write.
  -- for explanations behind this logic see write_uint_space_optimized
  -- the reason it is needed is because bit32 does accept values greater than uint32
  local double_str = string.char(
    value % 0x100,
    math.floor(value / 2 ^ (8 * 1)) % 0x100,
    math.floor(value / 2 ^ (8 * 2)) % 0x100,
    math.floor(value / 2 ^ (8 * 3)) % 0x100,
    math.floor(value / 2 ^ (8 * 4)) % 0x100,
    math.floor(value / 2 ^ (8 * 5)) % 0x100,
    (math.floor(value / 2 ^ (8 * 6)) % 0x10) -- Removes 4 bits, including the implied leading 1 bit.
      + bit32.lshift((exponent % 0x10), 4),
    (signed and 0x80 or 0) + bit32.rshift(exponent, 4)
  )
  serialized_double_cache[value] = double_str
  self:write_raw(double_str, 8)
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
      if self.use_int32 then
        self:write_int32(value)
      else
        self:write_double(value)
      end
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

---@class ReserveDefinition

---@param reserve_definition {length: integer, slots: integer?} @ `slots` default to `1`.
---@return ReserveDefinition
function serializer:reserve(reserve_definition)
  local out_c = self.out_c
  ---@diagnostic disable-next-line: inject-field
  reserve_definition.out_c = out_c
  self.out_c = out_c + (reserve_definition.slots or 1)
  self.length = self.length + reserve_definition.length
  self.reserved_count = self.reserved_count + 1
  return reserve_definition
end

---@param reserve_definition ReserveDefinition
---@param write_callback fun() @ Must write the amount of bytes as defined by `length` in the `reserve` call.
function serializer:write_to_reserved(reserve_definition, write_callback)
  ---@cast reserve_definition {out_c: integer, length: integer, slots: integer?, done: boolean?}
  if reserve_definition.done then
    util.debug_abort("Attempt to use the same 'reserve_definition' for multiple 'write_to_reserved' calls.")
  end
  reserve_definition.done = true
  self.reserved_count = self.reserved_count - 1
  local out_c = self.out_c
  local expected_length = self.length
  self.out_c = reserve_definition.out_c
  self.locked_length = self.length
  write_callback()
  self.locked_length = nil
  local got_slots = self.out_c - reserve_definition.out_c
  self.out_c = out_c
  local got_length = self.length - reserve_definition.length
  self.length = got_length
  local expected_slots = reserve_definition.slots or 1
  if expected_slots ~= got_slots then
    util.debug_abort("Expected 'write_callback' to make "..expected_slots.." write function calls, got "..got_slots..".")
  end
  if expected_length ~= got_length then
    util.debug_abort("Expected 'write_callback' to write "..reserve_definition.length
      .." bytes to the serializer, got "..(reserve_definition.length + (got_length - expected_length))..".")
  end
end

function serializer:tostring()
  if self.reserved_count > 0 then
    util.debug_abort("Attempt to call 'serializer.tostring' when 'reserve' was called "..self.reserved_count
      .." more times than 'write_to_reserved'. 'reserve' and 'write_to_reserved' calls must come in pairs.")
  end
  if self.reserved_count < 0 then
    util.debug_abort("Attempt to call 'serializer.tostring' when 'write_to_reserved' was called "..(-self.reserved_count)
      .." more times than 'reserve'. 'reserve' and 'write_to_reserved' calls must come in pairs.")
  end
  return table.concat(self.out)
end

function serializer:get_length()
  return self.locked_length or self.length
end

function serializer:get_use_int32()
  return self.use_int32
end

function serializer:set_use_int32(use_int32)
  util.debug_assert(type(use_int32) == "boolean",
    "Expected boolean for use_int32, got '"..tostring(use_int32).."'."
  )
  self.use_int32 = use_int32
end

---@param options Options?
---@return BinarySerializer
local function new_serializer(options)
  return setmetatable({
    use_int32 = options and options.use_int32 or false,
    out = {},
    out_c = 0,
    length = 0,
    locked_length = nil,
    reserved_count = 0,
  }, serializer)
end



---@class BinaryDeserializer
---@field use_int32 boolean @ internal
---@field binary_string string @ internal
---@field length integer @ internal
---@field index integer @ internal
---@field allow_reading_past_end boolean @ internal
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

function deserializer:read_int8()
  local value = self:read_bytes(1)
  if value >= 0x80 then
    value = value - 0x100
  end
  return value
end

function deserializer:read_uint16()
  local one, two = self:read_bytes(2)
  return one + bit32.lshift(two, 8)
end

function deserializer:read_int16()
  local one, two = self:read_bytes(2)
  local value = one + bit32.lshift(two, 8)
  if value >= 0x8000 then
    value = value - 0x10000
  end
  return value
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

function deserializer:read_int32()
  local one, two, three, four = self:read_bytes(4)
  local value = one
    + bit32.lshift(two, 8 * 1)
    + bit32.lshift(three, 8 * 2)
    + bit32.lshift(four, 8 * 3)
  if value >= 0x80000000 then
    value = value - 0x100000000
  end
  return value
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

function deserializer:read_size_t()
  return self.use_int32 and self:read_uint32() or self:read_uint64()
end

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

function deserializer:read_double()
  local one, two, three, four, five, six, seven, eight = self:read_bytes(8)
  local sign = (bit32.band(eight, 0x80) ~= 0) and -1 or 1
  local exponent = bit32.lshift(bit32.band(eight, 0x7f), 4) + bit32.rshift(bit32.band(seven, 0xf0), 4)
  -- using multiplication instead of lshift because we are exceeding the 32 bit limit of bit32
  local mantissa = one
    + two * 2 ^ (8 * 1)
    + three * 2 ^ (8 * 2)
    + four * 2 ^ (8 * 3)
    + five * 2 ^ (8 * 4)
    + six * 2 ^ (8 * 5)
    + bit32.band(seven, 0x0f) * 2 ^ (8 * 6)

  if exponent == 2047 then
    return mantissa ~= 0 and (0/0) or (sign * (1/0))
  end
  if exponent == 0 then
    exponent = -1022
  else
    exponent = exponent - 1023
    mantissa = mantissa + 0x0010000000000000
  end
  return sign * (mantissa * (2 ^ (exponent - 52)))
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
      return nodes.new_number{value = self.use_int32 and self:read_int32() or self:read_double()}
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

function deserializer:set_index(index)
  util.debug_assert(type(index) == "number", "Expected number arg for set_index, got '"..tostring(index).."'.")
  self.index = index
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

function deserializer:get_use_int32()
  return self.use_int32
end

function deserializer:set_use_int32(use_int32)
  util.debug_assert(type(use_int32) == "boolean",
    "Expected boolean for use_int32, got '"..tostring(use_int32).."'."
  )
  self.use_int32 = use_int32
end

---@param binary_string string
---@param start_index integer?
---@param options Options?
---@return BinaryDeserializer
local function new_deserializer(binary_string, start_index, options)
  return setmetatable({
    use_int32 = options and options.use_int32 or false,
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
