
local Path = require("lib.LuaPath.path")
Path.use_forward_slash_as_main_separator_on_windows()
local arg_parser = require("lib.LuaArgParser.arg_parser")
arg_parser.register_type(Path.arg_parser_path_type_def)
local compile_util = require("compile_util")
local phobos_profiles = require("phobos_profiles")
local profiles_util = require("profiles_util")

local args = arg_parser.parse_and_print_on_error_or_help({...}, {
  options = {
    {
      field = "profiles_files",
      long = "profiles-files",
      short = "p",
      type = "string",
      min_params = 1,
    },
    {
      field = "profile_names",
      long = "profile-names",
      short = "n",
      type = "string",
      min_params = 1,
    },
  },
})
if not args then return end

-- expose phobos_profiles as a `profiles` global for the duration of running profiles scripts
_ENV.profiles = phobos_profiles

local profiles_context = compile_util.new_context()
for _, profiles_file in ipairs(args.profiles_files) do
  local main_chunk = assert(load(compile_util.compile({
    source_name = "@?",
    filename = profiles_file,
    accept_bytecode = true,
  }, profiles_context), nil, "b"))
  local profiles_file_path = Path.new(profiles_file)
  phobos_profiles.internal.current_root_dir = profiles_file_path:sub(1, -2):to_fully_qualified():str()
  -- not sandboxed at all
  main_chunk()
end

-- the global is no longer needed
_ENV.profiles = nil

for _, name in ipairs(args.profile_names) do
  local profile = phobos_profiles.internal.profiles_by_name[name]
  if not profile then
    -- TODO: print list of profile names that were actually added
    error("No profile with the name '"..name.."' registered.")
  end
  profiles_util.run_profile(profile, print)
end

print(string.format("total time elapsed: %.3fs", os.clock()))
