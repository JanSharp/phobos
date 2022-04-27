
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
      description = "Only print tests that failed and scopes containing\n\z
                     tests that failed, except the root result that\n\z
                     always gets printed.",
      flag = true,
    },
    {
      field = "print_stacktrace",
      long = "print-stacktrace",
      short = "s",
      description = "Print the stack trace for failed tests.",
      flag = true,
    },
    {
      field = "test_ids",
      long = "test-ids",
      short = "i",
      description = "Only run tests with the given ids.",
      type = "number",
      optional = true,
      min_params = 0,
    },
    {
      field = "scopes",
      long = "scopes",
      short = "c",
      description = "Scopes to run, like 'root/foo/bar'. (Lua patterns)",
      type = "string",
      optional = true,
      min_params = 0,
    }
  },
}, {label_length = 80 - 4 - 2 - 50})
if not args then util.abort() end
if args.help then return end

local framework = require("test_framework")
local assert = require("assert")
assert.set_print_full_data_on_error_default(args.full_output)

-- test testing framework
require("test_virtual_file_system")
require("test_virtual_io_util")

-- test src
require("test_tokenizer")
require("test_parser")
require("test_jump_linker")
require("test_serialize")
require("test_binary_serializer")
require("test_emmy_lua_parser")
require("test_emmy_lua_linker")
require("test_cache")
require("test_profile_util")

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

local util_abort = util.abort
local util_assert = util.assert
util.abort = util.debug_abort
util.assert = util.debug_assert

local result = framework.scope:run_tests{
  only_print_failed = args.print_failed,
  print_stacktrace = args.print_stacktrace,
  test_ids_to_run = args.test_ids and util.invert(args.test_ids),
  scopes = args.scopes,
}

util.debug_abort = util_abort
util.debug_assert = util_assert

if result.failed_count > 0 then
  util.abort()
end
