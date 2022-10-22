
local framework = require("test_framework")
local assert = require("assert")

local nodes = require("nodes")
local parser = require("parser")
local jump_linker = require("jump_linker")
local formatter = require("formatter")
local ast = require("ast_util")
local error_code_util = require("error_code_util")

local tutil = require("testing_util")
local append_stat = ast.append_stat
local test_source = tutil.test_source

local prevent_assert = nodes.new_invalid{
  error_code_inst = error_code_util.new_error_code{
    error_code = error_code_util.codes.incomplete_node,
    source = test_source,
    position = {line = 0, column = 0},
  }
}

local function test_formatter(name, text, modify_ast)
  local parsed_ast = parser(text, "=("..name..")")
  jump_linker(parsed_ast)
  if modify_ast then
    modify_ast(parsed_ast)
  end
  local result = formatter(parsed_ast)
  assert.equals(text, result)
end

do
  local main_scope = framework.scope:new_scope("formatter")

  local function add_test(name, text, modify_ast)
    main_scope:add_test(name, function()
      test_formatter(name, text, modify_ast)
    end)
  end

  add_test("invalid node with src_paren_wrappers", "(@)")
end
