
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
Path.use_forward_slash_as_main_separator_on_windows()
local io_util = require("io_util")
local compile_util = require("compile_util")

-- TODO: validate input

---`root_dir` does not have an explicit default when using this function.\
---Technically it will be using the current working directory if it's `nil` because of `Path.to_fully_qualified`.
---@param params NewProfileParams
local function new_profile(params)
  local profile = {
    name = params.name,
    output_dir = params.output_dir,
    temp_dir = params.temp_dir,
    phobos_extension = params.phobos_extension or ".pho",
    lua_extension = params.lua_extension or ".lua",
    use_load = params.use_load or false,
    incremental = params.incremental == nil and true or params.incremental,
    inject_scripts = params.inject_scripts or {},
    optimizations = params.optimizations or {},
    error_message_count = params.error_message_count or 8,
    measure_memory = params.measure_memory or false,
    root_dir = params.root_dir,
    include_exclude_definitions = {},
    include_exclude_copy_definitions = {},
  }
  return profile
end

---@param params IncludeParams
local function include(params)
  params.profile.include_exclude_definitions[#params.profile.include_exclude_definitions+1] = {
    type = "include",
    source_dir = params.source_dir,
    output_dir = params.output_dir,
    recursion_depth = params.recursion_depth or (1/0),
    filename_pattern = params.filename_pattern or "",
    source_name = params.source_name,
    phobos_extension = params.phobos_extension or params.profile.phobos_extension,
    lua_extension = params.lua_extension or params.profile.lua_extension,
    use_load = params.use_load or params.profile.use_load,
    error_message_count = params.error_message_count or params.profile.error_message_count,
    inject_scripts = params.inject_scripts or params.profile.inject_scripts,
  }
end

---@param params ExcludeParams
local function exclude(params)
  params.profile.include_exclude_definitions[#params.profile.include_exclude_definitions+1] = {
    type = "exclude",
    source_path = params.source_path,
    recursion_depth = params.recursion_depth or (1/0),
    filename_pattern = params.filename_pattern or "",
  }
end

---@param params IncludeCopyParams
local function include_copy(params)
  params.profile.include_exclude_copy_definitions[#params.profile.include_exclude_copy_definitions+1] = {
    type = "include",
    source_path = params.source_path,
    output_path = params.output_path,
  }
end

---@param params ExcludeCopyParams
local function exclude_copy(params)
  params.profile.include_exclude_copy_definitions[#params.profile.include_exclude_copy_definitions+1] = {
    type = "include",
    source_path = params.source_path,
    output_path = params.output_path,
  }
end

---get a new table with all optimizations set to `true`
---@return Optimizations
local function get_all_optimizations()
  return {
    fold_const = true,
    fold_control_statements = true,
    tail_calls = true,
  }
end

local function new_inject_script_cache(root_dir)
  return {
    compile_util_context = compile_util.new_context(),
    ---indexed by fully qualified paths of inject scripts
    ---@type table<string, fun(ast:AstFunctionDef)>
    compiled_inject_script_files = {},
    ---indexed by `inject_scripts` tables
    ---@type table<table, fun(ast:AstFunctionDef)[]>
    compiled_inject_scripts_lut = {},
    ---the root dir of the current profile
    root_dir = root_dir,
  }
end

---get the compiled inject scripts while making sure not to compile the same file twice (ignoring symlinks)\
---also runs the main chunk of inject scripts to get the actual inject function
local function get_inject_scripts(inject_scripts, cache)
  if cache.compiled_inject_scripts_lut[inject_scripts] then
    return cache.compiled_inject_scripts_lut[inject_scripts]
  end
  local result = {}
  for i, filename in ipairs(inject_scripts) do
    local full_filename = Path.new(filename):to_fully_qualified(cache.root_dir):normalize():str()
    local compiled = cache.compiled_inject_script_files[full_filename]
    if not compiled then
      -- print("compiling inject script "..full_filename)
      local main_chunk = assert(load(compile_util.compile({
        filename = full_filename,
        source_name = "@?",
        accept_bytecode = true,
      }, cache.inject_script_context), nil, "b"))
      compiled = main_chunk()
      assert(type(compiled) == "function",
        "AST inject scripts must return a function. (script file: "..full_filename..")"
      )
      cache.compiled_inject_script_files[full_filename] = compiled
    end
    result[i] = compiled
  end
  cache.compiled_inject_scripts_lut[inject_scripts] = result
  return result
end

local function new_file_collection(output_root, root_dir)
  return {
    output_root = output_root,
    count = 0,
    next_index = 1,
    -- consider these to be opposites of each other, linking back and forth
    ---it's not an array because it can have holes
    ---@type table<integer, table>
    files = {},
    ---indexed by fully qualified source filenames
    ---@type table<string, integer>
    files_lut = {},
    root_dir = root_dir,
  }
end

