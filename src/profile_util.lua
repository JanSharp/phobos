
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
Path.set_main_separator("/")
local util = require("util")
local io_util = require("io_util")
local compile_util = require("compile_util")
local cache = require("cache")
local phobos_version = require("phobos_version")
local api_util = require("api_util")
local sandbox_util = require("sandbox_util")
local constants = require("constants")

local action_enum = constants.action_enum
local action_name_lut = constants.action_name_lut

---@class NewProfileInternalParams : NewProfileParams
---**default:** `true`\
---Should only files with a newer modification time get compiled or copied?
---@field incremental boolean

---@class PhobosProfileInternal : PhobosProfile
---**default:** `true`\
---Should only files with a newer modification time get compiled or copied?
---@field incremental boolean
---profile_util handles this field and uses it to determine if the current compilation can be incremental
---@field phobos_version table

local function validate_field_raw(name, value, expected_type, mandatory, expected_type_description)
  if mandatory then
    if value == nil then
      api_util.abort("'"..name.."' (mandatory): Expected type "
        ..(expected_type_description or expected_type)..", got nil."
      )
    end
  elseif value == nil then
    return
  end
  if type(value) ~= expected_type then
    api_util.abort("'"..name.."'"
      ..(mandatory == nil and "" or mandatory and " (mandatory)" or " (optional)")
      ..": Expected type "
      ..(expected_type_description or expected_type)..", got "..type(value).."."
    )
  end
end

local function validate_field(t, name, field, expected_type, mandatory, expected_value_description)
  validate_field_raw(name.."."..field, t[field], expected_type, mandatory, expected_value_description)
end

local function assert_params(params)
  api_util.assert(type(params) == "table", "Expected params table, got "..type(params)..".")
end

local function assert_params_and_profile(params, field, type_name)
  assert_params(params)
  validate_field(params, "params", "profile", "table", true, "must be a Profile")
  validate_field(params.profile, "params.profile", field, "table", true, "must be an "..type_name.."[]")
end

-- TODO: remove lua_extension and phobos_extension

local function validate_include_def(def, name)
  name = name or "IncludeInCompilationDef"
  validate_field(def, name, "source_path", "string", true)
  validate_field(def, name, "output_path", "string", true)
  validate_field(def, name, "recursion_depth", "number", true)
  validate_field(def, name, "filename_pattern", "string", true)
  validate_field(def, name, "source_name", "string", true)
  api_util.assert(def.source_name:find("^@"), "'"..name..".source_name' (mandatory): \z
    Must start with the symbol '@' to indicate the source is a file."
  )
  validate_field(def, name, "phobos_extension", "string", true)
  validate_field(def, name, "lua_extension", "string", true)
  validate_field(def, name, "use_load", "boolean", true)
  validate_field(def, name, "error_message_count", "number", true)
  validate_field(def, name, "inject_scripts", "table", true, "must be an string[]")
  for i, inject_script in ipairs(def.inject_scripts) do
    validate_field_raw(name..".inject_script["..i.."]", inject_script, "string", true)
  end
end

local function validate_exclude_def(def, name)
  name = name or "ExcludeInCompilationDef"
  validate_field(def, name, "source_path", "string", true)
  validate_field(def, name, "recursion_depth", "number", true)
  validate_field(def, name, "filename_pattern", "string", true)
end

local function validate_include_copy_def(def, name)
  name = name or "IncludeInCopyDef"
  validate_field(def, name, "source_path", "string", true)
  validate_field(def, name, "output_path", "string", true)
  validate_field(def, name, "recursion_depth", "number", true)
  validate_field(def, name, "filename_pattern", "string", true)
end

local function validate_exclude_copy_def(def, name)
  name = name or "ExcludeInCopyDef"
  validate_field(def, name, "source_path", "string", true)
  validate_field(def, name, "recursion_depth", "number", true)
  validate_field(def, name, "filename_pattern", "string", true)
  validate_field(def, name, "pop", "boolean", true)
end

local function validate_include_delete_def(def, name)
  name = name or "IncludeInDeleteDef"
  validate_field(def, name, "output_path", "string", true)
  validate_field(def, name, "recursion_depth", "number", true)
  validate_field(def, name, "filename_pattern", "string", true)
end

local function validate_exclude_delete_def(def, name)
  name = name or "ExcludeInDeleteDef"
  validate_field(def, name, "output_path", "string", true)
  validate_field(def, name, "recursion_depth", "number", true)
  validate_field(def, name, "filename_pattern", "string", true)
