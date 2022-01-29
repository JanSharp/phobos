
# Safe Chaining

```lua
local foo
result = foo?.bar
result = foo?.bar?.baz
result, result2 = foo?()
result = foo?:bar?()

-- similar to
local foo

result = foo and foo.bar

do
  local temp = foo and foo.bar and 
  result = temp and temp.baz
end

-- allow for multiple results, unlike `foo and foo()`
if foo then
  result, result2 = foo()
else
  -- but this is still similar to `foo and foo()`
  result, result2 = foo, nil
end

if foo then
  local temp = foo.bar
  -- using the `temp and temp(foo)` variant because it's just 1 result.
  -- internally they are handled the same
  result = temp and temp(foo)
else
  result = foo
end
```

-- TODO: maybe keep some of this for doc reasons
-- ok, it has to be the register used as the result of this expression
-- but what is this expression? this expression consists of 2 things!
-- the self and the call
-- so, uhhhhh, what am i doing?
-- ok, the safe chaining state is used by subsequent safe chain expressions
-- (meaning the left hand side) to directly assign to the "result" if their
-- test fails
-- however, if the test fails, we cannot perform the call, nor can we index into it using SELF
-- ha! this is it.. wait no. damn it.
-- uuuuuhhhh, ok, what does SELF even do, what is it's purpose
-- index into b to get the function, and keep b in a register to use it as the first argument
-- that's all it does
-- so, if it's safe chaining, we want to only index if b is truthy
-- then continue with the call as we were, which _might_ also test if the function is truthy
-- but if it's falsy, we need to... do something...
-- if it's falsy we cannot index
-- therefore we cannot get the function
-- therefore we cannot perform the call
-- therefore we have to directly assign the the result of _the call_
-- the falsy value that is
-- which means
-- drum roll
-- they are both using the same safe chaining state!
-- well, in this case anyway
-- there is another case:
-- we don't safely index into b, but we do safely call the resulting function
-- in that case any safe chaining expressions in the expression b cannot directly assign to the
-- result, can they?
-- I don't think they can
-- hmmm, have to think
-- foo?.bar:baz?()
-- this is an example
-- if foo is falsy... it has to completely abort, no?
-- hold on, have to double check how this works in the index expression generation
-- my brain is melting
-- so, uh, the current implementation would actually just have `foo?.bar` evaluate to `foo`
-- without error, but would then try to index that using `baz`...
-- wait! that's the correct behavior... at least in my book
-- TODO: ask in mod-making if `foo?.bar.baz` should error or not
-- assuming this is correct, the current behavior that is, then it does have to break the
-- safe chaining chain if it's only safely calling, but not safely indexing
-- however if we go by that logic, it also has to error if you do `foo?:bar()`, because
-- `foo` evaluated to false or nil, then it doesn't index using bar, but it does attempt to call
-- `foo` using nil as the first argument
-- it sounds stupid, but it's consistent
-- ok this was a lot of typing, a lot of thinking, but I have gained great understanding
-- I hope you have too ;)
