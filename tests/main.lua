
package.path = package.path..";./tests/lib/test_framework/?.lua;./tests/?.lua"

local framework = require("test_framework")

require("test_tokenizer")

framework.scope:run_tests()
