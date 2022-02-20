
<p align="center">
  <img src="thumbnail_1080_1080.png" alt="Phobos Thumbnail" width="144"/>
</p>

# Phobos

Phobos is planned to be an optimizing bytecode compiler for Lua with some language extensions and a type system.\
See below for which features are implemented and which are planned.

# Lua Bytecode

Phobos currently only supports bytecode for Lua 5.2 with [this](src/constants.lua) header.

# Running Phobos

Download the zip for your platform from the GitHub Releases, extract all files and run it using this command in your command line or terminal:\
(If your OS blocks the executable for security reasons either allow them to run in properties (on windows) or preferences (on osx/macOS), or use your own Lua and LuaFileSystem binaries with the raw Phobos package)
```bash
./lua -- main.lua -h
```
**The working directory has to be the directory containing the main.lua file.** Use the `--working-dir` argument if you wish to use relative paths to said directory. Otherwise they are relative to the `main.lua` file, as that is the working directory.

<!-- cSpell:ignore cpath -->
You could also change the `LUA_PATH` and `LUA_CPATH` environment variables to include the Phobos directory but beware of name collisions. (See [package.path](https://www.lua.org/manual/5.2/manual.html#pdf-package.path) and [package.cpath](https://www.lua.org/manual/5.2/manual.html#pdf-package.cpath) and maybe [here](https://www.lua.org/manual/5.2/manual.html#7))

# Library (not really supported)

You can use Phobos as a library. The raw package from the github releases is meant for this, though it will most likely change in the future because actually using `.pho` source files from the library would be beneficial both to the programmer and the compiler.

# Factorio

## Factorio Mod

There is also a Factorio mod on the [Factorio Mod Portal](https://mods.factorio.com/mod/phobos) and in the GitHub Releases.\
It contains all files required to use Phobos **at runtime** (like a library), no command line tools.\
(Though as mentioned in the Library section, this is most likely going to undergo changes in the future)\
Additionally the mod, and only the mod, contains a `control.lua` file to register commands to run Phobos in the in-game console similar to regular Lua commands. Use `/help` in-game.

## Compiling for Factorio

When compiling (see next section) for a Factorio mod you currently **must** use `--use-load` because Factorio does not load bytecode Lua files.

Additionally it is recommended to use `--source-name @__mod-name__/?` to match Factorio's source name pattern (`mod-name` being your internal mod name).

If the your dev environment is setup such that the root of the `.pho` source files is the same as the `info.json` file then you most likely want to omit `--output` to generate compiled `.lua` files directly next to the source files.\
An example:
```
MyMod
  |- control.pho
  |- info.json
```
Would look like this after compilation:
```
MyMod
  |- control.lua
  |- control.pho
  |- info.json
```

# Compiling

`main.lua` is the entry point for compiling. Use `--help` for information on it's arguments.

# Disassembling (partially implemented)

There is no command line entry point for disassembling, but you can require the `disassembler` file to disassemble bytecode and print out disassembly wherever you want. It automatically extracts and uses Phobos debug symbols properly.

# Disassembly Language (not implemented)

Phobos is planned to be able to parse some form of disassembly language to then generate bytecode basically one to one.

# Formatting (not implemented)

Phobos is planned to be able to format your code.

## Refactoring (not implemented)

Phobos is planned to be able to run refactoring scripts based on AST to, well, refactor code.

# Phobos Debug Symbols

Phobos generated bytecode has better debug symbols.
Phobos also provides extra debug information beyond what regular Lua bytecode supports (like instruction column positions). The Lua VM won't do anything with this, but other tools may read this information, such as 
debuggers. See [phobos_debug_symbols.md](phobos_debug_symbols.md) for how Phobos provides this information.

# Language Extensions (not implemented)

Phobos syntax is based on Lua 5.2. By default Phobos will always be able to compile raw Lua, but some opt-in syntax may inevitably break compatibility with regular Lua syntax.

## Type System (not implemented)

Phobos is planned to be type aware. The idea is that it can figure out the majority of types on it's own, but there will most likely be ways for you to explicitly tell Phobos what type something should have.

## Safe Chaining Operators (not implemented)

The operators `?.`, `?:`, `?[]` and `?()` to replace the common Lua idiom `foo and foo.bar`. These allow more efficient re-use of intermediate results in deeply nested optional objects. `?.`, `?:` and `?[]` protect an indexing operation, while `?()` protects a function call, calling the function only if it exists (is not `nil` or `false`).

## Block Initializer Clauses (not implemented)

Modified versions of several block constructs are planned to allow defining block locals in the opening condition of the block.

```lua
if name_list = exp_list then ... end

do
  local name_list = exp_list
  if select(1,name_list) then ... end
end
```

```lua
while name_list = exp_list do ... end

do
  local name_list = exp_list
  while select(1,name_list) do
    ...
    name_list = exp_list
  end
end
```

## Compact Expression-body Lambda (not implemented)

Lua's existing function syntax is already fairly compact, but for the specific case of a function which simply returns an exp_list it can be reduced further:

```lua
(foo,bar) => foo?[bar]
```

## And More (not implemented)

There are lots of ideas for language extensions which are not listed here in the readme yet.

# Libraries, Dependencies and Licenses

Phobos itself is licensed under the MIT License, see [LICENSE.txt](LICENSE.txt).

<!-- cSpell:ignore Kulchenko, Mischak, Wellmann -->

- [Lua](https://www.lua.org/home.html) MIT License, Copyright (c) 1994–2021 Lua.org, PUC-Rio.
- [LuaFileSystem](https://keplerproject.github.io/luafilesystem/) MIT License, Copyright (c) 2003 - 2020 Kepler Project.
- [Serpent](https://github.com/pkulchenko/serpent) MIT License, Copyright (c) 2012-2018 Paul Kulchenko (paul AT kulchenko DOT com) (_email "encrypted" for scraping reasons_)
- [LFSClasses](https://github.com/JanSharp/LFSClasses) The Unlicense
- [LuaArgParser](https://github.com/JanSharp/LuaArgParser) MIT License, Copyright (c) 2021 Jan Mischak
- [LuaPath](https://github.com/JanSharp/LuaPath) The Unlicense
- [FactorioSumnekoLuaPlugin](https://github.com/JanSharp/FactorioSumnekoLuaPlugin) MIT License, Copyright (c) 2021-2022 Jan Mischak, justarandomgeek
- [minimal-no-base-mod](https://github.com/Bilka2/minimal-no-base-mod), Copyright (c) 2020 Erik Wellmann
- [JanSharpDevEnv](https://github.com/JanSharp/JanSharpDevEnv), Copyright (c) 2020 Jan Mischak

For license details see the [LICENSE_THIRD_PARTY.txt](LICENSE_THIRD_PARTY.txt) file and or the linked repositories above.

# Contributors

Huge thanks to justarandomgeek for starting the project in the first place (writing the majority of the first iteration of the parser and starting on the actual compiler) and then helping me understand several parts of compilers in general, the Lua VM, Lua bytecode and Lua internals.

Thanks to Therenas for providing built Lua and LuaFileSystem binaries for macOS and ensuring Phobos runs properly on macOS.

Thanks to the factorio modding community for providing input, ideas and discussion about Phobos as a whole. Without several people wanting types and no longer wanting to micro optimize their code Phobos would never have happened.

# Contributing

Phobos is still in it's early stages (i would say anyway) and i plan on refactoring several things multiple times over before i'd really suggest anyone to contribute to the project through PRs (pull requests). I have not written down the ideals and goals behind Phobos yet either, but one of the big points is to not feature creep. It's already a giant project in terms of ideas and plans.

# Building from Source

Clone the repo and init and or update all submodules. something like this should work:
```
git submodule init
git submodule update
```

There are `scripts/build_src.lua` and `scripts/build_factorio_mod.lua` which have to be run through `dev_entry_point.lua` (see that file itself for details).

If you're using vscode just run the build tasks from the command pallet.

Then to actually run src or those built "binaries" check the `.vscode/launch.json` file.

<!-- cSpell:ignore luarocks -->
<!--
Currently there are Windows Lua and LFS binaries in the repo, so just clone the repo and try running this in the root directory. if it is successful, Phobos will most likely run properly.
```
bin/windows/lua -- dev_entry_point.lua src tests/compile_test.lua
```
(for other platforms you'll somehow have to get those binaries. LFS is on luarocks, for the record)

To actually run the main.lua file you'll have to run src/main.lua like this (with additional args of course)
```
bin/windows/lua -- dev_entry_point.lua src src/main.lua
```
-->
