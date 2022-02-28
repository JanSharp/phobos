
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
Path.use_forward_slash_as_main_separator_on_windows()
local arg_parser = require("lib.LuaArgParser.arg_parser")
arg_parser.register_type(Path.arg_parser_path_type_def)
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

for _, name in ipairs(args.profile_names) do
  local profile = profiles.profiles_by_name[name]
  if not profile then
    -- TODO: print list of profile names that were actually added
    error("No profile with the name '"..name.."' registered.")
  end
  print("running profile '"..name.."'")

  local output_root = Path.new(profile.output_dir):to_fully_qualified(profile.root_dir):normalize()

  local count = 0
  local next_index = 1
  -- consider these to be opposites of each other, linking back and forth
  ---it's not an array because it can have holes
  ---@type table<integer, table>
  local files = {}
  ---indexed by fully qualified source filenames
  ---@type table<string, integer>
  local files_lut = {}

  local inject_script_context = compile_util.new_context()
  ---indexed by fully qualified paths of inject scripts
  ---@type table<string, fun(ast:AstFunctionDef)>
  local compiled_inject_script_files = {}
  ---indexed by `inject_scripts` tables
  ---@type table<table, fun(ast:AstFunctionDef)[]>
  local compiled_inject_scripts_lut = {}

  ---get the compiled inject scripts while making sure not to compile the same file twice (ignoring symlinks)\
  ---also runs the main chunk of inject scripts to get the actual inject function
  local function get_inject_scripts(inject_scripts)
    if compiled_inject_scripts_lut[inject_scripts] then
      return compiled_inject_scripts_lut[inject_scripts]
    end
    local result = {}
    for i, filename in ipairs(inject_scripts) do
      local full_filename = Path.new(filename):to_fully_qualified(profile.root_dir):normalize():str()
      local compiled = compiled_inject_script_files[full_filename]
      if not compiled then
        -- print("compiling inject script "..full_filename)
        local main_chunk = assert(load(compile_util.compile({
          filename = full_filename,
          source_name = "@?",
          accept_bytecode = true,
        }, inject_script_context), nil, "b"))
        compiled = main_chunk()
        assert(type(compiled) == "function",
          "AST inject scripts must return a function. (script file: "..full_filename..")"
        )
        compiled_inject_script_files[full_filename] = compiled
      end
      result[i] = compiled
    end
    compiled_inject_scripts_lut[inject_scripts] = result
    return result
  end

  local function process_include(path_def)
    local root = Path.new(path_def.source_dir):to_fully_qualified(profile.root_dir):normalize()
    local output_path = Path.new(path_def.output_dir):normalize()
    if output_path:is_absolute() then
      error("'output_dir' has to be a relative path (output_dir: '"..path_def.output_dir.."')")
    end
    if output_path.entries[1] == ".." then
      error("Attempt to output files outside of the output directory. (output_dir: '"..path_def.output_dir.."')")
    end
    local function include_dir(path, depth)
      if depth > path_def.recursion_depth then return end
      for entry in lfs.dir((root / path):str()) do
        if entry == "." or entry == ".." then goto continue end
        local entry_path = root / path / entry
        local mode = entry_path:attr("mode")
        if mode == "directory" then
          include_dir(path / entry, depth + 1)
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
            local output_file = (output_root / output_path / path / output_entry):str()
            files[index] = {
              source_filename = str,
              relative_source_filename = (path / entry):str(),
              output_filename = output_file,
              source_name = path_def.source_name,
              use_load = path_def.use_load,
              inject_scripts = get_inject_scripts(path_def.inject_scripts),
            }
          end
        end
        ::continue::
      end
    end
    if not root:attr("mode") == "directory" then
      error("Including anything but directories is not supported. (source_dir: '"..root:str().."')")
    end
    include_dir(Path.new(), 1)
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
    local function exclude_dir(path, depth)
      if depth > path_def.recursion_depth then return end
      for entry in lfs.dir(path:str()) do
        if entry == "." or entry == ".." then goto continue end
        local entry_path = path / entry
        local mode = entry_path:attr("mode")
        if mode == "directory" then
          exclude_dir(entry_path, depth + 1)
        elseif mode == "file" then
          exclude_file(entry_path)
        end
        ::continue::
      end
    end
    local path = Path.new(path_def.path)
    local mode = path:attr("mode")
    if mode == "directory" then
      exclude_dir(path, 1)
    elseif mode == "file" then
      exclude_file(path)
    end
  end

  for _, fc_def in ipairs(profile.file_collection_defs) do
    if fc_def.type == "include" then
      process_include(fc_def)
    elseif fc_def.type == "exclude" then
      process_exclude(fc_def)
    else
      error("Impossible path definition type '"..(fc_def.type or "<nil>").."'.")
    end
  end

  local context = compile_util.new_context()
  local c = 0
  for i = 1, next_index - 1 do
    if files[i] then
      c = c + 1
      local file = files[i]
      local compile_this_file = not profile.incremental
      if not compile_this_file then
        if Path.new(file.output_filename):exists() then
          local source_modification = lfs.attributes(file.source_filename, "modification")
          local output_modification = lfs.attributes(file.output_filename, "modification")
          compile_this_file = os.difftime(source_modification, output_modification) > 0
        else
          -- output doesn't exist, so compile it
          compile_this_file = true
        end
      end
      if compile_this_file then
        print("["..c.."/"..count.."] "..file.source_filename)
        ---@type CompileUtilOptions
        local options = {
          source_name = file.source_name,
          filename = file.source_filename,
          filename_for_source = file.relative_source_filename,
          use_load = file.use_load,
          inject_scripts = file.inject_scripts,
          optimizations = profile.optimizations,

          ignore_syntax_errors = true,
          no_syntax_error_messages = true,
        }
        local result = compile_util.compile(options, context)
        if result then
          io_util.write_file(file.output_filename, result)
        end
      end
    end
  end
  print("finished profile '"..name.."'")
end

print(string.format("total time elapsed: %.3fs", os.clock()))
