
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
local arg_parser = require("lib.LuaArgParser.arg_parser")
arg_parser.register_type(Path.arg_parser_path_type_def)

local args_config = {
  options = {
    {
      field = "source_path",
      long = "source",
      short = "s",
      description = "Source directory path.",
      single_param = true,
      type = "path",
    },
    {
      field = "temp_path",
      long = "temp",
      short = "t",
      description = "Directory path to put temporary files in. Relative to source dir.",
      single_param = true,
      type = "path",
      default_value = Path.new("pho-temp"),
    },
    {
      field = "output_path",
      long = "output",
      short = "o",
      description = "Target directory path to put generated files into. Relative to source dir.",
      single_param = true,
      type = "path",
      optional = true,
    },
    {
      field = "ignore_paths",
      long = "ignore",
      short = "i",
      description = "Directories to ignore. Relative to source dir.",
      min_params = 0,
      type = "path",
      optional = true,
    },
    {
      field = "use_load",
      long = "use-load",
      description = "Use `load()` to load the bytecode in the generated \z
        files instead of generating raw bytecode files",
      flag = true,
    },
    {
      field = "pho_extension",
      long = "pho-extension",
      description = "The file extension of phobos files.",
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
  },
  positional = {},
}

local args = arg_parser.parse({...}, args_config)

local function exists_and_is_dir(path)
  if path:attr("mode") ~= "directory" then
    error("The given path '"..path:str().." does not exist.")
  end
end

exists_and_is_dir(args.source_path)
local clean_up_output_dir = true
if args.output_path then
  clean_up_output_dir = false
elseif args.pho_extension == args.lua_extension then
  error("When generating output next to source files the \z
    lua and phobos file extensions cannot be equal.")
end

-- if there is no target directory the output will be generated in place
-- in this case there is no auto cleanup of output files

-- if there is a target directory it will automatically delete any
-- lua_extension files it did not just generate at the end of compilation
-- (maybe add a flag to disable this but that should be hardly needed)

---relative
local source_file_paths = {}
---relative
local dir_paths = {}

---relative
local filename_lut = {}

local ignore_dirs = {
  [args.temp_path:str()] = true,
}
if args.output_path then
  ignore_dirs[args.output_path:str()] = true
end

for _, ignore_dir_path in ipairs(args.ignore_paths) do
  ignore_dirs[ignore_dir_path:str()] = true
end

-- search for source files

local function search_dir(dir, relative_dir)
  relative_dir = relative_dir or Path.new()
  if ignore_dirs[relative_dir:str()] then
    return
  end
  dir_paths[#dir_paths+1] = relative_dir

  for entry in lfs.dir(dir:str()) do
    if entry == "." or entry == ".." then
      goto continue
    end

    local entry_path = dir / entry
    local mode = entry_path:attr("mode")
    if mode == "directory" then
      search_dir(entry_path, relative_dir / entry)
    elseif mode == "file" then
      if entry_path:extension() == args.pho_extension then
        source_file_paths[#source_file_paths+1] = relative_dir / entry
        filename_lut[(relative_dir / entry_path:filename()):str()] = true
      end
    end

    ::continue::
  end
end

search_dir(args.source_path)

-- delete files from output

local output_path = Path.combine(args.source_path, args.output_path)

-- TODO: also look into dirs not found in source [...]
-- and delete those if they end up being empty
-- after deleting lua files

if args.output_path then
  for _, relative_dir_path in ipairs(dir_paths) do
    local output_dir_path = output_path / relative_dir_path
    if output_dir_path:exists() then
      for entry in lfs.dir(output_dir_path:str()) do
        if entry == "." or entry == ".." then
          goto continue
        end

        local entry_path = output_dir_path / entry
        if entry_path:attr("mode") == "file"
          and (not filename_lut[(relative_dir_path / entry_path:filename()):str()])
        then
          print("Deleting '"..entry_path:str().."'.")
          os.remove(entry_path:str())
        end

        ::continue::
      end
    end
  end
end

-- compile

local parser = require("parser")
local jump_linker = require("jump_linker")
local fold_const = require("optimize.fold_const")
local phobos = require("phobos")
local dump = require("dump")

for _, source_file_path in ipairs(source_file_paths) do
  local file = assert(io.open((args.source_path / source_file_path):str(), "r"))
  local text = file:read("*a")
  file:close()

  local ast = parser(text, "@"..source_file_path:str())
  jump_linker(ast)
  fold_const(ast)
  phobos(ast)
  local bytecode = dump(ast)
  local output
  if args.use_load then
    output = string.format("local main_chunk=assert(load(%q,nil,'b'))\nreturn main_chunk(...)", bytecode)
  else
    output = bytecode
  end

  local output_file_path = output_path / source_file_path
  local dir = output_file_path:sub(1, -2)
  output_file_path = dir / (output_file_path:filename()..args.lua_extension)
  if not dir:exists() then
    for i = 1, #dir do
      if not dir:sub(1, i):exists() then
        assert(lfs.mkdir(dir:sub(1, i):str()))
      end
    end
  end

  file = assert(io.open(output_file_path:str(), args.use_load and "w" or "wb"))
  file:write(output)
  file:close()
end
