
local very_start_time = os.clock()

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

local args = arg_parser.parse_and_print_on_error_or_help({...}, {
  options = {
    {
      field = "working_directory",
      long = "working-dir",
      short = "w",
      description = "Path all other relative paths will be relative to;\n\z
                     Except '--ignore' and '--copy' which are relative\n\z
                     to '--source'.",
      single_param = true,
      type = "path",
      default_value = Path.new(assert(lfs.currentdir())),
    },
    {
      field = "source_path",
      long = "source",
      short = "s",
      description = "Source directory path. All phobos source files in\n\z
                     this directory and its sub directories will be\n\z
                     compiled to the '--output' directory.\n\z
                     Root for '--ignore' and '--copy'.",
      single_param = true,
      type = "path",
    },
    {
      field = "temp_path",
      long = "temp",
      short = "t",
      description = "Directory path to put temporary files in.\n\z
                     (currently unused, but you may want to configure\n\z
                     it for the future. The temp directory should be\n\z
                     unique for each project and each build profile.)",
      single_param = true,
      type = "path",
      default_value = Path.new("pho-temp"),
    },
    {
      field = "output_path",
      long = "output",
      short = "o",
      description = "Target directory path to put generated files into.\n\z
                     Defaults to '--source'. If not equal to '--source'\n\z
                     files with '--lua-extension' in the output dir\n\z
                     will be deleted.",
      single_param = true,
      type = "path",
      optional = true,
    },
    {
      field = "ignore_paths",
      long = "ignore",
      short = "i",
      description = "Paths to ignore (files and or directories\n\z
                     regardless of trailing slashes).\n\z
                     Relative to '--source'.",
      min_params = 0,
      type = "path",
      optional = true,
    },
    {
      field = "copy_paths",
      long = "copy",
      short = "c",
      description = "Paths relative to '--source' to copy as-is to the\n\z
                     '--output' directory. Each path defines a file or\n\z
                     directory to include or ignore when copying.\n\z
                     The *last* entry in the list has highest priority.\n\z
                     By default nothing gets copied.\n\z
                     Syntax: '[!|=][%]<path>'\n\z
                     '%' ignored. allow starting paths with '!' or '='.\n\z
                     '!' specifies a path to ignore.\n\z
                     '=' specifies a path to rename files to. Relative\n\z
                     to '--output'. Only valid after a path\n\z
                     without '!' or '='.\n\z
                     If used for a directory all files in the directory\n\z
                     will keep the same name, but the directory they\n\z
                     are in will change.\n\z
                     For filenames this can change both which directory\n\z
                     they are in and what name and extension they have.",
      min_params = 0,
      type = "path",
      optional = true,
    },
    {
      field = "inject_paths",
      long = "inject",
      short = "j",
      description = "Filenames of files to run which modify the AST of\n\z
                     every compiled file. The extension of these files\n\z
                     is ignored; They will load as bytecode if they are\n\z
                     bytecode files, otherwise Phobos will compile them\n\z
                     just in time.\n\z
                     These files must return a function taking a single\n\z
                     argument, which will be the AST of whichever file\n\z
                     is currently being compiled.\n\z
                     If multiple are provided they will be run in the\n\z
                     order they are defined in.\n\z
                     These files will be run before any optimizations.\n\z
                     These files may require any Phobos file, such as\n\z
                     the 'ast_walker' for example.\n\z
                     (NOTE: This feature is far from complete.)",
      min_params = 0,
      type = "path",
      optional = true,
    },
    {
      field = "profile",
      long = "profile",
      short = "p",
      description = "Which profile to use.\n\z
                     'debug': No optimizations, no tailcalls.\n\z
                     'release': All optimizations.\n\z
                     (NOTE: Very WIP, most likely going to change)",
      single_param = true,
      default_value = "release",
      type = build_profile_arg_provider.build_profile_type_id,
    },
    {
      field = "use_load",
      long = "use-load",
      description = "Use 'load()' to load the bytecode in the generated\n\z
                     files instead of generating raw bytecode files.",
      flag = true,
    },
    {
      field = "pho_extension",
      long = "pho-extension",
      description = "The file extension of Phobos files.",
      single_param = true,
      type = "string",
      default_value = ".pho",
    },
    {
      field = "lua_extension",
      long = "lua-extension",
      description = "The file extension of lua files.",
      single_param = true,
      type = "string",
      default_value = ".lua",
    },
    {
      field = "source_name",
      long = "source-name",
      description = "A 'pattern' to use for the 'source' name of the\n\z
                     generated bytecode. '?' is a placeholder for the\n\z
                     relative file name (with '/' as separators and\n\z
                     including the source extension\n\z
                     relative to '--source').",
      single_param = true,
      type = "string",
      default_value = "@?",
    },
    {
      field = "ignore_syntax_errors",
      long = "ignore-syntax-errors",
      description = "Continue and ignore a file after encountering a\n\z
                     syntax error and print it to std out.",
      flag = true,
    },
    {
      field = "no_syntax_error_messages",
      long = "no-syntax-error-messages",
      description = "Used if '--ignore-syntax-errors' is set. Stops\n\z
                     printing syntax error messages to std out.",
      flag = true,
    },
    {
      field = "verbose",
      long = "verbose",
      short = "v",
      description = "Print more information to std out.",
      flag = true,
    },
    {
      field = "no_warnings",
      long = "no-warn",
      description = "Suppress warnings.",
      flag = true,
    },
    {
      field = "monitor_memory_allocation",
      long = "monitor-memory",
      description = "Monitors total memory allocated during the entire\n\z
                     compilation process at the cost of ~10% longer\n\z
                     compilation times. (Stops incremental GC. Instead\n\z
                     runs full garbage collection whenever it exceeds\n\z
                     4GB current memory usage. May overshoot by quite\n\z
                     a bit.)",
      flag = true,
    },
  },
}, {label_length = 80 - 4 - 2 - 50})
if not args then return end

