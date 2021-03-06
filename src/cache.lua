
local util = require("util")
local io_util = require("io_util")
local Path = require("lib.path")
local binary = require("binary_serializer")
local constants = require("constants")

local function save(profile, all_inject_scripts, file_list)
  local cache_dir = Path.new(profile.root_dir) / profile.cache_dir
  local profile_ser = binary.new_serializer()
  profile_ser:write_raw(constants.phobos_signature)
  profile_ser:write_uint16(0) -- metadata version
  local version = profile.phobos_version
  profile_ser:write_uint16(version.major)
  profile_ser:write_uint16(version.minor)
  profile_ser:write_uint16(version.patch)
  profile_ser:write_string(profile.name)
  profile_ser:write_string(profile.output_dir)
  profile_ser:write_string(profile.cache_dir)
  profile_ser:write_boolean(profile.use_load)
  profile_ser:write_boolean(profile.optimizations.fold_const)
  profile_ser:write_boolean(profile.optimizations.fold_control_statements)
  profile_ser:write_boolean(profile.optimizations.tail_calls)
  profile_ser:write_small_uint32(profile.error_message_count)
  profile_ser:write_boolean(profile.measure_memory)
  profile_ser:write_string(profile.root_dir)
  profile_ser:write_boolean(profile.incremental)
  io_util.write_file(cache_dir / "phobos_metadata.dat", profile_ser:tostring())

  local files_ser = binary.new_serializer()
  files_ser:write_medium_uint64(#all_inject_scripts)
  for _, inject_scripts in ipairs(all_inject_scripts) do
    if inject_scripts.usage_count == 0 then
      util.debug_abort("Attempt to save cache with inject_scripts with usage_count == 0. \z
        this is not actually an issue, however if this is ever 0 it most likely means \z
        there is a bug somewhere else in the code."
      )
    end
    files_ser:write_small_uint64(inject_scripts.id)
    files_ser:write_medium_uint64(inject_scripts.usage_count)
    files_ser:write_medium_uint64(#inject_scripts.filenames)
    for _, filename in ipairs(inject_scripts.filenames) do
      files_ser:write_string(filename)
    end
    -- modification_lut can be restored using required_files
    files_ser:write_medium_uint64(#inject_scripts.required_files)
    for _, file in ipairs(inject_scripts.required_files) do
      files_ser:write_string(file.filename)
      files_ser:write_uint64(file.modification)
    end
    -- funcs do not get cached
  end
  files_ser:write_medium_uint64(#file_list)
  for _, file in ipairs(file_list) do
    files_ser:write_uint8(file.action)
    if file.action == constants.action_enum.compile then
      files_ser:write_string(file.source_filename)
      files_ser:write_string(file.relative_source_filename)
      files_ser:write_string(file.output_filename)
      files_ser:write_string(file.source_name)
      files_ser:write_boolean(file.use_load)
      files_ser:write_small_uint32(file.error_message_count)
      files_ser:write_small_uint64(file.inject_scripts.id)
    elseif file.action == constants.action_enum.copy then
      files_ser:write_string(file.source_filename)
      files_ser:write_string(file.output_filename)
    elseif file.action == constants.action_enum.delete then
      files_ser:write_string(file.output_filename)
    else
      util.debug_abort("Invalid file action '"..file.action.."'.")
    end
  end
  io_util.write_file(cache_dir / "files.dat", files_ser:tostring())
end

local function load(root_dir, cache_dir)
  cache_dir = Path.new(root_dir) / cache_dir
  local metadata_path = cache_dir / "phobos_metadata.dat"
  if not metadata_path:exists() then
    return nil -- no cache, nothing to load. No warning message, this is perfectly fine
  end
  local profile_des = binary.new_deserializer(io_util.read_file(metadata_path))
  if profile_des:get_length() < #constants.phobos_signature + 2 then
    return nil, nil, "Invalid cache metadata, it is too short."
  end
  if profile_des:read_raw(#constants.phobos_signature) ~= constants.phobos_signature then
    -- signature doesn't match, someone messed with it, it is invalid
    return nil, nil, "Invalid cache metadata signature."
  end
  local version = profile_des:read_uint16()
  if version > 0 then
    -- cache has a newer version => cannot read it => it is invalid
    return nil, nil, "Cannot load cache version "..version.." from a newer version of Phobos."
  end
  -- if version < 0 then
  --   -- this is where migration calls will be, but there are none yet
  --   -- there is a good chance this will early return with the migrated result
  --   -- there is also a good chance this entire structure will change with migrations
  -- end

  local function assert_end_of_deserializer(des, filename)
    util.debug_assert(des:is_done(), "Expected end of binary data in cache file '"..filename.."'.")
  end

  local profile
  local file_list

  local success, err = xpcall(function()
    profile = {}
    profile.phobos_version = {
      major = profile_des:read_uint16(),
      minor = profile_des:read_uint16(),
      patch = profile_des:read_uint16(),
    }
    profile.name = profile_des:read_string()
    profile.output_dir = profile_des:read_string()
    profile.cache_dir = profile_des:read_string()
    profile.use_load = profile_des:read_boolean()
    local optimizations = {}
    optimizations.fold_const = profile_des:read_boolean()
    optimizations.fold_control_statements = profile_des:read_boolean()
    optimizations.tail_calls = profile_des:read_boolean()
    profile.optimizations = optimizations
    profile.error_message_count = profile_des:read_small_uint32()
    profile.measure_memory = profile_des:read_boolean()
    profile.root_dir = profile_des:read_string()
    profile.incremental = profile_des:read_boolean()
    assert_end_of_deserializer(profile_des, "phobos_metadata.dat")

    local files_des = binary.new_deserializer(io_util.read_file(cache_dir / "files.dat"))
    local inject_scripts_lut = {}
    for _ = 1, files_des:read_medium_uint64() do
      local inject_scripts = {}
      inject_scripts.id = files_des:read_small_uint64()
      inject_scripts.usage_count = files_des:read_medium_uint64()
      local filenames = {}
      inject_scripts.filenames = filenames
      for i = 1, files_des:read_medium_uint64() do
        filenames[i] = files_des:read_string()
      end
      local modification_lut = {}
      local required_files = {}
      inject_scripts.modification_lut = modification_lut
      inject_scripts.required_files = required_files
      for i = 1, files_des:read_medium_uint64() do
        local filename = files_des:read_string()
        local modification = files_des:read_uint64()
        util.debug_assert(filename, "Corrupted 'files.dat': nil filename.")
        ---@cast filename -?
        modification_lut[filename] = modification
        required_files[i] = {
          filename = filename,
          modification = modification,
        }
      end
      inject_scripts_lut[inject_scripts.id] = inject_scripts
    end
    file_list = {}
    for i = 1, files_des:read_medium_uint64() do
      local file = {}
      file.action = files_des:read_uint8()
      if file.action == constants.action_enum.compile then
        file.source_filename = files_des:read_string()
        file.relative_source_filename = files_des:read_string()
        file.output_filename = files_des:read_string()
        file.source_name = files_des:read_string()
        file.use_load = files_des:read_boolean()
        file.error_message_count = files_des:read_small_uint32()
        file.inject_scripts = util.debug_assert(
          inject_scripts_lut[files_des:read_small_uint64()],
          "Invalid inject script ids."
        )
      elseif file.action == constants.action_enum.copy then
        file.source_filename = files_des:read_string()
        file.output_filename = files_des:read_string()
      elseif file.action == constants.action_enum.delete then
        file.output_filename = files_des:read_string()
      else
        util.debug_abort("Invalid file action '"..file.action.."'.")
      end
      file_list[i] = file
    end
    assert_end_of_deserializer(files_des, "files.dat")
  end, function(msg)
    return debug.traceback("Corrupted cache: "..msg, 2)
  end)

  if not success then
    -- any error while loading the cache means the cache is invalid
    return nil, nil, err
  end

  return profile, file_list
end

return {
  save = save,
  load = load,
}
