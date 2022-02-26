
local profile_util = {
  current_root_directory = nil,
}

---@alias ProfileType
---| '"build"'

---@alias ProfilePath ProfileIncludePath|ProfileExcludePath

---@class ProfileIncludePath
---@field type '"include"'
---@field source_dir string
---@field output_dir string
---@field recursive boolean
---@field source_name string
---@field phobos_extension string
---@field lua_extension string
---@field use_load boolean
---@field inject_scripts fun(ast:AstFunctionDef)[]

---@class ProfileExcludePath
---@field type '"exclude"'
---@field path string
---@field recursive boolean

---@class Profile
---@field name string
---@field profile_type ProfileType
---@field output_dir string
---@field temp_dir string
---@field phobos_extension string
---@field lua_extension string
---@field use_load boolean
---@field inject_scripts fun(ast:AstFunctionDef)[]
---@field paths ProfilePath[]
---@field root_directory string


local profiles = {}
local profiles_by_name = {}
profile_util.profiles = profiles
profile_util.profiles_by_name = profiles_by_name

---@param profile Profile
function profile_util.add_profile(profile)
  assert(profile.name, "Missing profile name.")
  assert(not profiles_by_name[profile.name], "Attempt to add 2 profiles with the name '"..profile.name.."'.")
  profiles_by_name[profile.name] = profile
  profiles[#profiles+1] = profile
end

---All fields are mandatory
---@class NewProfileParams
---**mandatory**\
---unique name of the profile
---@field name string
---**mandatory**\
---@field profile_type ProfileType
---**mandatory**\
---root path all other output paths have to be relative to\
---if this is a relative path it will be relative to the **directory the build profile script entrypoint is in**
---@field output_dir string
---**mandatory**\
---directory all temporary files specific for this profile will be stored in\
---used, for example, for incremental builds (which are currently not implemented)\
---if this is a relative path it will be relative to the **directory the build profile script entrypoint is in**
---@field temp_dir string
---**default:** `".pho"`
---@field phobos_extension string
---**default:** `".lua"`
---@field lua_extension string
---**default:** `false`
---@field use_load boolean
---**default:** `{}`
---@field inject_scripts string[]
---**default:** `false`\
---should this profile immediately be added to the list of registered profiles?
---@field add boolean

---@param params NewProfileParams
---@return Profile
function profile_util.new_profile(params)
  local profile = {
    name = params.name,
    profile_type = params.profile_type,
    output_dir = params.output_dir,
    temp_dir = params.temp_dir,
    phobos_extension = params.phobos_extension or ".pho",
    lua_extension = params.lua_extension or ".lua",
    use_load = params.use_load or false,
    inject_scripts = params.inject_scripts or {},
    paths = {},
    root_directory = profile_util.current_root_directory,
  }
  if params.add then
    profile_util.add_profile(profile)
  end
  return profile
end

---@class IncludeParams
---@field profile Profile
---must be a path to a directory\
---if this is a relative path it will be relative to the **directory the build profile script entrypoint is in**
---@field source_dir string
---must be a path to a directory\
---must be a relative path, will be relative to the **profile's output_dir**
---@field output_dir string
---**default:** `true`\
---should all sub directories also be included?
---@field recursive boolean
---@field source_name string
---**default:** `profile.phobos_extension`
---@field phobos_extension string
---**default:** `profile.lua_extension`
---@field lua_extension string
---**default:** `profile.use_load`
---@field use_load boolean
---**default:** `profile.inject_scripts`
---@field inject_scripts string[]

---@param params IncludeParams
function profile_util.include(params)
  params.profile.paths[#params.profile.paths+1] = {
    type = "include",
    source_dir = params.source_dir,
    output_dir = params.output_dir,
    recursive = params.recursive == nil and true or params.recursive,
    source_name = params.source_name,
    phobos_extension = params.phobos_extension or params.profile.phobos_extension,
    lua_extension = params.lua_extension or params.profile.lua_extension,
    use_load = params.use_load or params.profile.use_load,
    inject_scripts = params.inject_scripts or params.profile.inject_scripts,
  }
end

---@class ExcludeParams
---@field profile Profile
---can be a path to a directory or a file\
---if this is a relative path it will be relative to the **directory the build profile script entrypoint is in**
---@field path string
---**default:** `true`
---@field recursive boolean

---@param params ExcludeParams
function profile_util.exclude(params)
  params.profile.paths[#params.profile.paths+1] = {
    type = "exclude",
    path = params.path,
    recursive = params.recursive == nil and true or params.recursive,
  }
end

-- TODO: compiler options
-- TODO: optimizer options
-- TODO: ignore syntax errors (based on error codes?)
-- TODO: ignore warnings (based on warning codes?)
-- TODO: actually errors, warnings and infos should all be the same thing just with different severities
-- TODO: monitor memory

return profile_util