if args.monitor_memory_allocation then
  collectgarbage("stop")
end

local working_dir = args.working_directory
local source_dir = args.source_path:to_fully_qualified(working_dir):normalize()
local output_dir = args.output_path
  and args.output_path:to_fully_qualified(working_dir):normalize()
  or source_dir
local temp_dir = args.temp_path:to_fully_qualified(working_dir):normalize()
local injection_files = {}
for i, inject_path in ipairs(args.inject_paths) do
  injection_files[i] = inject_path:to_fully_qualified(working_dir):normalize()
end

if source_dir:attr("mode") ~= "directory" then
  error("`--source` path does not exist or is not a directory ("..source_dir:str()..")")
end

if not output_dir:exists() then
  io_util.mkdir_recursive(output_dir)
end

-- if the output will be generated in place there
-- is no auto cleanup of output files
--
-- if there is a target directory it will automatically delete any
-- lua_extension files it did not just generate at the end of compilation
-- (maybe add a flag to disable this but that should be hardly needed)
if source_dir == output_dir and args.pho_extension == args.lua_extension then
  error("when generating output next to source files the \z
    lua and Phobos file extensions cannot be the same."
  )
end

local source_files = {}
local source_file_lut = {}
local ignore_path_lut = {
  [temp_dir:str()] = true,
}
if output_dir ~= source_dir then
  ignore_path_lut[output_dir:str()] = true
end

for _, ignore_path in ipairs(args.ignore_paths) do
  ignore_path_lut[ignore_path:to_fully_qualified(source_dir):normalize():str()] = true
end

local function warn_for_unhandled_entry(mode, entry_path)
  if not args.no_warnings then
    if mode then
      print("WARN: unhandled entry mode '"..mode.."' for '"..entry_path:str().."'")
    else
      print("WARN: skipping entry with unsupported characters '"..entry_path:str().."'")
    end
  end
end

-- create copy paths lookup tables

--- fully qualified in source dir => fully qualified in output dir
local source_copy_path_to_renamed_mapping = {}
local ignore_copy_path_lut = {}

