
local assert = require("assert")
local io_util = require("io_util")

---@class TestTest
---@field is_test true
---@field name string
---@field func fun()
---@field passed boolean? @ Set when running tests.
---@field error_message string? @ Set when running tests, specifically when `passed` is `false`.

---@class TestScope
---@field is_scope true
---@field parent_scope TestScope?
---@field child_scopes TestScope[]
---@field name string
---@field tests (TestTest|TestScope)[]
---@field before_all fun()?
---@field after_all fun()?
---A callback after each test, even for failing tests. Do not assert nor print anything here. It is called
---after everything for a test is done, which includes printing to standard out.
---@field after_each fun()?
local Scope = {}
Scope.__index = Scope

function Scope:new_scope(name)
  ---@type TestScope
  local scope = setmetatable({
    is_scope = true,
    parent_scope = self,
    child_scopes = {},
    name = name,
    tests = {},
    before_all = nil,
    after_all = nil,
  }, Scope)
  if self then
    self.child_scopes[#self.child_scopes+1] = scope
    self.tests[#self.tests+1] = scope
  end
  return scope
end

function Scope:add_test(name, func)
  self.tests[#self.tests+1] = {
    is_test = true,
    name = name,
    func = func,
  }
end

local function get_indentation(scope)
  local count = 0
  local current_scope = scope
  while current_scope.parent_scope do
    current_scope = current_scope.parent_scope
    count = count + 1
  end
  return string.rep("  ", count)
end

-- https://chrisyeh96.github.io/2020/03/28/terminal-colors.html
-- https://www2.ccs.neu.edu/research/gpc/VonaUtils/vona/terminal/vtansi.htm
local reset = "\x1b[0m"
local bold = "\x1b[1m"
local faint = "\x1b[2m"
local singly_underlined = "\x1b[4m"
local blink = "\x1b[5m"
local reverse = "\x1b[7m"
local hidden = "\x1b[8m"
-- foreground colors:
local black = "\x1b[30m"
local red = "\x1b[31m"
local green = "\x1b[32m"
local yellow = "\x1b[33m"
local blue = "\x1b[34m"
local magenta = "\x1b[35m"
local cyan = "\x1b[36m"
local white = "\x1b[37m"
-- background colors:
local background_black = "\x1b[40m"
local background_red = "\x1b[41m"
local background_green = "\x1b[42m"
local background_yellow = "\x1b[43m"
local background_blue = "\x1b[44m"
local background_magenta = "\x1b[45m"
local background_cyan = "\x1b[46m"
local background_white = "\x1b[47m"

local function should_run_test(full_scope_name, test_name, filters)
  local full_name = full_scope_name.."/"..test_name
  if not filters then return true end
  for _, scope_name in ipairs(filters) do
    if full_name:find(scope_name) then
      return true
    end
  end
  return false
end

local diff_state

local latest_expected_for_diff
local latest_got_for_diff
local function diff_callback(expected, got)
  latest_expected_for_diff = expected
  latest_got_for_diff = got
end

local function print_msg(msg)
  print(msg)
  if diff_state then
    diff_state.expected[#diff_state.expected+1] = msg
    diff_state.got[#diff_state.got+1] = msg
  end
end

local function print_latest_diff_msgs()
  if diff_state and latest_expected_for_diff and latest_got_for_diff then
    diff_state.expected[#diff_state.expected+1] = "expected:"
    diff_state.got[#diff_state.got+1] = "got:"
    diff_state.expected[#diff_state.expected+1] = latest_expected_for_diff
    diff_state.got[#diff_state.got+1] = latest_got_for_diff
    latest_expected_for_diff = nil
    latest_got_for_diff = nil
  end
end

local function write_diff_files()
  io_util.write_file("temp/diff/expected.txt", table.concat(diff_state.expected, "\n"))
  io_util.write_file("temp/diff/got.txt", table.concat(diff_state.got, "\n"))
end

---@param scope TestScope
---@param options any
---@param print_parent_scope_header any
---@param state any
---@param full_scope_name any
---@param is_root any
local function run_tests(scope, options, print_parent_scope_header, state, full_scope_name, is_root)
  -- header
  local start_time = os and os.clock()
  local printed_scope_header = false
  local function print_scope_header()
    if printed_scope_header then return end
    printed_scope_header = true
    print_parent_scope_header()
    print_msg(get_indentation(scope)..bold..scope.name..reset..":")
  end

  -- run tests
  if scope.before_all then
    scope.before_all()
  end
  local count = 0
  local failed_count = 0
  for _, test in ipairs(scope.tests) do
    if test.is_scope then
      ---@cast test TestScope
      local result = run_tests(test, options, print_scope_header, state, full_scope_name.."/"..test.name)
      count = count + result.count
      failed_count = failed_count + result.failed_count
    elseif test.is_test and should_run_test(full_scope_name, test.name, options.filters) then
      ---@cast test TestTest
      local id = state.next_id
      state.next_id = state.next_id + 1
      if not options.test_ids_to_run or options.test_ids_to_run[id] then
        count = count + 1
        local stacktrace
        local success, err = xpcall(test.func, function(msg)
          stacktrace = debug.traceback(nil, 2)
          return msg
        end)
        test.passed = success
        if not success then
          failed_count = failed_count + 1
          err = err and err:match(":%d+: (.*)")
          test.error_message = err
        end
        if not success or not options.only_show_failed then
          print_scope_header()
          print_msg(get_indentation(scope).."  ["..id.."] "..test.name..": "
            ..(success and (green.."passed"..reset) or (
              red.."failed"..reset..": "..blue..(err or "<no error message>")..reset
              ..(options.show_stacktrace and ("\n"..magenta..stacktrace:gsub("\t", "  ")..reset) or " ")
            ))
          )
          print_latest_diff_msgs()
        end
        if scope.after_each then
          scope.after_each()
        end
      end
    end
  end
  if scope.after_all then
    scope.after_all()
  end

  -- footer
  if is_root or printed_scope_header then
    print_msg(get_indentation(scope)..(count - failed_count).."/"..count.." "..green.."passed"..reset
      ..(failed_count > 0 and (" ("..failed_count.." "..faint..red.."failed"..reset..")") or "")
      .." in "..bold..scope.name..reset
      -- this seems to be the max precision of os.clock, at least on my system
      ..(os and (" in "..string.format("%0.3f", (os.clock() - start_time) * 1000).."ms") or "")
    )
  end
  return {count = count, failed_count = failed_count}
end

local function list_scopes(scope, depth, lines)
  lines.count = lines.count + 1 -- increment first to reserve the line
  local line_index = lines.count
  local count = 0
  for _, test in ipairs(scope.tests) do
    count = count + (test.is_test and 1 or test.is_scope and list_scopes(test, depth + 1, lines) or 0)
  end
  lines[line_index] = string.rep("  ", depth)..bold..scope.name..reset
    .." ("..count.." test"..(count == 1 and "" or "s")..")"
  return count
end

function Scope:list_scopes()
  local lines = {count = 0}
  list_scopes(self, 0, lines)
  for i = 1, lines.count do
    print(lines[i])
  end
end

function Scope:run_tests(options)
  if options.diff then
    diff_state = {expected = {}, got = {}}
    assert.set_diff_callback(diff_callback)
  else
    diff_state = nil
    assert.set_diff_callback(nil)
  end
  local result = run_tests(
    self,
    options,
    function() end,
    {next_id = 1, filters = options.filters},
    self.name,
    true
  )
  if options.diff then
    write_diff_files()
  end
  return result
end

return Scope
