
with types there can be several optimizations related to comparisons
this below were some ideas but there is a lot more to be done and this idea is incomplete:
`foo == false` to `not foo` optimization if foo is known to never be `nil`
`foo == true` to `foo` with "convert to bool flag" optimization

-- TODO: add a short list of most useful things Phobos can be used for

redundant op_test optimization


very loosely related to phobos:
what I use for setting up to and compiling all factorio mods for testing and fun:
unix-like systems specific:

shell docs stuff and how to stop running shell sub processes or whatever they're called
https://pubs.opengroup.org/onlinepubs/9699919799/
https://unix.stackexchange.com/questions/48425/how-to-stop-the-loop-bash-script-in-terminal
https://unix.stackexchange.com/questions/19816/where-can-i-find-official-posix-and-unix-documentation

extracting all factorio mods
```shell
target=/mnt/big/phobos_temp/extracted
rm -r "$target"
mkdir "$target"
for file in /mnt/big/data/FactorioModsManager/Mods_1.1/*; do
  name=${file##*/}
  unzip $file "*.lua" -d "$target/${name%.*}"
done
```


when adding anything other than errors as error codes - so infos or warnings - expose severity to build profiles

expose compile_util options.custom_header to build profiles

have an understanding of units for numbers. m/s (speed) * s (time) = m (distance) for example

when stripping debug symbols ensure that the last constant in the constant table cannot be mistaken as Phobos debug symbols by appending an unused nil constant if it is the case.

add list of all the features that are implemented in the docs.



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

## Global Definitions

Add a definition statements for globals, like `define global foo` and only then a standalone `foo` expression is a valid index into _ENV. Explicit indexing into _ENV would still be allowed regardless of what globals are defined.

## And More (not implemented)

There are lots of ideas for language extensions which are not listed here in the readme yet.
