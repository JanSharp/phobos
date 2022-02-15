
local Scope = {}
Scope.__index = Scope

function Scope:new_scope(name)
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

function Scope:run_tests(options)
  local start_time = os and os.clock()
  print(get_indentation(self)..bold..self.name..reset..":")
  if self.before_all then
    self.before_all()
  end
  local count = 0
  local failed_count = 0
  for _, test in ipairs(self.tests) do
    if test.is_scope then
      local result = test:run_tests(options)
      count = count + result.count
      failed_count = failed_count + result.failed_count
    elseif test.is_test then
      count = count + 1
      local stacktrace
      local success, err = xpcall(test.func, function(msg)
        stacktrace = debug.traceback(nil, 2)
        return msg
      end)
      test.passed = success
      if not success then
        failed_count = failed_count + 1
        err = err:match(":%d+: (.*)")
        test.error_message = err
      end
      if not success or not options.only_print_failed then
        print(get_indentation(self).."  "..test.name..": "
          ..(success and (green.."passed"..reset) or (red.."failed"..reset..":"..(
            options.print_stacktrace
              and ("\n"..faint..magenta..stacktrace:gsub("\t", "  ")..reset.."\n")
              or " "
          )..err))
        )
      end
    end
  end
  if self.after_all then
    self.after_all()
  end
  print(get_indentation(self)..(count - failed_count).."/"..count.." "..green.."passed"..reset
    ..(failed_count > 0 and (" ("..failed_count.." "..faint..red.."failed"..reset..")") or "")
    .." in "..bold..self.name..reset
    -- this seems to be the max precision of os.clock, at least on my system
    ..(os and (" in "..string.format("%0.3f", (os.clock() - start_time) * 1000).."ms") or "")
  )
  return {count = count, failed_count = failed_count}
end

return Scope
