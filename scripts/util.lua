
local invert = require("invert")

local profile_names = {
  "debug",
  "release",
}
local build_profiles = invert(profile_names)

local build_profile_type_id = "build_profile"
local arg_parser_build_profile_type_def = {
  id = build_profile_type_id,
  arg_count = 1,
  convert = function(arg, context)
    if build_profiles[arg] then
      return arg
    else
      local serpent = require("lib.serpent")
      return nil, "Expected one of "..serpent.line(profile_names)
        ..", got '"..arg.."' "..context.."."
    end
  end,
  compare = function(left, right)
    return left == right
  end,
}

local function get_dir_name(profile)
  return profile
end

return {
  profile_names = profile_names,
  build_profile_type_id = build_profile_type_id,
  arg_parser_build_profile_type_def = arg_parser_build_profile_type_def,
  get_dir_name = get_dir_name,
}
