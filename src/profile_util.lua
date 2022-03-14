
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
Path.set_main_separator("/")
local util = require("util")
local io_util = require("io_util")
local compile_util = require("compile_util")
local cache = require("cache")

local action_enum = {
  compile = 0,
  copy = 1,
}
local action_name_lut = {
  [0] = "compile",
  [1] = "copy",
}

-- TODO: validate input
-- TODO: cache the phobos version of used for the previous build and compare that when determining incremental

---@class NewProfileInternalParams : NewProfileParams
---**default:** `true`\
---Should only files with a newer modification time get compiled or copied?
---@field incremental boolean

---@class PhobosProfileInternal : PhobosProfile
---**default:** `true`\
---Should only files with a newer modification time get compiled or copied?
---@field incremental boolean

---`root_dir` does not have an explicit default when using this function.\
---Technically it will be using the current working directory if it's `nil` because of `Path.to_fully_qualified`.
---@param params NewProfileInternalParams
local function new_profile(params)
  local profile = {
    name = params.name,
    output_dir = params.output_dir,
    cache_dir = params.cache_dir,
    phobos_extension = params.phobos_extension or ".pho",
    lua_extension = params.lua_extension or ".lua",
    use_load = params.use_load or false,
    incremental = params.incremental == nil and true or params.incremental,
    inject_scripts = params.inject_scripts or {},
    optimizations = params.optimizations or {},
    error_message_count = params.error_message_count or 8,
    measure_memory = params.measure_memory or false,
    root_dir = params.root_dir,
    on_pre_profile_ran = params.on_pre_profile_ran,
    on_post_profile_ran = params.on_post_profile_ran,
    include_exclude_definitions = {},
    include_exclude_copy_definitions = {},
  }
  return profile
end

---@param params IncludeParams
local function include(params)
  params.profile.include_exclude_definitions[#params.profile.include_exclude_definitions+1] = {
    type = "include",
    source_path = params.source_path,
    output_path = params.output_path,
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
    recursion_depth = params.recursion_depth or (1/0),
    filename_pattern = params.filename_pattern or "",
  }
end

