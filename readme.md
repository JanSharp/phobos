# Phobos

Phobos is an optimizing bytecode compiler for Lua with minor language extensions.

## Safe Chaining Operators

The operators `?.`, `?:`, `?[]` and `?()` to replace the common Lua idiom
`foo and foo.bar`. These allow more efficient re-use of intermediate results in deeply nested optional objects. `?.`, `?:` and `?[]` protect an indexing operation, while `?()` protects a function call, calling the function only if it exists.

## If Initializer Clause



## Compact Expression-body Lambda

Lua's existing function syntax is already fairly compact, but for the specific case of a function which simply returns an explist it can be reduced further:

```lua
(foo,bar) => foo?[bar]
```
