
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
Path.use_forward_slash_as_main_separator_on_windows()
local arg_parser = require("lib.LuaArgParser.arg_parser")
arg_parser.register_type(Path.arg_parser_path_type_def)
local build_profile_arg_provider = require("build_profile_arg_provider")
arg_parser.register_type(build_profile_arg_provider.arg_parser_build_profile_type_def)
local io_util = require("io_util")
local constants = require("constants")
local error_code_util = require("error_code_util")
local compile_util = require("compile_util")

local parser = require("parser")
local jump_linker = require("jump_linker")
local fold_const = require("optimize.fold_const")
local fold_control_statements = require("optimize.fold_control_statements")
local compiler = require("compiler")
local dump = require("dump")

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
    }
  },
})
if not args then return end

local profiles = require("profile_util")
-- expose profile_util as a `profiles` global for the duration of running profiles scripts
_ENV.profiles = profiles

local profiles_context = compile_util.new_context()
for _, profiles_file in ipairs(args.profiles_files) do
  local main_chunk = assert(load(compile_util.compile({
    source_name = "@?",
    filename = profiles_file,
    accept_bytecode = true,
  }, profiles_context), nil, "b"))
  local profiles_file_path = Path.new(profiles_file)
  profiles.internal.current_root_dir = profiles_file_path:sub(1, -2):to_fully_qualified():str()
  -- not sandboxed at all
  main_chunk()
end

-- the global is no longer needed
_ENV.profiles = nil

-- local serpent = require("lib.serpent")
-- print(serpent.block(profiles.profiles))

for _, name in ipairs(args.profile_names) do
  local profile = profiles.profiles_by_name[name]
  if not profile then
    -- TODO: print list of profile names that were actually added
    error("No profile with the name '"..name.."' registered.")
  end

  local output_root = Path.new(profile.output_dir):to_fully_qualified(profile.root_dir):normalize()
  -- consider these to be opposites of each other, linking back and forth
  local count = 0
  local next_index = 1
  ---@type table<integer, table>
  local files = {}
  ---@type table<string, integer>
  local files_lut = {}

  local function process_include(path_def)
    local root = Path.new(path_def.source_dir):to_fully_qualified(profile.root_dir):normalize()
    local output_path = Path.new(path_def.output_dir):normalize()
    if output_path:is_absolute() then
      error("'output_dir' has to be a relative path (output_dir: '"..path_def.output_dir.."')")
    end
    if output_path.entries[1] == ".." then
      error("Attempt to output files outside of the output directory. (output_dir: '"..path_def.output_dir.."')")
    end
    local function include_dir(path)
      for entry in lfs.dir((root / path):str()) do
        if entry == "." or entry == ".." then goto continue end
        local entry_path = root / path / entry
        local mode = entry_path:attr("mode")
        if mode == "directory" then
          if path_def.recursive then
            include_dir(path / entry)
          end
        elseif mode == "file" then
          if entry_path:extension() == path_def.phobos_extension then
            local str = entry_path:str()
            local index = files_lut[str]
            if not index then
              index = next_index
              next_index = next_index + 1
              count = count + 1
              files_lut[str] = index
            end
            entry = Path.new(entry)
            local output_entry = entry:sub(1, -2) / (entry:filename()..path_def.lua_extension)
            local output_file = output_root / output_path / path / output_entry
            files[index] = {
              source_filename = str,
              output_filename = output_file,
              source_name = path_def.source_name,
              use_load = path_def.use_load,
              inject_scripts = path_def.inject_scripts,
            }
          end
        end
        ::continue::
      end
    end
    if not root:attr("mode") == "directory" then
      error("Including anything but directories is not supported. (Path: '"..root:str().."')")
    end
    include_dir(Path.new())
  end

  local function process_exclude(path_def)
    local function exclude_file(path)
      local index = files_lut[path:str()]
      if index then
        files_lut[path:str()] = nil
        files[index] = nil -- leaves hole
        count = count - 1
      end
    end
    local function exclude_dir(path)
      for entry in lfs.dir(path:str()) do
        if entry == "." or entry == ".." then goto continue end
        local entry_path = path / entry
        local mode = entry_path:attr("mode")
        if mode == "directory" then
          if path_def.recursive then
            exclude_dir(entry_path)
          end
        elseif mode == "file" then
          exclude_file(entry_path)
        end
        ::continue::
      end
    end
    local path = Path.new(path_def.path)
    local mode = path:attr("mode")
    if mode == "directory" then
      exclude_dir(path)
    elseif mode == "file" then
      exclude_file(path)
    end
  end

  for _, path_def in ipairs(profile.paths) do
    if path_def.type == "include" then
      process_include(path_def)
    elseif path_def.type == "exclude" then
      process_exclude(path_def)
    else
      error("Impossible path definition type '"..(path_def.type or "<nil>").."'.")
    end
  end

  -- print(serpent.block(files))

  local context = compile_util.new_context()
  for i = 1, next_index - 1 do
    if files[i] then
      local file = files[i]
      ---@type CompileUtilOptions
      local options = {
        source_name = file.source_name,
        filename = file.source_filename,
        use_load = file.use_load,
        -- inject_scripts = file.inject_scripts, -- TODO: compile inject scripts
        optimizations = profile.optimizations,
      }
      local result = compile_util.compile(options, context)
      io_util.write_file(file.output_filename, result)
    end
  end
end
