
# General

Endianness is the same as Lua's, so since Phobos only supports little endian right now, everything is little endian in here as well.

Indexes are 0 based. For ranges they are `start`: _including_, `end`: _excluding_.

Strings are encoded the same way as lua strings. See [dump.lua](src/dump.lua). Just like any other string constant it has a trailing `\0` (which also counts towards the string's size).

Phobos debug symbols exist per function, including main chunk.

Phobos debug symbols are between the signature and trailing `\0` in binary form.

# Identification

Phobos Debug Symbols are stored in an extra, unused string constant which is the last constant in the constant table and must start with the signature `"\x1bPho\x10\x42\xf5"` **plus** a version number.

The version number is a single byte counting from 0-254. At 255 it will start using the next byte the same way, so `fe` would be version 254, `ff00` 255, `ff01` 256. (just in case this ever gets that high)

## Collisions

If the source of the bytecode you are consuming is unknown, meaning it could be coming from regular Lua or Phobos, it may be wise to check if the string constant is _larger_ than the signature alone. This doesn't make collisions impossible, but it's incredibly unlikely that one would have that kind of string as a string constant in source code. Even Phobos itself doesn't.

Phobos itself will always output collision free bytecode by adding an unused nil constant when necessary.

# Format

## Version 0
**Introduced in v0.1.0**

- `uint32` column_defined (0 for unknown or main chunk)
- `uint32` end_column (0 for unknown or main chunk)
- `uint32` num_instruction_columns (same as total instruction count)
- instruction_columns - (length = num_instruction_columns) array of
  - `uint32` column (0 for unknown)
- `uint32` num_sources
- sources - (length = num_sources) array of
  - `string` source (same format as [lua_Debug](https://www.lua.org/manual/5.2/manual.html#lua_Debug) `source`)
- `uint32` num_sections
- sections - (length = num_sections) array of
  - `uint32` instruction_index - section start index
  - `uint32` source_index - index in `sources`. Instructions from this point forward originate from that source.
    0 stands for the lua_Debug `source` of this function, 1 is the 0th entry in `sources` and so on.

there is an implied first section with `instruction_index` and `source_index` both being `0`.

<!-- Notes:

If debug symbols was to support/allow for combined line information it would very most likely be 3 digits (least significant) for the column and the rest for the line, only stored in the regular line debug symbols. Phobos debug symbols would most likely just have a flag indicating wether or not these combined line numbers are used and the array of column numbers would be empty (but still exist because that's easier to consume).

Phobos debug symbols should not contain duplicate data which is already in regular debug symbols.

-->
