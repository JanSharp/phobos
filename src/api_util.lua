
local util = require("util")

local last_error_msg
local is_in_api_call = false

local function abort(msg)
  util.debug_assert(msg, "Must provide an error message for api errors.")
  if not is_in_api_call then
    util.debug_abort(msg)
  end
  if last_error_msg then
    local prev_msg = last_error_msg
    last_error_msg = nil
    util.debug_abort("Attempt to call api_error twice without an api_call handling the error in between. \n\z
      prev_msg: "..prev_msg.."\n\z
      msg: "..msg
    )
  end
  last_error_msg = msg
  error() -- "jump" to the message handler of the xpcall for api_call
end

local function api_assert(value, msg)
  if not value then
    abort(msg)
  end
  return value
end

local function get_last_api_error()
  return last_error_msg
end

local function pop_last_api_error()
  local msg = get_last_api_error()
  last_error_msg = nil
  return msg
end

---**Do not tailcall this function.** This function has to be on the stack to identify where the
---actual stacktrace that we want to show the programmer started.
local function api_call(func, pre_msg, post_msg)
  is_in_api_call = true
  local success, result = xpcall(func, function(msg)
    local api_error_msg = pop_last_api_error()
    if not api_error_msg then -- Wasn't an api error, but an internal error.
      return debug.traceback(msg, 2) -- Start at 2, no need to see traceback and this msg handler.
    end
    msg = "Api Error: "..(pre_msg or "")..api_error_msg..(post_msg or "")
    -- 0 = getinfo/traceback, 1 = this msg handler, 2 = error, 3 = function causing the error
    local level = 3 -- start searching at 3
    local info
    repeat
      info = debug.getinfo(level, "f")
      level = level + 1
    until not info or info.func == api_call -- Search until we find this api_call call.
    -- If didn't find api_call we show entire stack traceback. Otherwise level has already
    -- advanced to the function calling api_call so no need to modify level further.
    return debug.traceback(msg or "hi", info and level)
  end)
  if not success then
    print(result)
    os.exit(false)
  end
  is_in_api_call = false
  return result
end

return {
  abort = abort,
  assert = api_assert,
  api_call = api_call,
}
