
package.path = package.path..";./tests/lib/test_framework/?.lua;./tests/?.lua"

local arg_parser = require("lib.LuaArgParser.arg_parser")
local util = require("util")

local args = arg_parser.parse_and_print_on_error_or_help({...}, {
  options = {
    {
      field = "full_output",
      long = "full-output",
      short = "o",
      description = "Prints full outputs for contents equals by default",
      flag = true,
    },
    {
      field = "print_failed",
      long = "print-failed",
      short = "f",
      description = "Only print tests that failed. Scopes will still be\n\z
                     printed.",
      flag = true,
    },
    {
      field = "print_stacktrace",
      long = "print-stacktrace",
      short = "s",
      description = "Print the stack trace for failed tests.",
      flag = true,
    },
  },
}, {label_length = 80 - 4 - 2 - 50})
if not args then util.abort() end
if args.help then return end

local framework = require("test_framework")
local assert = require("assert")
assert.set_print_full_data_on_error_default(args.full_output)

require("test_tokenizer")
require("test_parser")
require("test_jump_linker")
require("test_serialize")
require("test_binary_serializer")

-- TODO: next ones to test:
-- ast_util
-- error_code_util
-- indexed_linked_list
-- io_util?
-- nodes (the parts that actually contain logic)
-- opcode_util
-- util

-- somehow test main.lua... not sure how I want to do that yet
-- same for control.lua

-- compiler, dump, disassembler, formatter, intermediate_language, optimize/*
-- won't be tested yet because chances of them changing drastically are high
-- even the test I've written so far are likely going change as I clean up the AST
-- so for now, all of those steps we have have to hope that they "just work", which
-- is obviously not the case. I'm certain there are bugs in there

local result = framework.scope:run_tests{
  only_print_failed = args.print_failed,
  print_stacktrace = args.print_stacktrace,
}
if result.failed_count > 0 then
  util.abort()
end
