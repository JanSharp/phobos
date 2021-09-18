
# General

Endianness is the same as Lua's, so since it only supports little endian right now, everything is little endian in here as well.

Indexes are 0 based. For ranges they are `start`: _including_, `end`: _excluding_.

Strings are encoded the same way as lua strings.

Phobos debug symbols exist on a per function basis, including main chunk.

# Identification

Phobos debug symbols are stored in an extra, unused string constant identified by it's length being _greater than_ the signature length + trailing `\0` (8 + 1 bytes) and it's first 8 bytes matching the signature.\
Phobos adds this constant as the last constant, however to allow for other tools to mess with bytecode just in case the specification does not require it to be the last constant.

(_Greater than_ because it allows for the signature alone to exist as a string in the constant table without it being identified as the phobos debug symbols)

The signature is
```lua
---last byte is a format version number
---which just starts at 0 and counts up
local phobos_signature = "\x1bPho\x10\x42\xf5\x00"
```

Just like any other string constant it has a trailing `\0` (which also counts towards the string's size).

Phobos debug symbols are between this signature and trailing `\0` in binary form.

# Phobos Debug Symbols

- `uint32` column_defined (0 for unknown or main chunk)
- `uint32` end_column (0 for unknown or main chunk)
- `uint32` num_instruction_columns (same as total instruction count)
- instruction_columns - array of (length = num_instruction_columns)
  - `uint32` column (0 for unknown)
- `uint32` num_sources
- sources - array of (length = num_sources)
  - `string` source (same format as Lua `source`) -- TODO: though `=` identifiers or raw sources probably don't make sense/aren't very smart
- `uint32` num_sections
- sections - array of (length = num_sections)
  - `uint32` instruction_index - section start index
  - `uint32` source_index - index in `sources`. instructions from this point forward originate from that source\
    0 stands for the regular Lua `source`, 1 is the 0th entry in `sources`

there is an implied first section with instruction_index and source_index both being `0`.

-- TODO: Phobos debug symbols will always be the last constant
