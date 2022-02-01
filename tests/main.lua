
package.path = package.path..";./tests/lib/test_framework/?.lua;./tests/?.lua"

local framework = require("test_framework")

require("test_tokenizer")
require("test_parser")

framework.scope:run_tests()
