
---@alias IncludeOrExcludeInCompilationDef IncludeInCompilationDef|ExcludeInCompilationDef

---@class IncludeInCompilationDef : IncludeParams
---@field profile 'nil' @ no longer in the table
---@field type '"include"'

---@class ExcludeInCompilationDef : ExcludeParams
---@field profile 'nil' @ no longer in the table
---@field type '"exclude"'

---@alias IncludeOrExcludeCopyDef IncludeInCopyDef|ExcludeInCopyDef

---@class IncludeInCopyDef : IncludeCopyParams
---@field profile 'nil' @ no longer in the table
---@field type '"include"'

---@class ExcludeInCopyDef : ExcludeCopyParams
---@field profile 'nil' @ no longer in the table
---@field type '"exclude"'

---@alias IncludeOrExcludeDeleteDef IncludeInDeleteDef|ExcludeInDeleteDef

---@class IncludeInDeleteDef : IncludeDeleteParams
---@field profile 'nil' @ no longer in the table
---@field type '"include"'

---@class ExcludeInDeleteDef : ExcludeDeleteParams
---@field profile 'nil' @ no longer in the table
---@field type '"exclude"'

---@class PhobosProfile : NewProfileParams
---@field include_exclude_definitions IncludeOrExcludeInCompilationDef[]
---@field include_exclude_copy_definitions IncludeOrExcludeCopyDef[]
---@field include_exclude_delete_definitions IncludeOrExcludeDeleteDef[]

---@class Optimizations
---@field fold_const boolean
---@field fold_control_statements boolean
---@field tail_calls boolean



-- IMPORTANT: make sure to copy defaults and descriptions to IncludeInCompilationDef for the fields:
-- phobos_extension, lua_extension, use_load, inject_scripts, error_message_count

-- IMPORTANT: make sure to update doc/emmy_lua/phobos_profiles.lua when adding or removing mandatory fields.

---@class NewProfileParams
---**Mandatory**\
---Unique name of the profile.
---@field name string
---**Mandatory**\
---Root path all other output paths have to be relative to.
---
---If this is a relative path it will be **relative to the root_dir**.
---@field output_dir string
---**Mandatory**\
---Directory all temporary files specific for this profile will be stored in.\
---Used, for example, for future incremental builds (once compilation requires context from multiple files).
---
---If this is a relative path it will be relative to the
---**directory the build profile script entrypoint is in**.
---@field cache_dir string
---**Default:** `".pho"`\
---The file extension of Phobos files. Source files must have this extension.
---@field phobos_extension string
---**Default:** `".lua"`\
---The file extension of Lua files. Output files will have this extension.
---@field lua_extension string
---**Default:** `false`\
---Should `load()` be used in the generated output to load the bytecode
---instead of outputting raw bytecode files?
---@field use_load boolean
---**Default:** `{}`\
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
---**Default:** `{}` (so all optimizations set to "false")
---@field optimizations Optimizations
---**Default:** `8`\
---The amount of info/warn/error messages to print per file
---@field error_message_count integer
---**Default:** `false`\
---Monitors total memory allocated during the entire compilation process at the cost of ~10% longer
---compilation times. (Stops incremental GC. Runs full garbage collection whenever it exceeds
---4GB current memory usage. May overshoot by quite a bit.)
---@field measure_memory boolean
---**Default:** the directory the build profile script (entrypoint) is in.\
---Using `require()` or some other method to run other files does not change this default directory.\
---You can get the default directory using `get_current_root_dir()`.
---@field root_dir string
---**Default:** `nil`\
---A function that is ran before this profile is ran. It runs before absolutely anything happens.
---@field on_pre_profile_ran function
---**Default:** `nil`\
---A function that is ran after this profile is ran. It runs after absolutely everything happened.
---@field on_post_profile_ran function



-- You may notice that for the "include and exclude specific" bold texts the `:` is not bold.
-- That is because the sumneko.lua markdown renderer, which might also just be vscode's renderer,
-- just doesn't want to actually render it bold, but renders literal `**` instead.

