
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

function Scope:run_tests()
  print(get_indentation(self)..self.name..":")
  if self.before_all then
    self.before_all()
  end
  local count = 0
  local failed_count = 0
  for _, test in ipairs(self.tests) do
    if test.is_scope then
      local result = test:run_tests()
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
      print(get_indentation(self).."  "..test.name..": "..(success and "passed" or ("failed: "..err)))
    end
  end
  if self.after_all then
    self.after_all()
  end
  print(get_indentation(self)..(count - failed_count).."/"..count.." passed in "..self.name)
  return {count = count, failed_count = failed_count}
end

return Scope
