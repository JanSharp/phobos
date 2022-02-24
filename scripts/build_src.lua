
local arg_parser = require("lib.LuaArgParser.arg_parser")
local Path = require("lib.LuaPath.path")
Path.use_forward_slash_as_main_separator_on_windows()
local build_profile_arg_provider = require("build_profile_arg_provider")
arg_parser.register_type(Path.arg_parser_path_type_def)
arg_parser.register_type(build_profile_arg_provider.arg_parser_build_profile_type_def)

local args = arg_parser.parse_and_print_on_error_or_help({...}, {
  options = {
    {
      field = "profile",
      long = "profile",
      short = "p",
      description = "The build profile to use.",
      type = build_profile_arg_provider.build_profile_type_id,
      single_param = true,
    },
    {
      field = "verbose",
      long = "verbose",
      short = "v",
      flag = true,
    },
  },
})
if not args then return end

loadfile(assert(package.searchpath("main", package.path)))(table.unpack{
  "--source", "src",
  "--output", "out/src/"..args.profile,
  "--temp", "temp/src/"..args.profile,
  "--profile", args.profile,
  -- for now source files are still `.lua` files because they
  -- do compile with regular lua compilers and i do not trust
  -- Phobos enough yet
  -- this will probably change soon though
  "--pho-extension", ".lua",
  "--source-name", "@src/?",
  -- HACK: have to --use-load until https://github.com/tomblind/local-lua-debugger-vscode/issues/56 is implemented
  "--use-load",
  "--ignore",
  "control.lua",
  args.verbose and "--verbose" or nil,
})
