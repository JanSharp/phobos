
local profile_util = require("profile_util")
local arg_parser = require("lib.LuaArgParser.arg_parser")
local api_util = require("api_util")
local util = require("util")

---@class PhobosProfilesInternal : PhobosProfiles
local phobos_profiles = {
  internal = {
    all_profiles = {},
    profiles_by_name = {},
    main_args_config = nil, -- set by main.lua
    main_help_config = nil, -- set by main.lua
    -- the exact string that was passed in as an argument to the program
    -- (after going through a Path.new(filename):str() roundtrip - implementation details)
    current_profile_file = nil, -- set by main.lua
    current_root_dir = nil, -- set by main.lua
  },
}

local all_profiles = phobos_profiles.internal.all_profiles
local profiles_by_name = phobos_profiles.internal.profiles_by_name

function phobos_profiles.add_profile(params)
  local profile = api_util.api_call(function()
    local root_dir = params.root_dir
    params.root_dir = params.root_dir or phobos_profiles.internal.current_root_dir
    local profile = profile_util.new_profile(params)
    params.root_dir = root_dir
    -- add the profile
    api_util.assert(not profiles_by_name[profile.name],
      "Attempt to add 2 profiles with the name '"..profile.name.."'."
    )
    profiles_by_name[profile.name] = profile
    all_profiles[#all_profiles+1] = profile
    return profile
  end)
  return profile
end

function phobos_profiles.include(params)
  api_util.api_call(function()
    profile_util.include(params)
  end)
end

function phobos_profiles.exclude(params)
  api_util.api_call(function()
    profile_util.exclude(params)
  end)
end

function phobos_profiles.include_copy(params)
  api_util.api_call(function()
    profile_util.include_copy(params)
  end)
end

function phobos_profiles.exclude_copy(params)
  api_util.api_call(function()
    profile_util.exclude_copy(params)
  end)
end

function phobos_profiles.include_delete(params)
  api_util.api_call(function()
    profile_util.include_delete(params)
  end)
end

function phobos_profiles.exclude_delete(params)
  api_util.api_call(function()
    profile_util.exclude_delete(params)
  end)
end

function phobos_profiles.get_current_root_dir()
  return phobos_profiles.internal.current_root_dir
end

function phobos_profiles.get_all_optimizations()
  return profile_util.get_all_optimizations()
end

function phobos_profiles.parse_extra_args(extra_args, config)
  ---@diagnostic disable-next-line:redefined-local
  return phobos_profiles.custom_parse_extra_args(extra_args, function(extra_args)
    local args, err_or_index = arg_parser.parse(extra_args, config)
    if not args or args.help then
      if args then
        -- set it to nil if it was an index, making it an error message or nil
        -- which is what custom_parse_extra_args expects
        err_or_index = nil
      end
      local help_config = phobos_profiles.internal.main_help_config
      local usage = help_config.usage
      help_config.usage = nil
      local help = arg_parser.get_help_string(config, help_config)
      help_config.usage = usage
      return nil, err_or_index, help
    end
    return args
  end)
end

function phobos_profiles.custom_parse_extra_args(extra_args, custom_parse_function)
  local args, err, help = custom_parse_function(extra_args)
  if args == nil then
    if err then
      print("Invalid extra args: "..err.."\n")
    end
    print(arg_parser.get_help_string(
      phobos_profiles.internal.main_args_config,
      phobos_profiles.internal.main_help_config
    ))
    if help then
      print("\nExtra args for profiles file '"..phobos_profiles.internal.current_profile_file.."':\n"..help)
    end
    if err then
      util.abort()
    else
      os.exit(true)
    end
  end
  return args
end

return phobos_profiles
