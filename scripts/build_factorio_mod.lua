
local arg_parser = require("lib.LuaArgParser.arg_parser")
local Path = require("lib.LuaPath.path")
Path.use_forward_slash_as_main_separator_on_windows()
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
        needed for the factorio debugger to resolve file paths.\n\z
        enable when debugging locally, disable when building for publish.",
      flag = true,
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

local output_dir = Path.combine("factorio", script_util.get_dir_name(args.profile), "phobos")

loadfile(assert(package.searchpath("main", package.path)))(table.unpack{
  "--source", "src",
  "--output", ("out" / output_dir):str(),
  "--temp", ("temp" / output_dir):str(),
  "--inject", "scripts/build_factorio_mod_ast_inject.pho",
  "--use-load",
  "--pho-extension", ".lua",
  "--source-name", "@__phobos__/"..(args.include_src and "src/" or "").."?",
  (function()
    local function ignore()
      return "--ignore", table.unpack(require("scripts.factorio_build_ignore_list"))
    end
    if args.verbose then
      return "--verbose", ignore()
    else
      return ignore()
    end
  end)(),
})

local io_util = require("io_util")
local function copy_from_root_to_output(filename)
  io_util.copy(filename, "out" / output_dir / filename)
end

copy_from_root_to_output("info.json")
copy_from_root_to_output("changelog.txt")