do
  local prev_not_modified_source_copy_path = nil
  for _, path in ipairs(args.copy_paths) do
    if path:is_absolute() then
      error("all paths in '--copy' must be relative paths. invalid absolute path '"..path:str().."'")
    end
    local first_entry = path.entries[1]
    if not first_entry then
      -- this should only be possible if it's an absolute path without any entries
      -- but because paths are weird here's a check for it anyway
      error("invalid '--copy' path '"..path:str().."'")
    end

    local function without_special_chars(special_path)
      local new_first_entry = first_entry:gsub("^[=!]?%%?", "")
      if new_first_entry == "" then
        error("Invalid '--copy' path with just special characters in first entry '"..special_path:str().."'")
      end
      return Path.combine(new_first_entry, special_path:sub(2))
    end
    local function get_str_when_rooted_at(root_dir)
      return without_special_chars(path):to_fully_qualified(root_dir):normalize():str()
    end

    if first_entry:find("^!") then
      ignore_copy_path_lut[get_str_when_rooted_at(source_dir)] = true
      prev_not_modified_source_copy_path = nil
    elseif first_entry:find("^=") then
      if not prev_not_modified_source_copy_path then
        error("rename paths in '--copy' are only valid immediately after a path \z
          without the '!' or '=' modifiers. invalid location for path '"..path:str().."'"
        )
      end
      source_copy_path_to_renamed_mapping[prev_not_modified_source_copy_path]
        = get_str_when_rooted_at(output_dir)
      prev_not_modified_source_copy_path = nil
    else
      prev_not_modified_source_copy_path = get_str_when_rooted_at(source_dir)
      source_copy_path_to_renamed_mapping[prev_not_modified_source_copy_path]
        = get_str_when_rooted_at(output_dir)
    end
  end
end

-- search for source files

-- TODO: use mappings created from --copy to find files to copy and figure out where to

