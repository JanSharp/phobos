
local Path = require("lib.LuaPath.path")
Path.set_main_separator("/")
local arg_parser = require("lib.LuaArgParser.arg_parser")
arg_parser.register_type(Path.arg_parser_path_type_def)
local compile_util = require("compile_util")
local phobos_profiles = require("phobos_profiles")
local profile_util = require("profile_util")
local phobos_version = require("phobos_version")
local api_util = require("api_util")
local util = require("util")
local sandbox_util = require("sandbox_util")

local default_profile_files = {Path.new("phobos_profiles")}

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
    -- the rebuild/incremental option is not part of the profiles themselves because
    -- you want to use incremental builds 99% of the time, and if you ever need to use
    -- a rebuild you very most likely just want to run it once and then use incremental again
    {
      field = "rebuild",
      long = "rebuild",
      description = "Perform a rebuild instead of an incremental build.",
      flag = true,
    },
    {
      field = "version",
      long = "version",
      description = "Prints the current version of Phobos to std out.",
      flag = true,
    },
    {
      field = "foo",
      long = "foo",
      type = "path",
      single_param = true,
      optional = true,
    },
  },
}

local help_config = {usage = "phobos [options] [-- {extra args passed to the profile files}]"}

phobos_profiles.internal.main_args_config = args_config
phobos_profiles.internal.main_help_config = help_config

local arg_strings = {...}
local args, last_arg_index = arg_parser.parse_and_print_on_error_or_help(arg_strings, args_config, help_config)
if not args then util.abort() end
if args.help then return end

if args.version then
  print(string.format("%d.%d.%d", phobos_version.major, phobos_version.minor, phobos_version.patch))
  return
end

if args.profile_files == default_profile_files
  and not args.profile_names
  and not args.list
  and not args.foo
then
  print("No args provided, use '--help' for help message.")
  return
end

if args.foo then
  util.assert(args.foo:exists(), "No such file "..args.foo:str())
  sandbox_util.enable_phobos_require()
  local context = compile_util.new_context()
  local main_chunk = assert(load(compile_util.compile({
    filename = args.foo:str(),
    source_name = "@?",
    accept_bytecode = true,
    error_message_count = 8,
  }, context)))
  main_chunk()
  return
end

if args.profile_files == default_profile_files then
  if not default_profile_files[1]:exists() then
    print("No such (default) 'phobos_profiles' file, stop.")
    print() -- empty line, just like the arg parser itself for invalid arg error messages
    print(arg_parser.get_help_string(args_config, help_config))
    -- since the message above reads like an error message, this should exit as a failure
    util.abort()
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

-- validating all profiles
-- using a function just to have its name in the stack trace for when profiles are invalid
local function validate_profiles()
  for _, profile in ipairs(phobos_profiles.internal.all_profiles) do
    api_util.api_call(function()
      profile_util.validate_profile(profile)
    end, "Profile '"..tostring(profile.name).."': ") -- it's not validated yet, 'name' could be anything
  end
end
validate_profiles()

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

if args.list then
  print(get_list_of_all_profiles())
  return
end

for _, name in ipairs(args.profile_names) do
  local profile = phobos_profiles.internal.profiles_by_name[name]
  if not profile then
    print("No such profile '"..name.."'. "..get_list_of_all_profiles())
    util.abort()
  end
  profile.incremental = not args.rebuild
  profile_util.run_profile(profile, print)
end

print(string.format("total time elapsed: %.3fs", os.clock()))
