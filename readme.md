
# Phobos

Phobos is an optimizing bytecode compiler for Lua with minor language extensions.

## Safe Chaining Operators

The operators `?.`, `?:`, `?[]` and `?()` to replace the common Lua idiom
`foo and foo.bar`. These allow more efficient re-use of intermediate results in deeply nested optional objects. `?.`, `?:` and `?[]` protect an indexing operation, while `?()` protects a function call, calling the function only if it exists.

## Block Initializer Clauses

Modified versions of several block constructs allow defining block locals in the opening condition of the block.

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

## Compact Expression-body Lambda

Lua's existing function syntax is already fairly compact, but for the specific case of a function which simply returns an exp_list it can be reduced further:

```lua
(foo,bar) => foo?[bar]
```

# Compiling with Phobos

Clone the repo and init and or update all submodules. something like this should work:
```
git submodule init
git submodule update
```

Currently there are Windows Lua and LFS binaries in the root dir of the repo, so just clone the repo and try running this in the root directory. if it is successful, phobos will most likely run properly.
```
bin/windows/lua52.exe -- entry_point.lua src tests/compile_test.lua
```
<!-- cSpell:ignore luarocks -->
(for other platforms you'll somehow have to get those binaries. LFS is on luarocks, for the record)

`main.lua` is the main entry point for phobos which can only compile right now.\
The arg parser does not print the most helpful help messages yet so you may want to read the arg config in the src/main.lua file for info about args.

To actually run the main.lua file when you cloned the repository (the only option at the moment) you'll have to run src/main.lua like this (with additional args of course)
```
bin/windows/lua52.exe -- entry_point.lua src src/main.lua
```

When compiling for factorio you'd most likely want to set `--use-load` and `--source-name @__mod-name__/?` (mod-name being your mod name) with just `--source` (pointing to your mod root) and no `--output` in order to compile all `.pho` files in the mod folder (and sub folders) into `.lua` files relative next to the source files. Optionally with `--ignore` of course.
