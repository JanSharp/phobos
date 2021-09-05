
# General

endianness is the same as Lua's, so since it only supports little endian right now, everything is little endian in here as well.

Indexes are 0 based. For ranges they are `start`: _including_, `end`: _excluding_.

strings are encoded the same way as lua strings.

# Identification

phobos debug symbols are stored in an extra, unused string constant identified by it's length being _greater than_ the signature length + trailing `\0` (8 + 1 bytes) and it's first 8 bytes matching the signature.\
phobos adds this constant as the last constant, however to allow for other tools to mess with bytecode just in case the specification does not require it to be the last constant.

(_greater than_ because it allows for the signature alone to exist as a string in the constant table without it being identified as the phobos debug symbols)

The signature is
```lua
---last 2 bytes are a format version number
---which just starts at 0 and counts up\
---TODO: is that number always big endian or should it also reflect whichever endian is currently used?
local phobos_signature = "\x1bPho\x10\x42\x00\x00"
```

Just like any other string constant it has a trailing `\0` (which also counts towards the string's size).

phobos debug symbols are between this signature and trailing `\0` in binary form.

# Phobos Debug Symbols

- `uint32` line_defined (0 for main chunk)
- `uint32` column_defined (0 for main chunk)
- `uint32` end_line (0 for main chunk)
- `uint32` end_column (0 for main chunk)
- `uint32` num_instruction_positions (same as total instruction count)
- instruction_positions - array of (length = num_instructions)
  - `uint32` line
  - `uint32` column
- (--TODO: from this point forward i'm really not sure)
- `uint32` num_source_files
- source_files - array of (length = num_source_files)
  - `string` source_file_uri (--TODO: should it be a URI? a regular path? idk)
- `uint32` num_sections
- sections - array of (length = num_sections)
  - `uint32` instruction_index - section start index
  - `uint32` file_index - index in source_files. instructions from this point forward originate from that file

(this also contains line information in case the line numbers visible to regular lua are compound numbers consisting of line and column combined in some way)
