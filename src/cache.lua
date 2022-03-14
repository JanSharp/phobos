
local util = require("util")
local io_util = require("io_util")
local Path = require("lib.LuaPath.path")
local binary = require("binary_serializer")
local constants = require("constants")
-- ---@type LFS
-- local lfs = require("lfs")

local function save(profile, file_list)
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
  profile_ser:write_string(profile.phobos_extension)
  profile_ser:write_string(profile.lua_extension)
  profile_ser:write_boolean(profile.use_load)
  -- meta_ser:write_small_uint32(#profile_meta.inject_scripts)
  -- for i, inject_script in ipairs(profile_meta.inject_scripts) do
  --   meta_ser:write_string(inject_script)
  --   meta_ser:write_uint64(profile_meta.inject_script_modifications[i])
  -- end
  profile_ser:write_boolean(profile.optimizations.fold_const)
  profile_ser:write_boolean(profile.optimizations.fold_control_statements)
  profile_ser:write_boolean(profile.optimizations.tail_calls)
  profile_ser:write_small_uint32(profile.error_message_count)
  profile_ser:write_string(profile.root_dir)
  io_util.write_file(Path.new(profile.cache_dir) / "phobos_metadata.dat", profile_ser:tostring())

  local files_ser = binary.new_serializer()
  files_ser:write_medium_uint64(#file_list)
  for _, file in ipairs(file_list) do
    files_ser:write_string(file.source_filename)
    files_ser:write_string(file.output_filename)
    files_ser:write_uint8(file.action)
  end
  io_util.write_file(Path.new(profile.cache_dir) / "files.dat", files_ser:tostring())
end

local function load(cache_dir)
  local metadata_path = Path.new(cache_dir) / "phobos_metadata.dat"
  if not metadata_path:exists() then
    return nil -- no cache, nothing to load
  end
  local profile_des = binary.new_deserializer(io_util.read_file(metadata_path))
  if profile_des:read_raw(#constants.phobos_signature) ~= constants.phobos_signature then
    return nil -- signature doesn't match, someone messed with it, it is invalid
  end
  local version = profile_des:read_uint16()
  if version > 0 then
    return nil -- cache has a newer version => cannot read it => it is invalid
  end
  -- if version < 0 then
  --   -- this is where migration calls will be, but there are none yet
  --   -- there is a good chance this will early return with the migrated result
  --   -- there is also a good chance this entire structure will change with migrations
  -- end

  local profile
  local file_list

  local success = pcall(function()
    profile = {}
    profile.phobos_version = {
      major = profile_des:read_uint16(),
      minor = profile_des:read_uint16(),
      patch = profile_des:read_uint16(),
    }
    profile.name = profile_des:read_string()
    profile.output_dir = profile_des:read_string()
    profile.cache_dir = profile_des:read_string()
    profile.phobos_extension = profile_des:read_string()
    profile.lua_extension = profile_des:read_string()
    profile.use_load = profile_des:read_boolean()
    -- profile.inject_scripts = {}
    -- profile.inject_script_modifications = {}
    -- local inject_script_count = meta_des:read_small_uint32()
    -- for i = 1, inject_script_count do
    --   profile_meta.inject_scripts[i] = meta_des:read_string()
    --   profile_meta.inject_script_modifications[i] = meta_des:read_uint64()
    -- end
    local optimizations = {}
    optimizations.fold_const = profile_des:read_boolean()
    optimizations.fold_control_statements = profile_des:read_boolean()
    optimizations.tail_calls = profile_des:read_boolean()
    profile.optimizations = optimizations
    profile.error_message_count = profile_des:read_small_uint32()
    profile.root_dir = profile_des:read_string()
    util.assert(profile_des:is_done(),
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

  return profile, file_list
end

return {
  save = save,
  load = load,
}