end

local function validate_profile(profile)
  validate_field(profile, "profile", "name", "string", true)
  validate_field(profile, "profile", "output_dir", "string", true)
  validate_field(profile, "profile", "cache_dir", "string", true)
  validate_field(profile, "profile", "phobos_extension", "string", true)
  validate_field(profile, "profile", "lua_extension", "string", true)
  validate_field(profile, "profile", "use_load", "boolean", true)
  validate_field(profile, "profile", "incremental", "boolean", true)
  validate_field(profile, "profile", "inject_scripts", "table", true, "must be an string[]")
  for i, inject_script in ipairs(profile.inject_scripts) do
    validate_field_raw("profile.inject_script["..i.."]", inject_script, "string", true)
  end
  validate_field(profile, "profile", "optimizations", "table", true)
  validate_field(profile.optimizations, "profile.optimizations", "fold_const", "boolean", false)
  validate_field(profile.optimizations, "profile.optimizations", "fold_control_statements", "boolean", false)
  validate_field(profile.optimizations, "profile.optimizations", "tail_calls", "boolean", false)
  validate_field(profile, "profile", "error_message_count", "number", true)
  validate_field(profile, "profile", "measure_memory", "boolean", true)
  validate_field(profile, "profile", "root_dir", "string", true)
  validate_field(profile, "profile", "on_pre_profile_ran", "function", false)
  validate_field(profile, "profile", "on_post_profile_ran", "function", false)
  local function validate_include_exclude(field, type_name, validate_include_func, validate_exclude_func)
    validate_field(profile, "profile", field, "table", true, "must be an "..type_name.."[]")
    for i, def in ipairs(profile[field]) do
      validate_field_raw("profile."..field.."["..i.."]", def, "table", nil, "must be an "..type_name)
      if def.type == "include" then
        validate_include_func(def, "profile."..field.."["..i.."]")
      elseif def.type == "exclude" then
        validate_exclude_func(def, "profile."..field.."["..i.."]")
      else
        api_util.abort("profile.include_exclude_definitions["..i
          .."].type: Expected 'include' or 'exclude', got "..tostring(def.type).."."
        )
      end
    end
  end
  validate_include_exclude(
    "include_exclude_definitions",
    "IncludeOrExcludeInCompilationDef",
    validate_include_def,
    validate_exclude_def
  )
  validate_include_exclude(
    "include_exclude_copy_definitions",
    "IncludeOrExcludeCopyDef",
    validate_include_copy_def,
    validate_exclude_copy_def
  )
  validate_include_exclude(
    "include_exclude_delete_definitions",
    "IncludeOrExcludeDeleteDef",
    validate_include_delete_def,
    validate_exclude_delete_def
  )
end

---`root_dir` does not have an explicit default when using this function.\
---Technically it will be using the current working directory if it's `nil` because of `Path.to_fully_qualified`.
---@param params NewProfileInternalParams
local function new_profile(params)
  assert_params(params)
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
    include_exclude_delete_definitions = {},
  }
  validate_profile(profile)
  return profile
end

