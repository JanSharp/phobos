
local arg_parser = require("lib.LuaArgParser.arg_parser")
local Path = require("lib.LuaPath.path")
local script_util = require("scripts.util")
arg_parser.register_type(Path.arg_parser_path_type_def)
arg_parser.register_type(script_util.arg_parser_build_profile_type_def)

local args = arg_parser.parse_and_print_on_error_or_help({...}, {
  options = {
    {
      field = "profile",
      long = "profile",
      short = "p",
      description = "The build profile to use.",
      type = script_util.build_profile_type_id,
      single_param = true,
    },
    {
      field = "include_src",
      long = "include-src-in-source-name",
      short = "s",
      description = "include the `src` sub dir in source_name?\n\z
        needed for the local lua debugger to resolve file paths.\n\z
        enable when debugging locally, disable when building for publish.",
      flag = true,
    },
  },
})
if not args then return end

loadfile(assert(__source_dir).."/main.lua")(table.unpack{
  "--source", "src",
  "--output", "../out/"..script_util.get_dir_name(args.profile),
  -- for now source files are still `.lua` files because they
  -- do compile with regular lua compilers and i do not trust
  -- phobos enough yet
  -- this will probably change soon though
  "--pho-extension", ".lua",
  "--source-name", (args.include_src and "src/" or "").."?",
  "--ignore",
  "control.lua",
})
