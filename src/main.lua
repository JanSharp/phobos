
local Path = require("lib.LuaPath.path")
Path.use_forward_slash_as_main_separator_on_windows()
local arg_parser = require("lib.LuaArgParser.arg_parser")
arg_parser.register_type(Path.arg_parser_path_type_def)
local compile_util = require("compile_util")
local phobos_profiles = require("phobos_profiles")
local profile_util = require("profile_util")

local default_profile_files = {Path.new(".phobos_profiles")}

local args_config = {
  options = {
    {
      field = "profile_files",
      long = "profile-files",
      short = "p",
      description = "Paths to files that register phobos profiles.",
      type = "path",
      min_params = 1,
      default_value = default_profile_files,
    },
    {
      field = "profile_names",
      long = "profile-names",
      short = "n",
      description = "The profiles to run.",
      type = "string",
      min_params = 1,
      optional = true,
    },
    {
      field = "list",
      long = "list",
      short = "l",
      description = "List all registered profile names.",
      flag = true,
    },
    -- the clean/incremental option is not part of the profiles themselves because
    -- 99% of the time you want to uses incremental builds, and if you ever need to use
    -- a clean build you very most likely just want to run it once and then use incremental again
    {
      field = "clean",
      long = "clean",
      description = "Perform clean builds instead of incremental.",
      flag = true,
    },
  },
}

local help_config = {usage = "phobos [options] [-- {extra args passed to the profile files}]"}

phobos_profiles.internal.main_args_config = args_config
phobos_profiles.internal.main_help_config = help_config

local arg_strings = {...}
local args, last_arg_index = arg_parser.parse_and_print_on_error_or_help(arg_strings, args_config, help_config)
if not args then os.exit(false) end
if args.help then return end

if args.profile_files == default_profile_files then
  if not default_profile_files[1]:exists() then
    print("No such (default) '.phobos_profiles' file, stop.")
    print() -- empty line, just like the arg parser itself for invalid arg error messages
    print(arg_parser.get_help_string(args_config, help_config))
    -- since the message above reads like an error message, this should exit as a failure
    os.exit(false)
  end
end

local profiles_context = compile_util.new_context()
for _, profiles_path in ipairs(args.profile_files) do
  local main_chunk = assert(load(compile_util.compile({
    source_name = "@?",
    filename = profiles_path:str(),
    accept_bytecode = true,
  }, profiles_context), nil, "b"))
  phobos_profiles.internal.current_profile_file = profiles_path:str()
  phobos_profiles.internal.current_root_dir = profiles_path:sub(1, -2):to_fully_qualified():str()
  -- not sandboxed at all
  main_chunk(table.unpack(arg_strings, last_arg_index + 1))
end

---always returns a full sentence
local function get_list_of_all_profiles()
  if not phobos_profiles.internal.all_profiles[1] then
    return "No profiles added."
  end
  local names = {}
  for i, profile in ipairs(phobos_profiles.internal.all_profiles) do
    names[i] = "'"..profile.name.."'"
  end
  return "All profile names: "..table.concat(names, ", ").."."
end

if args.list or not args.profile_names then
  print(get_list_of_all_profiles())
  return
end

for _, name in ipairs(args.profile_names) do
  local profile = phobos_profiles.internal.profiles_by_name[name]
  if not profile then
    print("No such profile '"..name.."'. "..get_list_of_all_profiles())
    os.exit(false)
  end
  profile.incremental = not args.clean
  profile_util.run_profile(profile, print)
end

print(string.format("total time elapsed: %.3fs", os.clock()))