---@param params IncludeParams
local function include(params)
  assert_params_and_profile(params, "include_exclude_definitions", "IncludeOrExcludeInCompilationDef")
  local def = {
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
  validate_include_def(def)
  params.profile.include_exclude_definitions[#params.profile.include_exclude_definitions+1] = def
end

---@param params ExcludeParams
local function exclude(params)
  assert_params_and_profile(params, "include_exclude_definitions", "IncludeOrExcludeInCompilationDef")
  local def = {
    type = "exclude",
    source_path = params.source_path,
    recursion_depth = params.recursion_depth or (1/0),
    filename_pattern = params.filename_pattern or "",
  }
  validate_exclude_def(def)
  params.profile.include_exclude_definitions[#params.profile.include_exclude_definitions+1] = def
end

---@param params IncludeCopyParams
local function include_copy(params)
  assert_params_and_profile(params, "include_exclude_copy_definitions", "IncludeOrExcludeCopyDef")
  local def = {
    type = "include",
    source_path = params.source_path,
    output_path = params.output_path,
    recursion_depth = params.recursion_depth or (1/0),
    filename_pattern = params.filename_pattern or "",
  }
  validate_include_copy_def(def)
  params.profile.include_exclude_copy_definitions[#params.profile.include_exclude_copy_definitions+1] = def
end

---@param params ExcludeCopyParams
local function exclude_copy(params)
  assert_params_and_profile(params, "include_exclude_copy_definitions", "IncludeOrExcludeCopyDef")
  local def = {
    type = "exclude",
    source_path = params.source_path,
    recursion_depth = params.recursion_depth or (1/0),
    filename_pattern = params.filename_pattern or "",
    pop = params.pop or false,
  }
  validate_exclude_copy_def(def)
  params.profile.include_exclude_copy_definitions[#params.profile.include_exclude_copy_definitions+1] = def
end

---@param params IncludeDeleteParams
local function include_delete(params)
  assert_params_and_profile(params, "include_exclude_delete_definitions", "IncludeOrExcludeDeleteDef")
  local def = {
    type = "include",
    output_path = params.output_path,
    recursion_depth = params.recursion_depth or (1/0),
    filename_pattern = params.filename_pattern or "",
  }
  validate_include_delete_def(def)
  params.profile.include_exclude_delete_definitions[#params.profile.include_exclude_delete_definitions+1] = def
end

---@param params ExcludeDeleteParams
local function exclude_delete(params)
  assert_params_and_profile(params, "include_exclude_delete_definitions", "IncludeOrExcludeDeleteDef")
  local def = {
    type = "exclude",
    output_path = params.output_path,
    recursion_depth = params.recursion_depth or (1/0),
    filename_pattern = params.filename_pattern or "",
  }
  validate_exclude_delete_def(def)
  params.profile.include_exclude_delete_definitions[#params.profile.include_exclude_delete_definitions+1] = def
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

local function get_modification(filename)
  return util.debug_assert(lfs.attributes(filename, "modification"))
end

local function new_inject_script_cache(root_dir)
  return {
    ---has `required_files` and `func`
    file_specific_data_lut = {},
    raw_to_full_filenames = {},

    next_id = 0,
    result_lut = {},
    results = {}, -- the list version of result_lut
    ---the root dir of the current profile
    root_dir = root_dir,
  }
end

local function get_inject_script_file_specific_data(filename, script_cache)
  local result = script_cache.file_specific_data_lut[filename]
  if result then
    return result
  end
  -- util.debug_print("compiling inject script "..filename)
  local main_chunk = assert(load(compile_util.compile({
    filename = filename,
    source_name = "@?",
    accept_bytecode = true,
  }, script_cache.inject_script_context), nil, "b"))
  sandbox_util.hook()
  local func = main_chunk()
  util.assert(type(func) == "function",
    "AST inject scripts must return a function. (script file: "..filename..")"
  )
  local required_files = sandbox_util.unhook()
  for i = #required_files, 1, -1 do
    local file = required_files[i]
    file = Path.new(file):to_fully_qualified():normalize():str()
    required_files[i + 1] = {
      filename = file,
      modification = get_modification(file),
    }
  end
  required_files[1] = {
    filename = filename,
    modification = get_modification(filename),
  }
  result = {
    required_files = required_files,
    func = func,
  }
  script_cache.file_specific_data_lut[filename] = result
  return result
end

local function load_inject_scripts(inject_scripts, script_cache)
  for i, filename in ipairs(inject_scripts.filenames) do
    local data = get_inject_script_file_specific_data(filename, script_cache)
    inject_scripts.funcs[i] = data.func
    for _, file in ipairs(data.required_files) do
      if not inject_scripts.modification_lut[file.filename] then
        inject_scripts.modification_lut[file.filename] = file.modification
        inject_scripts.required_files[#inject_scripts.required_files+1] = file
      end
    end
  end
end

local function get_inject_script_data(raw_inject_scripts, script_cache)
  local result = script_cache.result_lut[raw_inject_scripts]
  if result then
    return result
  end

  local filenames = script_cache.raw_to_full_filenames[raw_inject_scripts]
  if not filenames then
    filenames = {}
    script_cache.raw_to_full_filenames[raw_inject_scripts] = filenames
    for i, raw_filename in ipairs(raw_inject_scripts) do
      filenames[i] = Path.new(raw_filename):to_fully_qualified(script_cache.root_dir):normalize():str()
    end
  end

  result = {
    id = script_cache.next_id,
    usage_count = 0,
    filenames = filenames,
    -- these 3 get populated by load_inject_scripts
    modification_lut = {},
    required_files = {},
    funcs = {},
  }
  script_cache.next_id = script_cache.next_id + 1
  script_cache.result_lut[raw_inject_scripts] = result
  script_cache.results[#script_cache.results+1] = result
  return result
end

local function new_file_collection(output_root, root_dir, action)
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
    action = action,
    ---only for compilation file collections, set outside this function
    inject_script_cache = nil,
  }
end

local function normalize_output_path(output_path)
  local normalized_output_path = Path.new(output_path):normalize()
  if normalized_output_path:is_absolute() then
    util.abort("'output_path' has to be a relative path (output_path: '"..output_path.."')")
  end
  if normalized_output_path.entries[1] == ".." then
    util.abort("Attempt to output files outside of the output directory. \z
      (output_path: '"..output_path.."', normalized: '"..normalized_output_path:str().."')"
    )
  end
  return normalized_output_path
end

local function replace_extension(path, extension)
  return path:sub(1, -2) / (path:filename()..extension)
end

local function process_include(include_def, collection)
  local relative_output_path = normalize_output_path(include_def.output_path)
  local output_root = collection.output_root / relative_output_path
  -- deleting is rooted at the output, and doesn't use source_path at all
  local source_root = collection.action == action_enum.delete
    and output_root
    or Path.new(include_def.source_path):to_fully_qualified(collection.root_dir):normalize()
  -- that also means that everything that is called something with "source" in this function
  -- actually refers to the output for delete collections

  local include_entry

  local function include_file(relative_entry_path)
    local source_filename = (source_root / relative_entry_path):str()
    local index = collection.files_lut[source_filename]
    if collection.action == action_enum.copy or not index then
      -- Only increment count if this is not overwriting an already included file.
      -- It is overwriting if it is a compilation collection and the source file was already added.
      -- Copy file collections can include the same file twice, so they always increment
      -- The other case is handled near the end of the function.
      collection.count = collection.count + 1
    end
    if not index then -- doesn't exist yet, so it's not overwriting but defining a new file
      index = collection.next_index
      collection.next_index = collection.next_index + 1
      collection.files_lut[source_filename] = index
      if collection.action == action_enum.copy then
        collection.files[index] = {} -- new array
      end
    end
    local relative_output_entry_path = collection.action == action_enum.compile
      and replace_extension(relative_entry_path, include_def.lua_extension)
      or relative_entry_path
    if collection.action == action_enum.compile
      and not relative_output_entry_path.entries[1]
      and include_def.source_name:find("?", 1, true)
    then
      util.abort("When including a single file for compilation the 'source_name' must not contain '?'. \z
        It must instead define the entire source_name - it is not a pattern. \z
        (source_path: '"..include_def.source_path.."', source_name: '"..include_def.source_name.."')"
      )
    end
    if collection.action == action_enum.compile then
      local inject_scripts = get_inject_script_data(include_def.inject_scripts, collection.inject_script_cache)
      inject_scripts.usage_count = inject_scripts.usage_count + 1
      -- not an array of files because compilation collections disallow compiling the same file twice anyway
      collection.files[index] = {
        action = action_enum.compile,
        source_filename = source_filename,
        relative_source_filename = relative_entry_path:str(),
        output_filename = (output_root / relative_output_entry_path):str(),
        source_name = include_def.source_name,
        use_load = include_def.use_load,
        error_message_count = include_def.error_message_count,
        inject_scripts = inject_scripts,
      }
    elseif collection.action == action_enum.delete then
      -- Again not an array. I mean how would you delete the same file twice. You don't.
      collection.files[index] = {
        action = action_enum.delete,
        output_filename = source_filename,
      }
    else
      local files = collection.files[index]
      local output_filename = (output_root / relative_output_entry_path):str()
      -- if the source an output filename combination already then exists just ignore this one
      for _, file in ipairs(files) do
        if file.source_filename == source_filename and file.output_filename == output_filename then
          -- This is the other case that was mentioned at the beginning of the function.
          collection.count = collection.count - 1
          goto ignore
        end
      end
      files[#files+1] = {
        action = action_enum.copy,
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
        include_entry(relative_entry_path / entry, depth + 1)
      end
    end
  end

  function include_entry(relative_entry_path, depth)
    local source_rooted_entry_path = source_root / relative_entry_path
    if depth == 1
      and collection.action == action_enum.delete
      and not source_rooted_entry_path:exists()
    then
      return
    end
    local mode = util.assert(source_rooted_entry_path:attr("mode"))
    if mode == "directory" then
      include_dir(relative_entry_path, depth)
    elseif mode == "file" then
      -- phobos_extension is only used for compilation includes
      local included = collection.action ~= action_enum.compile
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

local function process_exclude(exclude_def, collection)
  local exclude_entry

  local function exclude_file(entry_path)
    local index = collection.files_lut[entry_path:str()]
    if index then
      if collection.action ~= action_enum.copy then
        if collection.action == action_enum.compile then
          local inject_scripts = collection.files[index].inject_scripts
          inject_scripts.usage_count = inject_scripts.usage_count - 1
        end
        collection.files_lut[entry_path:str()] = nil
        collection.files[index] = nil -- leaves hole
        collection.count = collection.count - 1
      else
        local files = collection.files[index]
        local length = #files
        if length > 1 and exclude_def.pop then
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
    if depth > exclude_def.recursion_depth then return end
    for entry in lfs.dir(entry_path:str()) do
      if entry ~= "." and entry ~= ".." then
        exclude_entry(entry_path / entry, depth + 1)
      end
    end
  end

  function exclude_entry(entry_path, depth)
    if depth == 1
      and collection.action == action_enum.delete
      and not entry_path:exists()
    then
      return
    end
    local mode = util.assert(entry_path:attr("mode"))
    if mode == "directory" then
      exclude_dir(entry_path, depth)
    elseif mode == "file" then
      -- filename_pattern "" matches everything => should exclude
      if exclude_def.filename_pattern == ""
        or ("/"..entry_path:str()):find(exclude_def.filename_pattern)
      then
        exclude_file(entry_path)
      end
    end
  end

  if collection.action == action_enum.delete then
    local relative_output_path = normalize_output_path(exclude_def.output_path)
    exclude_entry(collection.output_root / relative_output_path, 1)
  else
    exclude_entry(Path.new(exclude_def.source_path):to_fully_qualified(collection.root_dir):normalize(), 1)
  end
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
    -- cannot compile nor copy incrementally
    return false, false
  end
  if current_profile.phobos_extension ~= cached_profile.phobos_extension
    or current_profile.lua_extension ~= cached_profile.lua_extension
    or current_profile.phobos_version.major ~= cached_profile.phobos_version.major
    or current_profile.phobos_version.minor ~= cached_profile.phobos_version.minor
    or current_profile.phobos_version.patch ~= cached_profile.phobos_version.patch
  then
    -- cannot compile incrementally, but can copy incrementally
    return false, true
  end
  for name in pairs(get_all_optimizations()) do
    if not current_profile.optimizations[name] ~= not cached_profile.optimizations[name] then
      -- cannot compile incrementally, but can copy incrementally
      return false, true
    end
  end
  return true, true
end

local function should_update(file, action, cached_file_mapping, incremental)
  util.debug_assert(file.action ~= action_enum.delete, "Attempt to use the function should_update \z
    for a file with the action type '"..action_name_lut[action_enum.delete].."'."
  )
  local cached_file = cached_file_mapping and cached_file_mapping[file.output_filename]
  if not incremental
    or not cached_file
    or cached_file.source_filename ~= file.source_filename -- both compile and copy actions have this
    or cached_file.action ~= action
    or not Path.new(file.output_filename):exists()
  then
    return true
  end
  if file.action == action_enum.compile then -- compile specific
    local function get_source_name(file_data)
      return compile_util.get_source_name{
        filename = file_data.relative_source_filename,
        source_name = file_data.source_name,
      }
    end
    if file.use_load ~= cached_file.use_load
      or get_source_name(file) ~= get_source_name(cached_file)
    then
      return true
    end
    -- inject_scripts
    local inject_scripts = file.inject_scripts
    local cached_inject_scripts = cached_file.inject_scripts
    for i = 1, #inject_scripts.filenames + 1 do -- +1 to also make sure they both have the same length
      if inject_scripts.filenames[i] ~= cached_inject_scripts.filenames[i] then
        return true
      end
    end
    -- if all their modification dates match then there is no way one required more or less files than the other
    -- so the only way this could fail to identify changes is if the inject scripts read files manually
    local modification_lut = inject_scripts.modification_lut
    for _, required_file in ipairs(cached_inject_scripts.required_files) do
      if modification_lut[required_file.filename] ~= required_file.modification then
        return true
      end
    end
  end
  local source_modification = get_modification(file.source_filename)
  local output_modification = get_modification(file.output_filename)
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

local function unify_file_collections(compile_collection, copy_collection, delete_collection)
  -- TODO: properly handle input and output paths colliding [...]
  -- ref: output and input dir are the exact same
  local file_mapping = {}
  local file_list = {}
  local function add_file(file)
    if file then
      local existing = file_mapping[file.output_filename]
      if existing then
        if file.action == action_enum.delete then
          return -- just return because we won't delete files that are just getting outputted
        end
        -- for compile and copy it's an error though
        util.abort("Attempt to output to the same file location twice: '"..file.output_filename.."'. \z
          Sources: '"..existing.source_filename.."' (" ..action_name_lut[existing.action].."), '"
          ..file.source_filename.."' ("..action_name_lut[file.action]..")."
        )
      end
      file_mapping[file.output_filename] = file
      file_list[#file_list+1] = file
    end
  end
  for i = 1, compile_collection.next_index - 1 do
    add_file(compile_collection.files[i])
  end
  for i = 1, copy_collection.next_index - 1 do
    local files = copy_collection.files[i]
    if files then
      for _, file in ipairs(files) do
        add_file(file)
      end
    end
  end
  for i = 1, delete_collection.next_index - 1 do
    add_file(delete_collection.files[i])
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

  profile.phobos_version = phobos_version

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

  local inject_script_cache = new_inject_script_cache()
  local file_list, compile_count, copy_count, delete_count
  do
    local output_root = Path.new(profile.output_dir):to_fully_qualified(profile.root_dir):normalize()
    local compilation_file_collection = new_file_collection(output_root, profile.root_dir, action_enum.compile)
    compilation_file_collection.inject_script_cache = inject_script_cache
    local copy_file_collection = new_file_collection(output_root, profile.root_dir, action_enum.copy)
    local delete_file_collection = new_file_collection(output_root, profile.root_dir, action_enum.delete)

    process_include_exclude_definitions(profile.include_exclude_definitions, compilation_file_collection)
    process_include_exclude_definitions(profile.include_exclude_copy_definitions, copy_file_collection)
    process_include_exclude_definitions(profile.include_exclude_delete_definitions, delete_file_collection)

    compile_count = compilation_file_collection.count
    copy_count = copy_file_collection.count
    file_list = unify_file_collections(compilation_file_collection, copy_file_collection, delete_file_collection)
    -- can't use the count from the file collection because during unification
    -- delete actions will be removed if they would delete a file that is being compiled/copied to
    delete_count = #file_list - compile_count - copy_count
  end

  local all_inject_scripts = inject_script_cache.results
  do
    local i = 1
    local j = 1
    local c = 1
    while i <= c do
      local inject_scripts = all_inject_scripts[i]
      all_inject_scripts[i] = nil
      if inject_scripts.usage_count > 0 then
        all_inject_scripts[j] = inject_scripts
        load_inject_scripts(inject_scripts, inject_script_cache)
        -- local foo = {}
        -- for k, file in ipairs(inject_scripts.required_files) do
        --   foo[k] = "\n"..file.filename.." || "..os.date("%F %T", file.modification)
        -- end
        -- util.debug_print("inject scripts: "..table.concat(inject_scripts.filenames, ", ")..": \n\z
        --   used "..inject_scripts.usage_count.." times, requiring "..#foo.." files:"..table.concat(foo))
        j = j + 1
      end
      i = i + 1
    end
  end
  -- the previous code modified the results table of the cache and the cache should no longer be used
  inject_script_cache = nil

  local incremental_compile, incremental_copy = determine_incremental(profile, cached_profile)

  print("compiling "..compile_count.." files")
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
        inject_scripts = file.inject_scripts.funcs,
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

  print("deleting "..delete_count.." files")
  for i = compile_count + copy_count + 1, compile_count + copy_count + delete_count do
    local file = file_list[i]
    print("["..(i - compile_count - copy_count).."/"..delete_count.."] "..file.output_filename)
    os.remove(file.output_filename)
  end

  cache.save(profile, all_inject_scripts, file_list)

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
  include_delete = include_delete,
  exclude_delete = exclude_delete,
  get_all_optimizations = get_all_optimizations,
  validate_profile = validate_profile,
  run_profile = run_profile,
}
