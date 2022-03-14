
local util = require("util")
local io_util = require("io_util")
local Path = require("lib.LuaPath.path")
local binary = require("binary_serializer")
local constants = require("constants")
-- ---@type LFS
-- local lfs = require("lfs")

local action_enum = {
  compile = 0,
  copy = 1,
}
local action_name_lut = {
  [0] = "compile",
  [1] = "copy",
}

local function make_file_mapping(compile_collection, copy_collection)
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
      local file_data = {
        source_filename = file.source_filename,
        output_filename = file.output_filename,
        action = action,
      }
      file_mapping[file.output_filename] = file_data
      file_list[#file_list+1] = file_data
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
  return file_mapping, file_list
end

local function make_file_mapping_from_file_list(file_list)
  local file_mapping = {}
  for _, file in ipairs(file_list) do
    file_mapping[file.output_filename] = file
  end
  return file_mapping
end

local function make_profile_meta(profile)
  -- local inject_script_modifications = {}
  -- for i, modification in ipairs(profile.inject_scripts) do
  --   inject_script_modifications[i] = modification
  -- end
  return {
    name = profile.name,
    output_dir = profile.output_dir,
    cache_dir = profile.cache_dir,
    phobos_extension = profile.phobos_extension,
    lua_extension = profile.lua_extension,
    use_load = profile.use_load,
    incremental = profile.incremental,
    -- inject_scripts = profile.inject_scripts,
    -- inject_script_modifications = inject_script_modifications,
    optimizations = profile.optimizations,
    error_message_count = profile.error_message_count,
    measure_memory = profile.measure_memory,
    root_dir = profile.root_dir,
  }
end

local function save(profile_meta, file_list)
  local meta_ser = binary.new_serializer()
  meta_ser:write_raw(constants.phobos_signature)
  meta_ser:write_uint16(0) -- metadata version
  meta_ser:write_string(profile_meta.name)
  meta_ser:write_string(profile_meta.output_dir)
  meta_ser:write_string(profile_meta.cache_dir)
  meta_ser:write_string(profile_meta.phobos_extension)
  meta_ser:write_string(profile_meta.lua_extension)
  meta_ser:write_boolean(profile_meta.use_load)
  -- meta_ser:write_small_uint32(#profile_meta.inject_scripts)
  -- for i, inject_script in ipairs(profile_meta.inject_scripts) do
  --   meta_ser:write_string(inject_script)
  --   meta_ser:write_uint64(profile_meta.inject_script_modifications[i])
  -- end
  meta_ser:write_boolean(profile_meta.optimizations.fold_const)
  meta_ser:write_boolean(profile_meta.optimizations.fold_control_statements)
  meta_ser:write_boolean(profile_meta.optimizations.tail_calls)
  meta_ser:write_small_uint32(profile_meta.error_message_count)
  meta_ser:write_string(profile_meta.root_dir)
  io_util.write_file(Path.new(profile_meta.cache_dir) / "phobos_metadata.dat", meta_ser:tostring())

  local files_ser = binary.new_serializer()
  files_ser:write_medium_uint64(#file_list)
  for _, file in ipairs(file_list) do
    files_ser:write_string(file.source_filename)
    files_ser:write_string(file.output_filename)
    files_ser:write_uint8(file.action)
  end
  io_util.write_file(Path.new(profile_meta.cache_dir) / "files.dat", files_ser:tostring())
end

local function load(cache_dir)
  local metadata_path = Path.new(cache_dir) / "phobos_metadata.dat"
  if not metadata_path:exists() then
    return nil -- no cache, nothing to load
  end
  local meta_des = binary.new_deserializer(io_util.read_file(metadata_path))
  if meta_des:read_raw(#constants.phobos_signature) ~= constants.phobos_signature then
    return nil -- signature doesn't match, someone messed with it, it is invalid
  end
  local version = meta_des:read_uint16()
  if version > 0 then
    return nil -- cache has a newer version => cannot read it => it is invalid
  end
  -- if version < 0 then
  --   -- this is where migration calls will be, but there are none yet
  --   -- there is a good chance this will early return with the migrated result
  --   -- there is also a good chance this entire structure will change with migrations
  -- end

  local profile_meta
  local file_list

  local success = pcall(function()
    profile_meta = {}
    profile_meta.name = meta_des:read_string()
    profile_meta.output_dir = meta_des:read_string()
    profile_meta.cache_dir = meta_des:read_string()
    profile_meta.phobos_extension = meta_des:read_string()
    profile_meta.lua_extension = meta_des:read_string()
    profile_meta.use_load = meta_des:read_boolean()
    profile_meta.inject_scripts = {}
    profile_meta.inject_script_modifications = {}
    -- local inject_script_count = meta_des:read_small_uint32()
    -- for i = 1, inject_script_count do
    --   profile_meta.inject_scripts[i] = meta_des:read_string()
    --   profile_meta.inject_script_modifications[i] = meta_des:read_uint64()
    -- end
    local optimizations = {}
    optimizations.fold_const = meta_des:read_boolean()
    optimizations.fold_control_statements = meta_des:read_boolean()
    optimizations.tail_calls = meta_des:read_boolean()
    profile_meta.optimizations = optimizations
    profile_meta.error_message_count = meta_des:read_small_uint32()
    profile_meta.root_dir = meta_des:read_string()
    util.assert(meta_des:is_done(),
      "There is more content in the cache phobos_metadata.dat file than there should be."
    )

    local files_des = binary.new_deserializer(io_util.read_file(Path.new(cache_dir) / "files.dat"))
    file_list = {}
    for i = 1, files_des:read_medium_uint64() do
      file_list[i] = {
        source_filename = files_des:read_string(),
        output_filename = files_des:read_string(),
        action = files_des:read_uint8(),
      }
    end
  end)

  if not success then
    return nil -- any error while loading the cache means the cache is invalid
  end

  return profile_meta, file_list
end

return {
  action_enum = action_enum,
  make_file_mapping = make_file_mapping,
  make_file_mapping_from_file_list = make_file_mapping_from_file_list,
  make_profile_meta = make_profile_meta,
  save = save,
  load = load,
}
