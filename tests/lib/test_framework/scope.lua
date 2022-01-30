
local Scope = {}
Scope.__index = Scope

function Scope:new_scope(name)
  local scope = setmetatable({
    parent_scope = self,
    child_scopes = {},
    name = name,
    tests = {},
    before_all = nil,
    after_all = nil,
  }, Scope)
  if self then
    self.child_scopes[#self.child_scopes+1] = scope
  end
  return scope
end

function Scope:register_test(name, func)
  self.tests[#self.tests+1] = {
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
    count = count + 1
    local success, err = pcall(test.func)
    test.passed = success
    if not success then
      failed_count = failed_count + 1
      err = err:match(":%d+: (.*)")
      test.error_message = err
    end

    print(get_indentation(self).."  "..test.name..": "..(success and "passed" or ("failed: "..err)))
  end
  if self.after_all then
    self.after_all()
  end
  print(get_indentation(self)..(count - failed_count).."/"..count.." passed in "..self.name)
  if self.child_scopes[1] then
    for _, child_scope in ipairs(self.child_scopes) do
      local result = child_scope:run_tests()
      count = count + result.count
      failed_count = failed_count + result.failed_count
    end
    print(get_indentation(self)..(count - failed_count).."/"..count.." passed in "..self.name.." and its child scopes")
  end
  return {count = count, failed_count = failed_count}
end

return Scope
