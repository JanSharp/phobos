
package.path = package.path..";./tests/lib/test_framework/?.lua;./tests/?.lua"

local framework = require("test_framework")

print_full_data_on_error = ({...})[1] == "--full-output"

require("test_tokenizer")
require("test_parser")

framework.scope:run_tests()
