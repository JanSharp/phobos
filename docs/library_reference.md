
# Packages

You can use Phobos as a library. The raw package from the github releases (and the Factorio mod) is meant for this, though it will most likely change in the future because actually using `.pho` source files from the library would be beneficial both to the programmer and the compiler.

# Reference

There is no proper api for anything in Phobos yet. I do have some ideas for how to make a proper one, but like I mentioned in [Ideas and Plans](ideas_and_plans.md) other things take priority.

However some parts may remain a little bit more stable than others:

## Abstract Syntax Tree

The abstract syntax tree is probably going to stay roughly the same as it is now, with some additions in the future. That said, no guarantees. The [classes.lua](../src/classes.lua) file contains all of their type definitions. To get AST from source code you'll have to use `parser.lua` which returns a function. Said function takes the source code, the source name and an optional options table which currently only contains `use_int32` as a flag. The function returns the `ASTMain` data structure, and an array of `ErrorCodeInstance`s (empty array when successful). To make use of those error code instances, look at the [error_code_util.lua](../src/error_code_util.lua) file. Both the parser and error code APIs are not stable.

Note that the parser parses past syntax errors and always returns an AST. If there were syntax errors then the AST will contain `AstInvalidNode`s.

## Disassembler

The `disassembler.lua` has a tiny api, it's just 2 functions, however using it is currently a bit of a chore. I'm not sure how I'm going to make it less of a chore, but keep in mind that I may change it to make it easier to use.

### disassemble(bytecode) -> CompiledFunc

give it a bytecode string (like from `string.dump()`) and it returns a data structure representing said bytecode.

The resulting data structure is not stable and I don't wish to copy paste it into here, just for it to change without it changing here. You can check [classes.lua](../src/classes.lua) for CompiledFunc.

The most notable fields are these, since you'd need them in combination with `get_disassembly` to create human readable disassembly for all functions recursively:

- line_defined: integer? @ so you know where to put the function description from `func_description_callback`
- inner_functions: CompiledFunc[] @ to walk all functions recursively. Infinite recursion is impossible

### get_disassembly(func, func_description_callback, instruction_callback)

Parameters:

- func: expects a CompiledFunc from `disassemble`
- func_description_callback: a function taking one parameter which is a string describing the metadata of the given function. Said string contains newlines
- instruction_callback: a function that gets called for each instruction in the given function. It gets the following parameters:
  - line: integer?
  - column: integer?
  - instruction_index: integer
  - padded_opcode: string @ the name of the opcode, padded with spaces to all have the same length, left aligned
  - description: string @ a string describing what the instruction does
  - description_with_keys: string @ the same as description but with inlay hints for how the values get calculated from the raw values (see below)
  - raw_values: string @ the raw instruction argument values a, b, c, ax, bx, sbx formatted in a string
