
<p align="center">
  <img src="thumbnail_1080_1080.png" alt="Phobos Thumbnail" width="144"/>
</p>

# Phobos

Phobos's initial goal was to be an optimizing bytecode compiler for Lua with some language extensions and a type system.

This goal is no longer achievable because Factorio no longer supports loading Lua bytecode, only text, therefore any optimizations Phobos could make Factorio could not actually use. That leaves Phobos without a clear goal, so it simply exists as a fun little project containing tools for analyzing Lua code, for example.

That said, the furthest Phobos got in actually compiling was incredibly similar to how Lua itself compiles, just with AST (abstract syntax tree) as a step in between. Attempts at adding another step into the compile chain - intermediate language - failed at register coloring which is the process of assigning register indexes to variables (named and temporary), with the deal breaker always being Lua instructions which take a list of registers which must be adjacent to each other. Lining them up and making efficient use of registers without constant and needless MOVE instructions, while also ensuing that there aren't many gaps in register indexes since that could lead to running out of stack space in larger functions (max stack of each function is 250). I've made a few attempts, but was never able to meet all of the described requirements.

Phobos supports bytecode with the default Lua 5.2 signature.

# Table of Contents

Before going through these pages, take big note of the effective "deprecation" notes in the section above. I've not gone through and updated each of the pages, but rather I've left them more as an archive of the state of the project before it lost it's ability to fulfill its goal. And I won't lie, I was too ambitions.

- [Getting Started](docs/getting_started.md)
- [Factorio Support](docs/factorio_support.md)
- [Library/Reference](docs/library_reference.md)
- [Phobos Debug Symbols](docs/phobos_debug_symbols.md)
- [Ideas and Plans](docs/ideas_and_plans.md)
- [Contributing](docs/contributing.md)
- [Building from Source](docs/building_from_source.md)
- [Running from Source](docs/running_from_source.md)
- [Running Tests](docs/running_tests.md)

# Libraries, Dependencies and Licenses

Phobos itself is licensed under the MIT License, see [LICENSE.txt](LICENSE.txt).

<!-- cSpell:ignore Kulchenko, Mischak, Wellmann, Niklas, Frykholm -->

- [Lua](https://www.lua.org/home.html) MIT License, Copyright (c) 1994–2021 Lua.org, PUC-Rio.
- [LuaFileSystem](https://keplerproject.github.io/luafilesystem/) MIT License, Copyright (c) 2003 - 2020 Kepler Project.
- [Serpent](https://github.com/pkulchenko/serpent) MIT License, Copyright (c) 2012-2018 Paul Kulchenko (paul AT kulchenko DOT com) (_email "encrypted" for scraping reasons_)
- [LFSClasses](https://github.com/JanSharp/LFSClasses) The Unlicense
- [LuaArgParser](https://github.com/JanSharp/LuaArgParser) MIT License, Copyright (c) 2021-2022 Jan Mischak
- [LuaPath](https://github.com/JanSharp/LuaPath) The Unlicense
- [minimal-no-base-mod](https://github.com/Bilka2/minimal-no-base-mod), Copyright (c) 2020 Erik Wellmann
- [JanSharpDevEnv](https://github.com/JanSharp/JanSharpDevEnv), Copyright (c) 2020 Jan Mischak
- [markdown.lua](https://github.com/speedata/luamarkdown), Copyright (c) 2008 Niklas Frykholm

For license details see the [LICENSE_THIRD_PARTY.txt](LICENSE_THIRD_PARTY.txt) file and or the linked repositories above.

# Contributors

Huge thanks to justarandomgeek for starting the project in the first place (writing the majority of the first iteration of the parser and starting on the actual compiler) and then helping me understand several parts of compilers in general, the Lua VM, Lua bytecode and Lua internals.

Thanks to Therenas for providing built Lua and LuaFileSystem binaries for macOS and ensuring Phobos runs properly on macOS.

Thanks to the factorio modding community for providing input, ideas and discussion about Phobos as a whole. Without several people wanting types and no longer wanting to micro optimize their code Phobos would never have happened.
