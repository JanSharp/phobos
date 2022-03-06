
---@class PhobosProfiles
local phobos_profiles = {}

---@param params NewProfileParams
---@return PhobosProfile
function phobos_profiles.add_profile(params) end

---@param params IncludeParams
function phobos_profiles.include(params) end

---@param params ExcludeParams
function phobos_profiles.exclude(params) end

---@param params IncludeCopyParams
function phobos_profiles.include_copy(params) end

---@param params ExcludeCopyParams
function phobos_profiles.exclude_copy(params) end

---get the directory which is the current default for `profile.root_dir`.\
---it is the the directory the build profile script (entrypoint) is in.\
---using `require()` or some other method to run other files does not change this directory.\
---this dir is fully qualified and does not have a trailing `/`
---@return string
function phobos_profiles.get_current_root_dir() end

---get a new table with all optimizations set to `true`
---@return Optimizations
function phobos_profiles.get_all_optimizations() end

return phobos_profiles
