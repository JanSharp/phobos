
---@diagnostic disable

---@class PhobosProfiles
local phobos_profiles = {}

---Mandatory fields: `name`, `output_dir`, `cache_dir`.
---@param params NewProfileParams
---@return PhobosProfile
function phobos_profiles.add_profile(params) end

---Mandatory fields: `profile`, `source_path`, `source_name`, `output_path`.
---@param params IncludeParams
function phobos_profiles.include(params) end

---Mandatory fields: `profile`, `source_path`.
---@param params ExcludeParams
function phobos_profiles.exclude(params) end

---Mandatory fields: `profile`, `source_path`, `output_path`.
---@param params IncludeCopyParams
function phobos_profiles.include_copy(params) end

---Mandatory fields: `profile`, `source_path`.
---@param params ExcludeCopyParams
function phobos_profiles.exclude_copy(params) end

---Mandatory fields: `profile`, `output_path`.
---@param params IncludeDeleteParams
function phobos_profiles.include_delete(params) end

---Mandatory fields: `profile`, `output_path`.
---@param params ExcludeDeleteParams
function phobos_profiles.exclude_delete(params) end

---Get the directory which is the current default for `profile.root_dir`.\
---It is the the directory the build profile script (entrypoint) is in.\
---Using `require()` or some other method to run other files does not change this directory.\
---This dir is fully qualified and does not have a trailing `/`.
---@return string
function phobos_profiles.get_current_root_dir() end

---Get a new table with all optimizations set to `true`.
---@return Optimizations
function phobos_profiles.get_all_optimizations() end

---Parse the extra args according to a defined config and get the resulting table if the args are valid.
---@param extra_args string[] @ The phobos profiles file gets the extra args passed in as vararg (`...`), so you would probably want to pass in `{...}`.
---@param config ArgsConfig @ Uses [LuaArgParser](https://github.com/JanSharp/LuaArgParser). Definitions are currently not validated so invalid ones will cause crashes.
---@return table @ Never `nil` and never has the `help` flag set, because the program aborts in those cases.
function phobos_profiles.parse_extra_args(extra_args, config) end

---Parse the extra args using a custom function.
---@param extra_args string[] @ The phobos profiles file gets the extra args passed in as vararg (`...`). These will be passed along to the custom parse function
---@param custom_parse_function fun(extra_args: string[]): any|nil, nil|string, nil|string @
---This function is expected to parse the arguments, returning any value that isn't `nil` on success.\
---On failure however, it is expected to return `nil` plus an optional `string` as a second return value
---to describe the error and an optional `string` as a third return value as a help message for the expected
---extra args - the help message, essentially.
---
---If all you wish to do is print a help message, then do `return nil, nil, "<help message>"`.
---
---This function should not intentionally throw an `error` nor use `os.exit` to indicate invalid args.
---Use `pcall` to wrap functions that could call `error` or `assert` if you do do not have control over
---those functions (for example when using some library).\
---If the intention is to indicate a crash then it's fine.
function phobos_profiles.custom_parse_extra_args(extra_args, custom_parse_function) end

-- TODO: copy ArgsConfigOption, ArgsConfigPositional and ArgsConfig to the docs output programmatically

return phobos_profiles