---@class IncludeAndExcludeBase
---**Mandatory**\
---The profile to add this definition to.
---@field profile PhobosProfile
---**Default:** `1/0` (infinite)\
---Does nothing if `source_path` is a file.\
---How many directories and sub directories deep it should enumerate.\
---`0` means literally none, `1` means just the given directory, `2` means this directory
---and all it's sub directories, but not sub directories in sub directories, and so on.
---@field recursion_depth integer
---**Default:** `""` (matches everything)\
---Only files matching this Lua pattern will be excluded.\
---The paths matched against this pattern will...
---- be relative to `source_path`
---- have a leading `/` for convenience (so you can use `/` as an anchor for "the start of any entry")
---- use `/` as separators
---- include the file extension.
---
---**`include()` specific**:\
---Filtering for `phobos_extension` happens before this pattern gets applied.
---
---**`exclude()` and `exclude_copy()` specific**:\
---Note that excluding a file that isn't included is not a problem, it simply does nothing.
---
---If you're used to "file globs" here are respective equivalents:
---- `*` => `[^/]*` - Match a part of a filename or directory of undetermined length.
---- `/**/` => `/.*/` - Match any amount of directories.
---- `?` => `[^/]` - Match any single character within a filename or directory.
---
---For more details refer to the
---[Lua manual for string patterns](http://www.lua.org/manual/5.2/manual.html#6.4.1).
---@field filename_pattern string

---@class NonDeleteIncludeAndExcludeBase : IncludeAndExcludeBase
---**Mandatory**\
---Can be a path to a file or directory.
---
---**`include()` specific**:\
---If this is a file its extension must be the same as `lua_extension`.\
---
---If this is a relative path it will be relative to the
---**directory the build profile script entrypoint is in**.
---@field source_path string

---@class DeleteIncludeAndExcludeBase : IncludeAndExcludeBase
---**Mandatory**\
---Can be a path to a file or directory.
---
---Attempting to delete a file that is going to be
---outputted to through compilation or copying has no effect.
---It is going to be overwritten anyway.
---
---Must be a relative path, will be relative to the **profile's `output_dir`**
---@field output_path string



---@class IncludeParams : NonDeleteIncludeAndExcludeBase
---**Mandatory**\
---Must be a path to a file or directory, whichever `source_path` is using.\
---If this is a file its extension must be the same as `phobos_extension`.
---
---Must be a relative path, will be relative to the **profile's `output_dir`**
---@field output_path string
---**Mandatory**\
---This defines the `source` property of generated bytecode.\
---This property is used by debuggers to figure out where the source code is located, commonly relative
---to the root of your workspace or the specific project if a project root has identifying properties.
---
---Since we are compiling files here this **must** start with the symbol `@` -
---to tell Lua that the source is in a file - followed by the filename, defined as follows:
---
---If `source_path` is a directory this must be a "pattern" where the symbol `?` is representative of
---the file path relative to `source_path` (using `/` as separators and containing the file extension).
---
---If `source_path` is a file this must the filename, not containing any `?`, which will be used as-is.
---@field source_name string
---**Default:** `profile.phobos_extension` (its default is `".pho"`)\
---The file extension of Phobos files. Source files must have this extension.
---@field phobos_extension string
---**Default:** `profile.lua_extension` (its default is `".lua"`)\
---The file extension of Lua files. Output files will have this extension.
---@field lua_extension string
---**Default:** `profile.use_load` (its default is `false`)\
---Should `load()` be used in the generated output to load the bytecode
---instead of outputting raw bytecode files?
---@field use_load boolean
---**Default:** `profile.error_message_count` (its default is `8`)\
---The amount of info/warn/error messages to print per file
---@field error_message_count integer
---**Default:** `profile.inject_scripts` (its default is `{}`)\
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

---@class ExcludeParams : NonDeleteIncludeAndExcludeBase



---@class IncludeCopyParams : NonDeleteIncludeAndExcludeBase
---**Mandatory**\
---Must be a path to a file or directory, whichever `source_path` is using.
---
---Must be a relative path, will be relative to the **profile's `output_dir`**
---@field output_path string

---@class ExcludeCopyParams : NonDeleteIncludeAndExcludeBase
---**Default:** `false`\
---Should this only exclude the latest included file when a given file was
---included multiple times with different output paths?
---@field pop boolean



---@class IncludeDeleteParams : DeleteIncludeAndExcludeBase

---@class ExcludeDeleteParams : DeleteIncludeAndExcludeBase