local function process_include(include_def, collection)
  local root = Path.new(include_def.source_dir):to_fully_qualified(collection.root_dir):normalize()
  local output_path = Path.new(include_def.output_dir):normalize()
  if output_path:is_absolute() then
    error("'output_dir' has to be a relative path (output_dir: '"..include_def.output_dir.."')")
  end
  if output_path.entries[1] == ".." then
    error("Attempt to output files outside of the output directory. \z
      (output_dir: '"..include_def.output_dir.."')"
    )
  end
  local function include_dir(path, depth)
    if depth > include_def.recursion_depth then return end
    for entry in lfs.dir((root / path):str()) do
      if entry == "." or entry == ".." then goto continue end
      local entry_path = root / path / entry
      local mode = assert(entry_path:attr("mode"))
      if mode == "directory" then
        include_dir(path / entry, depth + 1)
      elseif mode == "file" then
        local included = entry_path:extension() == include_def.phobos_extension
        -- "" matches everything, don't waste time processing all of this
        if include_def.filename_pattern ~= "" and included then
          included = ("/"..(path / entry):str()):find(include_def.filename_pattern)
        end
        if included then
          local str = entry_path:str()
          local index = collection.files_lut[str]
          if not index then
            index = collection.next_index
            collection.next_index = collection.next_index + 1
            collection.count = collection.count + 1
            collection.files_lut[str] = index
          end
          entry = Path.new(entry)
          local output_entry = entry:sub(1, -2) / (entry:filename()..include_def.lua_extension)
          local output_file = (collection.output_root / output_path / path / output_entry):str()
          collection.files[index] = {
            source_filename = str,
            relative_source_filename = (path / entry):str(),
            output_filename = output_file,
            source_name = include_def.source_name,
            use_load = include_def.use_load,
            error_message_count = include_def.error_message_count,
            inject_scripts = include_def.inject_scripts,
          }
        end
      end
      ::continue::
    end
  end
  if not assert(root:attr("mode")) == "directory" then
    error("Including anything but directories is not supported. (source_dir: '"..root:str().."')")
  end
  include_dir(Path.new(), 1)
end

local function process_exclude(path_def, collection)
  local root = Path.new(path_def.source_path):to_fully_qualified(collection.root_dir):normalize()
  local function exclude_file(path)
    local index = collection.files_lut[path:str()]
    if index then
      collection.files_lut[path:str()] = nil
      collection.files[index] = nil -- leaves hole
      collection.count = collection.count - 1
    end
  end
  local function exclude_dir(path, depth)
    if depth > path_def.recursion_depth then return end
    for entry in lfs.dir((root / path):str()) do
      if entry == "." or entry == ".." then goto continue end
      local entry_path = path / entry
      local mode = assert((root / entry_path):attr("mode"))
      if mode == "directory" then
        exclude_dir(entry_path, depth + 1)
      elseif mode == "file" then
        if path_def.filename_pattern == ""
          or ("/"..entry_path:str()):find(path_def.filename_pattern)
        then
          exclude_file(root / entry_path)
        end
      end
      ::continue::
    end
  end
  local mode = assert(root:attr("mode"))
  if mode == "directory" then
    exclude_dir(Path.new(), 1)
  elseif mode == "file" then
    exclude_file(root)
  end
end

local function should_compile(file, incremental)
  if not incremental then
    return true
  end
  if Path.new(file.output_filename):exists() then
    local source_modification = lfs.attributes(file.source_filename, "modification")
    local output_modification = lfs.attributes(file.output_filename, "modification")
    return os.difftime(source_modification, output_modification) > 0
  else
    -- output doesn't exist, so compile it
    return true
  end
end

local function run_profile(profile, print)
  print = print or function() end
  print("running profile '"..profile.name.."'")

  local total_memory_allocated = 0
  if profile.measure_memory then
    collectgarbage("stop")
    total_memory_allocated = -collectgarbage("count")
  end

  local output_root = Path.new(profile.output_dir):to_fully_qualified(profile.root_dir):normalize()
  local compilation_file_collection = new_file_collection(output_root, profile.root_dir)

  for _, include_or_exclude_def in ipairs(profile.include_exclude_definitions) do
    if include_or_exclude_def.type == "include" then
      process_include(include_or_exclude_def, compilation_file_collection)
    elseif include_or_exclude_def.type == "exclude" then
      process_exclude(include_or_exclude_def, compilation_file_collection)
    else
      error("Impossible path definition type '"..(include_or_exclude_def.type or "<nil>").."'.")
    end
  end

  print("compiling "..compilation_file_collection.count.." files")

  local inject_script_cache = new_inject_script_cache()
  local context = compile_util.new_context()
  local c = 0
  for i = 1, compilation_file_collection.next_index - 1 do
    if compilation_file_collection.files[i] then
      if profile.measure_memory then
        local prev_gc_count = collectgarbage("count")
        if prev_gc_count > 4 * 1000 * 1000 then
          collectgarbage("collect")
          total_memory_allocated = total_memory_allocated + (prev_gc_count - collectgarbage("count"))
        end
      end

      c = c + 1
      local file = compilation_file_collection.files[i]
      if should_compile(file, profile.incremental) then
        print("["..c.."/"..compilation_file_collection.count.."] "..file.source_filename)
        local result = compile_util.compile({
          source_name = file.source_name,
          filename = file.source_filename,
          filename_for_source = file.relative_source_filename,
          use_load = file.use_load,
          inject_scripts = get_inject_scripts(file.inject_scripts, inject_script_cache),
          optimizations = profile.optimizations,
          error_message_count = file.error_message_count,
        }, context)
        if result then
          io_util.write_file(file.output_filename, result)
        end
      end
    end
  end

  if profile.measure_memory then
    total_memory_allocated = total_memory_allocated + collectgarbage("count")
    ---cSpell:ignore giga
    print("total memory allocated "..(total_memory_allocated / (1000 * 1000)).." giga bytes")
    collectgarbage("restart")
  end
  print("finished profile '"..profile.name.."'")
end

return {
  new_profile = new_profile,
  include = include,
  exclude = exclude,
  include_copy = include_copy,
  exclude_copy = exclude_copy,
  get_all_optimizations = get_all_optimizations,
  run_profile = run_profile,
}