---@param params ExcludeCopyParams
local function exclude_copy(params)
  params.profile.include_exclude_copy_definitions[#params.profile.include_exclude_copy_definitions+1] = {
    type = "include",
    source_path = params.source_path,
    recursion_depth = params.recursion_depth or (1/0),
    filename_pattern = params.filename_pattern or "",
    pop = params.pop,
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
local function get_inject_scripts(inject_scripts, script_cache)
  if script_cache.compiled_inject_scripts_lut[inject_scripts] then
    return script_cache.compiled_inject_scripts_lut[inject_scripts]
  end
  local result = {}
  for i, filename in ipairs(inject_scripts) do
    local full_filename = Path.new(filename):to_fully_qualified(script_cache.root_dir):normalize():str()
    local compiled = script_cache.compiled_inject_script_files[full_filename]
    if not compiled then
      -- print("compiling inject script "..full_filename)
      local main_chunk = assert(load(compile_util.compile({
        filename = full_filename,
        source_name = "@?",
        accept_bytecode = true,
      }, script_cache.inject_script_context), nil, "b"))
      compiled = main_chunk()
      assert(type(compiled) == "function",
        "AST inject scripts must return a function. (script file: "..full_filename..")"
      )
      script_cache.compiled_inject_script_files[full_filename] = compiled
    end
    result[i] = compiled
  end
  script_cache.compiled_inject_scripts_lut[inject_scripts] = result
  return result
end

local function new_file_collection(output_root, root_dir, is_compilation_collection)
  return {
    ---fully qualified and normalized
    output_root = output_root,
    count = 0,
    next_index = 1,
    -- consider these to be opposites of each other, linking back and forth
    ---it's not an array because it can have holes
    ---@type table<integer, table|table[]>
    files = {},
    ---indexed by fully qualified source filenames
    ---@type table<string, integer>
    files_lut = {},
    root_dir = root_dir,
    is_compilation_collection = is_compilation_collection,
  }
end

local function replace_extension(path, extension)
  return path:sub(1, -2) / (path:filename()..extension)
end

local function process_include(include_def, collection)
  local is_compilation_collection = collection.is_compilation_collection
  local root = Path.new(include_def.source_path):to_fully_qualified(collection.root_dir):normalize()
  local relative_output_path = Path.new(include_def.output_path):normalize()
  if relative_output_path:is_absolute() then
    util.abort("'output_path' has to be a relative path (output_path: '"..include_def.output_path.."')")
  end
  if relative_output_path.entries[1] == ".." then
    util.abort("Attempt to output files outside of the output directory. \z
      (output_path: '"..include_def.output_path.."', normalized: '"..relative_output_path:str().."')"
    )
  end
  local source_root = root
  local output_root = collection.output_root / relative_output_path

  local include_entry

  local function include_file(relative_entry_path)
    local source_filename = (root / relative_entry_path):str()
    local index = collection.files_lut[source_filename]
    if not is_compilation_collection or not index then
      -- Only increment count if this is not overwriting an already included file.
      -- It is overwriting if it is a compilation collection and the source file was already added
      -- the other case is handled near the end of the function
      collection.count = collection.count + 1
    end
    if not index then -- doesn't exist yet, so it's not overwriting but defining a new file
      index = collection.next_index
      collection.next_index = collection.next_index + 1
      collection.files_lut[source_filename] = index
      if not is_compilation_collection then
        collection.files[index] = {} -- new array
      end
    end
    local relative_output_entry_path = is_compilation_collection
      and replace_extension(relative_entry_path, include_def.lua_extension)
      or relative_entry_path
    if is_compilation_collection
      and not relative_output_entry_path.entries[1]
      and include_def.source_name:find("?", 1, true)
    then
      util.abort("When including a single file for compilation the 'source_name' must not contain '?'. \z
        It must instead define the entire source_name - it is not a pattern. \z
        (source_path: '"..include_def.source_path.."', source_name: '"..include_def.source_name.."')"
      )
    end
    if is_compilation_collection then
      -- not an array of files because compilation collections disallow compiling the same file twice anyway
      collection.files[index] = {
        source_filename = source_filename,
        relative_source_filename = relative_entry_path:str(),
        output_filename = (output_root / relative_output_entry_path):str(),
        source_name = include_def.source_name,
        use_load = include_def.use_load,
        error_message_count = include_def.error_message_count,
        inject_scripts = include_def.inject_scripts,
      }
    else
      local files = collection.files[index]
      local output_filename = (output_root / relative_output_entry_path):str()
      -- if the source an output filename combination already then exists just ignore this one
      for _, file in ipairs(files) do
        if file.source_filename == source_filename and file.output_filename == output_filename then
          collection.count = collection.count - 1
          goto ignore
        end
      end
      files[#files+1] = {
        source_filename = source_filename,
        output_filename = output_filename,
      }
      ::ignore::
    end
  end

  local function include_dir(relative_entry_path, depth)
    if depth > include_def.recursion_depth then return end
    for entry in lfs.dir((source_root / relative_entry_path):str()) do
      if entry ~= "." and entry ~= ".." then
        include_entry(relative_entry_path / entry, depth)
      end
    end
  end

  function include_entry(relative_entry_path, depth)
    local source_rooted_entry_path = source_root / relative_entry_path
    local mode = util.assert(source_rooted_entry_path:attr("mode"))
    if mode == "directory" then
      include_dir(relative_entry_path, depth + 1)
    elseif mode == "file" then
      -- phobos_extension is only used for compilation includes
      local included = not is_compilation_collection
        or source_rooted_entry_path:extension() == include_def.phobos_extension
      -- "" matches everything, don't waste time processing all of this
      if include_def.filename_pattern ~= "" and included then
        included = ("/"..source_rooted_entry_path:str()):find(include_def.filename_pattern)
      end
      if included then
        include_file(relative_entry_path)
      end
    end
  end

  include_entry(Path.new(), 1)
end

local function process_exclude(path_def, collection)
  local exclude_entry

  local function exclude_file(entry_path)
    local index = collection.files_lut[entry_path:str()]
    if index then
      if collection.is_compilation_collection then
        collection.files_lut[entry_path:str()] = nil
        collection.files[index] = nil -- leaves hole
        collection.count = collection.count - 1
      else
        local files = collection.files[index]
        local length = #files
        if length > 1 and path_def.pop then
          files[length] = nil
          collection.count = collection.count - 1
        else
          collection.files_lut[entry_path:str()] = nil
          collection.files[index] = nil -- leaves hole
          collection.count = collection.count - length
        end
      end
    end
  end

  local function exclude_dir(entry_path, depth)
    if depth > path_def.recursion_depth then return end
    for entry in lfs.dir(entry_path:str()) do
      if entry ~= "." or entry ~= ".." then
        exclude_entry(entry_path / entry)
      end
    end
  end

  function exclude_entry(entry_path, depth)
    local mode = util.assert(entry_path:attr("mode"))
    if mode == "directory" then
      exclude_dir(entry_path, depth + 1)
    elseif mode == "file" then
      -- filename_pattern "" matches everything => should exclude
      if path_def.filename_pattern == ""
        or ("/"..entry_path:str()):find(path_def.filename_pattern)
      then
        exclude_file(entry_path)
      end
    end
  end

  exclude_entry(Path.new(path_def.source_path):to_fully_qualified(collection.root_dir):normalize())
end

---current and cached are profile metadata
local function determine_incremental(current_profile, cached_profile)
  local function get_output_root(profile)
    return Path.new(profile.output_dir):to_fully_qualified(profile.root_dir):normalize()
  end
  if not current_profile.incremental
    or not cached_profile
    or get_output_root(current_profile) ~= get_output_root(cached_profile)
  then
    return false, false
  end
  if current_profile.use_load ~= cached_profile.use_load
    or current_profile.phobos_extension ~= cached_profile.phobos_extension
    or current_profile.lua_extension ~= cached_profile.lua_extension
  then
    return false, true
  end
  for name in pairs(get_all_optimizations()) do
    if not current_profile.optimizations[name] ~= not cached_profile.optimizations[name] then
      return false, true
    end
  end
  -- TODO: compare modification dates of profile files and injection script files and the files they all require
  return true, true
end

local function should_update(file, action, cached_file_mapping, incremental)
  local cached_file = cached_file_mapping and cached_file_mapping[file.output_filename]
  if not incremental
    or (cached_file and cached_file.source_filename) ~= file.source_filename
    or (cached_file and cached_file.action) ~= action
    or not Path.new(file.output_filename):exists()
  then
    return true
  end
  local source_modification = lfs.attributes(file.source_filename, "modification")
  local output_modification = lfs.attributes(file.output_filename, "modification")
  return os.difftime(source_modification, output_modification) > 0
end

local function process_include_exclude_definitions(defs, file_collection)
  for _, include_or_exclude_def in ipairs(defs) do
    if include_or_exclude_def.type == "include" then
      process_include(include_or_exclude_def, file_collection)
    elseif include_or_exclude_def.type == "exclude" then
      process_exclude(include_or_exclude_def, file_collection)
    else
      error("Impossible path definition type '"..(include_or_exclude_def.type or "<nil>").."'.")
    end
  end
end

local function unify_file_collections(compile_collection, copy_collection)
  local file_mapping = {}
  local file_list = {}
  local function add_file(file, action)
    if file then
      local existing = file_mapping[file.output_filename]
      if existing then
        util.abort("Attempt to output to the same file location twice: '"..file.output_filename.."'. \z
          Sources: '"..existing.source_filename.."' (" ..action_name_lut[existing.action].."), '"
          ..file.source_filename.."' ("..action..")."
        )
      end
      file.action = action
      file_mapping[file.output_filename] = file
      file_list[#file_list+1] = file
    end
  end
  for i = 1, compile_collection.next_index - 1 do
    add_file(compile_collection.files[i], action_enum.compile)
  end
  for i = 1, copy_collection.next_index - 1 do
    local files = copy_collection.files[i]
    if files then
      for _, file in ipairs(files) do
        add_file(file, action_enum.copy)
      end
    end
  end
  return file_list, file_mapping
end

local function make_file_mapping_from_file_list(file_list)
  local file_mapping = {}
  for _, file in ipairs(file_list) do
    file_mapping[file.output_filename] = file
  end
  return file_mapping
end

---@param profile PhobosProfileInternal
---@param print? fun(message: string)
local function run_profile(profile, print)
  print = print or function() end
  print("running profile '"..profile.name.."'")

  if profile.on_pre_profile_ran then
    print("running on_pre_profile_ran")
    profile.on_pre_profile_ran()
  end

  local total_memory_allocated = 0
  if profile.measure_memory then
    collectgarbage("stop")
    total_memory_allocated = -collectgarbage("count")
  end

  ---can be nil
  local cached_profile, cached_file_mapping
  do
    local file_list
    cached_profile, file_list = cache.load(profile.cache_dir)
    cached_file_mapping = file_list and make_file_mapping_from_file_list(file_list)
  end

  local file_list, compile_count, copy_count
  do
    local output_root = Path.new(profile.output_dir):to_fully_qualified(profile.root_dir):normalize()
    local compilation_file_collection = new_file_collection(output_root, profile.root_dir, true)
    local copy_file_collection = new_file_collection(output_root, profile.root_dir)

    process_include_exclude_definitions(profile.include_exclude_definitions, compilation_file_collection)
    process_include_exclude_definitions(profile.include_exclude_copy_definitions, copy_file_collection)

    compile_count = compilation_file_collection.count
    copy_count = copy_file_collection.count
    file_list = unify_file_collections(compilation_file_collection, copy_file_collection)
  end

  local incremental_compile, incremental_copy = determine_incremental(profile, cached_profile)

  print("compiling "..compile_count.." files")
  local inject_script_cache = new_inject_script_cache()
  local context = compile_util.new_context()
  for i = 1, compile_count do
    if profile.measure_memory then
      local prev_gc_count = collectgarbage("count")
      if prev_gc_count > 4 * 1000 * 1000 then
        collectgarbage("collect")
        total_memory_allocated = total_memory_allocated + (prev_gc_count - collectgarbage("count"))
      end
    end
    local file = file_list[i]
    if should_update(file, action_enum.compile, cached_file_mapping, incremental_compile) then
      print("["..i.."/"..compile_count.."] "..file.source_filename)
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

  print("copying "..copy_count.." files")
  for i = compile_count + 1, compile_count + copy_count do
    local file = file_list[i]
    if should_update(file, action_enum.copy, cached_file_mapping, incremental_copy) then
      print("["..(i - compile_count).."/"..copy_count.."] "..file.source_filename)
      io_util.copy(file.source_filename, file.output_filename)
    end
  end

  cache.save(profile, file_list)

  if profile.measure_memory then
    total_memory_allocated = total_memory_allocated + collectgarbage("count")
    print("total memory allocated "..(total_memory_allocated / (1000 * 1000)).." gigabytes")
    collectgarbage("restart")
  end

  if profile.on_post_profile_ran then
    print("running on_post_profile_ran")
    profile.on_post_profile_ran()
  end

  print("finished profile '"..profile.name.."'")
end

return {
  action_enum = action_enum,
  action_name_lut = action_name_lut,
  new_profile = new_profile,
  include = include,
  exclude = exclude,
  include_copy = include_copy,
  exclude_copy = exclude_copy,
  get_all_optimizations = get_all_optimizations,
  run_profile = run_profile,
}