do
  local visited_file_count = 0
  local function search_dir(dir)
    if ignore_path_lut[dir:str()] then
      return
    end

    for entry in lfs.dir(dir:str()) do
      if entry == "." or entry == ".." then
        goto continue
      end

      local entry_path = dir / entry
      local mode = entry_path:attr("mode")
      if mode == "directory" then
        search_dir(entry_path)
      elseif mode == "file" then
        visited_file_count = visited_file_count + 1
        if (not ignore_path_lut[entry_path:str()])
          and entry_path:extension() == args.pho_extension
        then
          source_files[#source_files+1] = entry_path
          source_file_lut[entry_path:sub(#source_dir + 1):str()] = true
        end
      else
        warn_for_unhandled_entry(mode, entry_path)
      end

      ::continue::
    end
  end

  search_dir(source_dir)

  if args.verbose then
    print("visited "..visited_file_count.." files in source dir")
  end
end

-- delete files from output

if output_dir ~= source_dir then
  local visited_file_count = 0

  local function process_dir(dir)
    local remaining_count = 0
    local did_delete = false

    for entry in lfs.dir(dir:str()) do
      if entry == "." or entry == ".." then
        goto continue
      end

      remaining_count = remaining_count + 1
      local entry_path = dir / entry
      local mode = entry_path:attr("mode")
      if mode == "directory" then
        if process_dir(entry_path) then
          remaining_count = remaining_count - 1
          did_delete = true
        end
      elseif mode == "file" then
        visited_file_count = visited_file_count + 1
        if entry_path:extension() == args.lua_extension then
          local respective_source_file = entry_path:sub(#output_dir + 1, -2)
            / (entry_path:filename()..args.pho_extension)
          if not source_file_lut[respective_source_file:str()] then
            remaining_count = remaining_count - 1
            did_delete = true
            if args.verbose then
              print("deleting file '"..entry_path:str().."'")
            end
            os.remove(entry_path:str())
          end
        end
      else
        warn_for_unhandled_entry(mode, entry_path)
      end

      ::continue::
    end

    if did_delete and remaining_count == 0 then
      if args.verbose then
        print("deleting dir '"..dir:str().."'")
      end
      lfs.rmdir(dir:str())
      return true
    end
  end

  process_dir(output_dir)

  if args.verbose then
    print("visited "..visited_file_count.." files in output dir")
  end
end

-- compile

local parser = require("parser")
local jump_linker = require("jump_linker")
local fold_const = require("optimize.fold_const")
local fold_control_statements = require("optimize.fold_control_statements")
local compiler = require("compiler")
local dump = require("dump")

local syntax_error_count = 0
local do_optimize = args.profile == "release"
local function compile(filename, source_name, ignore_syntax_errors, accept_bytecode, inject_scripts)
  local file
  if accept_bytecode then
    file = assert(io.open(filename:str(), "rb"))
    if file:read(4) == constants.lua_signature_str then
      assert(file:seek("set"))
      local contents = file:read("*a")
      assert(file:close())
      return contents
    else
      assert(lfs.setmode(file, "text"))
      assert(file:seek("set"))
    end
  else
    file = assert(io.open(filename:str(), "r"))
  end
  local contents = file:read("*a")
  assert(file:close())
  local ast
  if ignore_syntax_errors then
    local success
    success, ast = pcall(parser, contents, source_name)
    if not success then
      syntax_error_count = syntax_error_count + 1
      if not args.no_syntax_error_messages then
        print(ast:gsub("^[^:]+:%d+: ", "").." in "..source_name)
      end
      return nil
    end
  else
    ast = parser(contents, source_name)
  end
  jump_linker(ast)
  if inject_scripts then
    for _, inject_script in ipairs(inject_scripts) do
      inject_script(ast)
    end
  end
  if do_optimize then
    fold_const(ast)
    fold_control_statements(ast)
  end
  local compiled = compiler(ast, do_optimize)
  local bytecode = dump(compiled)
  return bytecode
end

-- load or compile ast injection files

local inject_scripts
local success, err = true, nil
if injection_files[1] then
  if args.verbose then
    print("started compilation or loading of "..(#injection_files)
      .." AST injection script files at ~ "..(os.clock() - very_start_time).."s"
    )
  end

  inject_scripts = {}
  local current_filename
  success, err = xpcall(function()
    for i, filename in ipairs(injection_files) do
      current_filename = filename
      local bytecode = compile(filename, "@"..filename:str(), false, true, nil)
      local inject_script_main_chunk = assert(load(bytecode, nil, "b")) -- not sandboxed
      local injection_func = inject_script_main_chunk()
      if type(injection_func) ~= "function" then
        error("expected 'function' return value from AST inject script file '"..filename:str().."'")
      end
      inject_scripts[i] = injection_func
    end
  end, function(msg)
    return "Error when loading or compiling AST inject script file"
      ..(current_filename and (" '"..current_filename:str().."'") or "")
      ..":\n\n"
      ..debug.traceback(msg, 2)
  end)
end

-- compile source files

local start_time = os.clock()

local total_memory_allocated = 0
local compiled_file_count = 0

local current_source_file_index

if success then
  if args.verbose then
    print("started compilation of "..(#source_files).." files at ~ "..(start_time - very_start_time).."s")
  end

  success, err = xpcall(function()
    for i, source_file in ipairs(source_files) do
      current_source_file_index = i
      if args.monitor_memory_allocation then
        compiled_file_count = compiled_file_count + 1
        if (compiled_file_count % 8) == 0 then
          local c = collectgarbage("count")
          if c > 4 * 1000 * 1000 then
            collectgarbage("collect")
            total_memory_allocated = total_memory_allocated + (c - collectgarbage("count"))
          end
        end
      end

      local source_name = args.source_name:gsub("%?", source_file:sub(#source_dir + 1):str())
      local bytecode = compile(source_file, source_name, args.ignore_syntax_errors, false, inject_scripts)
      if not bytecode then
        goto continue
      end
      local output
      if args.use_load then
        output = string.format("local main_chunk=assert(load(%q,nil,'b'))\nreturn main_chunk(...)", bytecode)
      else
        output = bytecode
      end

      local output_file_dir = output_dir / source_file:sub(#source_dir + 1, -2)
      if not output_file_dir:exists() then
        io_util.mkdir_recursive(output_file_dir)
      end
      local output_file = output_file_dir / (source_file:filename()..args.lua_extension)

      file = assert(io.open(output_file:str(), args.use_load and "w" or "wb"))
      file:write(output)
      file:close()
      ::continue::
    end
  end, function(msg)
    return "Runtime error (Phobos itself or an AST inject script, see stack trace)"
      ..(
        current_source_file_index
          and (" when compiling file '"..source_files[current_source_file_index]:str().."'")
          or ""
      )
      ..":\n\n"
      ..debug.traceback(msg, 2)
  end)
end

if not success then
  print()
  print("aborting"
    ..(
      current_source_file_index
        and (" at "..current_source_file_index.."/"..(#source_files))
        or ""
    )
    .."..."
  )
end

if args.verbose and args.ignore_syntax_errors then
  print(syntax_error_count.." files with syntax errors")
end

if args.monitor_memory_allocation then
  total_memory_allocated = total_memory_allocated + collectgarbage("count")
  ---cSpell:ignore giga
  print("total memory allocated "..(total_memory_allocated / (1000 * 1000)).." giga bytes")
end

local end_time = os.clock()
if args.verbose then
  print("compilation took ~ "..(end_time - start_time).."s")
end
print("total time elapsed ~ "..(end_time - very_start_time).."s")

if not success then
  print()
  error(err)
end
