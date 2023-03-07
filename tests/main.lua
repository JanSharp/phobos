
package.path = package.path..";./tests/lib/test_framework/?.lua;./tests/?.lua"

local shell_util = require("shell_util")

local arg_parser = require("lib.LuaArgParser.arg_parser")
local util = require("util")

local args = arg_parser.parse_and_print_on_error_or_help({...}, {
  options = {
    {
      field = "verbose",
      long = "verbose",
      short = "v",
      description = "Prints full outputs for contents_equals by default",
      flag = true,
    },
    {
      field = "show_failed",
      long = "failed",
      short = "f",
      description = "Only print tests that failed and scopes containing\n\z
                     tests that failed, except the root result which\n\z
                     always gets printed.",
      flag = true,
    },
    {
      field = "show_stacktrace",
      long = "stacktrace",
      short = "s",
      description = "Print the stack traceback for failed tests.",
      flag = true,
    },
    {
      field = "test_ids",
      long = "id",
      description = "Only run tests with the given ids.",
      type = "number",
      optional = true,
      min_params = 0,
    },
    {
      field = "filters",
      long = "filter",
      description = "Only run tests matching any of the given filters\n\z
                     (Lua patterns). Filters are matched against \n\z
                     'root/first_scope/second_scope/hello world test'.",
      type = "string",
      optional = true,
      min_params = 0,
    },
    {
      field = "list_scopes",
      long = "list-scopes",
      description = "List all scopes and their test counts.",
      flag = true,
    },
    {
      field = "diff",
      long = "diff",
      description = "Open a diff for failing tests.",
      flag = true,
    },
    {
      field = "diff_tool",
      long = "diff-tool",
      description = "Open an external diff tool for failing tests.\n\z
                     %expected% and %got% will be substituted with\n\z
                     properly escaped paths to the files to diff.\n\z
                     For example: 'code --wait --diff %expected% %got%'",
      type = "string",
      single_param = true,
      optional = true,
    },
  },
}, {label_length = 80 - 4 - 2 - 50})
if not args then util.abort() end
---@cast args -?
if args.help then return end

local framework = require("test_framework")
local assert = require("assert")
assert.set_print_full_data_on_error_default(args.verbose)

-- test testing framework
require("test_virtual_file_system")
require("test_virtual_io_util")

-- test src
require("test_linked_list")
require("test_indexed_linked_list")
require("test_tokenizer")
require("test_parser")
require("test_jump_linker")
require("test_formatter")
require("test_serialize")
require("test_binary_serializer")
require("test_emmy_lua_parser")
require("test_emmy_lua_linker")
require("test_cache")
require("test_profile_util")
require("test_number_ranges")
require("test_linq")

-- TODO: next ones to test:
-- ast_util
-- error_code_util
-- io_util?
-- nodes (the parts that actually contain logic)
-- opcode_util
-- util

-- somehow test main.lua... not sure how I want to do that yet
-- same for control.lua

-- compiler, dump, disassembler, intermediate_language, optimize/*
-- won't be tested yet because chances of them changing drastically are high
-- even the test I've written so far are likely going to change as I clean up the AST
-- so for now, all of those steps we have have to hope that they "just work", which
-- is obviously not the case. I'm certain there are bugs in there

if args.list_scopes then
  framework.scope:list_scopes()
  return
end

local util_abort = util.abort
local util_assert = util.assert
util.abort = util.debug_abort
util.assert = util.debug_assert

local result = framework.scope:run_tests{
  only_show_failed = args.show_failed,
  show_stacktrace = args.show_stacktrace,
  test_ids_to_run = args.test_ids and util.invert(args.test_ids),
  filters = args.filters,
  diff = args.diff or (args.diff_tool and true) or false,
}

util.debug_abort = util_abort
util.debug_assert = util_assert

if result.failed_count > 0 then
  if args.diff_tool then
    assert(io.popen((args.diff_tool
      :gsub("%%expected%%", shell_util.escape_arg("temp/diff/expected.txt"))
      :gsub("%%got%%", shell_util.escape_arg("temp/diff/got.txt")))
    )):close()
  elseif args.diff then
    assert(io.popen("git diff --minimal --color-moved --color-words --unified=10000 --no-index -- \z
      temp/diff/expected.txt temp/diff/got.txt", "w"
    )):close()
  end
  util.abort()
end
