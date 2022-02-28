
local profile_util = {
  internal = {
    current_root_dir = nil,
  },
}

---@alias FileCollectionDefinition FileCollectionIncludeDef|FileCollectionExcludeDef

---@class FileCollectionIncludeDef : IncludeParams
---@field type '"include"'

---@class FileCollectionExcludeDef : ExcludeParams
---@field type '"exclude"'

---@class Profile : AddProfileParams
---@field file_collection_defs FileCollectionDefinition[]

---@class Optimizations
---@field fold_const boolean
---@field fold_control_statements boolean
---@field tail_calls boolean


local profiles = {}
local profiles_by_name = {}
profile_util.profiles = profiles
profile_util.profiles_by_name = profiles_by_name

-- IMPORTANT: make sure to copy defaults and descriptions to FileCollectionIncludeDef for the fields:
-- phobos_extension, lua_extension, use_load, inject_scripts

---mandatory fields: `name`, `output_dir`, `temp_dir`
---@class AddProfileParams
---**mandatory**\
---Unique name of the profile.
---@field name string
---**mandatory**\
---Root path all other output paths have to be relative to.\
---\
---If this is a relative path it will be **relative to the root_dir**.
---@field output_dir string
---**mandatory**\
---Directory all temporary files specific for this profile will be stored in.\
---Used, for example, for future incremental builds (once compilation requires context from multiple files).\
---\
---If this is a relative path it will be relative to the
---**directory the build profile script entrypoint is in**.
---@field temp_dir string
---**default:** `".pho"`\
---The file extension of Phobos files. Source files must have this extension.
---@field phobos_extension string
---**default:** `".lua"`\
---The file extension of Lua files. Output files will have this extension.
---@field lua_extension string
---**default:** `false`\
---Should `load()` be used in the generated output to load the bytecode
---instead of outputting raw bytecode files?
---@field use_load boolean
---**default:** `true`\
---Should only files with a newer modification time get compiled?
---@field incremental boolean
---**default:** `{}`\
---Filenames of files to run which modify the AST of every compiled file.
---The extension of these files is ignored; They will load as bytecode if they are bytecode files,
---otherwise Phobos will compile them just in time with purely default settings, no optimizations.\
---These files must return a function taking a single argument which will be the AST of whichever
---file is currently being compiled.\
---If multiple are provided they will be run in the order they are defined in.\
---These files will be run before any optimizations.\
---These files may `require` any Phobos file, such as the 'ast_walker' or 'nodes' for example.\
---**NOTE:** This feature is far from complete.\
---if there are relative paths they will be **relative to the root_dir**
---@field inject_scripts string[]
---**default:** `{}` (so all optimizations set to "false")
---@field optimizations Optimizations
---**default:** the directory the build profile script (entrypoint) is in.\
---Using `require()` or some other method to run other files does not change this default directory.\
---You can get the default directory using `get_current_root_dir()`.
---@field root_dir string
---**default:** `false`\
---Should this profile immediately be added to the list of registered profiles?
---@field add_profile boolean

---@param params AddProfileParams
---@return Profile
function profile_util.add_profile(params)
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
    root_dir = params.root_dir or profile_util.internal.current_root_dir,
    file_collection_defs = {},
  }
  -- add the profile
  assert(profile.name, "Missing profile name.")
  assert(not profiles_by_name[profile.name], "Attempt to add 2 profiles with the name '"..profile.name.."'.")
  profiles_by_name[profile.name] = profile
  profiles[#profiles+1] = profile
  return profile
end

---@class IncludeParams
---**mandatory**\
---The profile to add this definition to.
---@field profile Profile
---**mandatory**\
---Must be a path to a directory.\
---\
---If this is a relative path it will be relative to the
---**directory the build profile script entrypoint is in**.
---@field source_dir string
---**mandatory**\
---must be a path to a directory\
---must be a relative path, will be relative to the **profile's `output_dir`**
---@field output_dir string
---**mandatory**\
---@field source_name string
---**default:** `1/0` (infinite)\
---How many directories and sub directories deep it should include.\
---`0` means literally none, `1` means just the given directory, `2` means this directory
---and all it's sub directories, but not sub directories in sub directories, and so on.
---@field recursion_depth integer
---**default:** `profile.phobos_extension` (it's default is `".pho"`)\
---The file extension of Phobos files. Source files must have this extension.
---@field phobos_extension string
---**default:** `profile.lua_extension` (it's default is `".lua"`)\
---The file extension of Lua files. Output files will have this extension.
---@field lua_extension string
---**default:** `profile.use_load` (it's default is `false`)\
---Should `load()` be used in the generated output to load the bytecode
---instead of outputting raw bytecode files?
---@field use_load boolean
---**default:** `profile.inject_scripts` (it's default is `{}`)\
---Filenames of files to run which modify the AST of every compiled file.
---The extension of these files is ignored; They will load as bytecode if they are bytecode files,
---otherwise Phobos will compile them just in time with purely default settings, no optimizations.\
---These files must return a function taking a single argument which will be the AST of whichever
---file is currently being compiled.\
---If multiple are provided they will be run in the order they are defined in.\
---These files will be run before any optimizations.\
---These files may `require` any Phobos file, such as the 'ast_walker' or 'nodes' for example.\
---**NOTE:** This feature is far from complete.\
---if there are relative paths they will be **relative to the root_dir**
---@field inject_scripts string[]

---@param params IncludeParams
function profile_util.include(params)
  params.profile.file_collection_defs[#params.profile.file_collection_defs+1] = {
    type = "include",
    source_dir = params.source_dir,
    output_dir = params.output_dir,
    recursion_depth = params.recursion_depth or (1/0),
    source_name = params.source_name,
    phobos_extension = params.phobos_extension or params.profile.phobos_extension,
    lua_extension = params.lua_extension or params.profile.lua_extension,
    use_load = params.use_load or params.profile.use_load,
    inject_scripts = params.inject_scripts or params.profile.inject_scripts,
  }
end

---@class ExcludeParams
---@field profile Profile
---Can be a path to a directory or a file.\
---\
---If this is a relative path it will be relative to the
---**directory the build profile script entrypoint is in**.
---@field path string
---**default:** `1/0` (infinite)\
---Does nothing if `path` is a file.\
---How many directories and sub directories deep it should exclude.\
---`0` means literally none, `1` means just the given directory, `2` means this directory
---and all it's sub directories, but not sub directories in sub directories, and so on.
---@field recursion_depth integer

---@param params ExcludeParams
function profile_util.exclude(params)
  params.profile.file_collection_defs[#params.profile.file_collection_defs+1] = {
    type = "exclude",
    path = params.path,
    recursion_depth = params.recursion_depth or (1/0),
  }
end

---get the directory which is the current default for `profile.root_dir`.\
---it is the the directory the build profile script (entrypoint) is in.\
---using `require()` or some other method to run other files does not change this directory.\
---this dir is fully qualified and does not have a trailing `/`
---@return string
function profile_util.get_current_root_dir()
  return profile_util.internal.current_root_dir
end

---get a new table with all optimizations set to `true`
---@return Optimizations
function profile_util.get_all_optimizations()
  return {
    fold_const = true,
    fold_control_statements = true,
    tail_calls = true,
  }
end

-- TODO: patterns for paths in include and exclude
-- TODO: ignore syntax errors (based on error codes?)
-- TODO: ignore warnings (based on warning codes?)
-- TODO: actually errors, warnings and infos should all be the same thing just with different severities
-- TODO: monitor memory

return profile_util
