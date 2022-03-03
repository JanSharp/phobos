
local profile_util = require("profile_util")

---@class PhobosProfilesInternal : PhobosProfiles
local phobos_profiles = {
  internal = {
    current_root_dir = nil, -- set by main.lua
    all_profiles = {},
    profiles_by_name = {},
  },
}

local all_profiles = phobos_profiles.internal.all_profiles
local profiles_by_name = phobos_profiles.internal.profiles_by_name

function phobos_profiles.add_profile(params)
  local root_dir = params.root_dir
  params.root_dir = params.root_dir or phobos_profiles.internal.current_root_dir
  local profile = profile_util.new_profile(params)
  params.root_dir = root_dir
  -- add the profile
  assert(not profiles_by_name[profile.name], "Attempt to add 2 profiles with the name '"..profile.name.."'.")
  profiles_by_name[profile.name] = profile
  all_profiles[#all_profiles+1] = profile
  return profile
end

function phobos_profiles.include(params)
  profile_util.include(params)
end

function phobos_profiles.exclude(params)
  profile_util.exclude(params)
end

function phobos_profiles.get_current_root_dir()
  return phobos_profiles.internal.current_root_dir
end

function phobos_profiles.get_all_optimizations()
  return profile_util.get_all_optimizations()
end

return phobos_profiles
