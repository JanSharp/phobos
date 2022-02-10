
package.path = package.path..";./tests/lib/test_framework/?.lua;./tests/?.lua"

local arg_parser = require("lib.LuaArgParser.arg_parser")

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
  },
}, {label_length = 80 - 4 - 2 - 50})
if not args then return end

local framework = require("test_framework")
local assert = require("assert")
assert.set_print_full_data_on_error_default(args.full_output)

require("test_tokenizer")
require("test_parser")

framework.scope:run_tests{
  only_print_failed = args.print_failed,
}
