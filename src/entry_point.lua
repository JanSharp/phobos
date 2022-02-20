
-- get the first line from package.config
local path_sep = package.config:match("^([^\n]*)")
-- get the second line from package.config
local template_sep = package.config:match("^[^\n]*\n([^\n]*)")
-- get the third line from package.config
local substitution = package.config:match("^[^\n]*\n[^\n]*\n([^\n]*)")

-- I just prefer this over `arg`
local args = {...}

-- first arg is the root directory for all phobos files
local root = args[1]
-- second arg is the root directory for c libraries (lfs)
local c_lib_root = args[2]
-- third arg is the file extension for c libraries
local c_lib_extension = args[3]
-- fourth arg is the file to load and run with the rest of the args
local main_filename = args[4]

package.path = table.concat({
  root..path_sep..substitution..".lua",
  package.path ~= "" and package.path or nil,
}, template_sep)
package.cpath = table.concat({
  c_lib_root..path_sep..substitution..c_lib_extension,
  package.cpath ~= "" and package.cpath or nil,
}, template_sep)

local main_chunk = assert(loadfile(main_filename, "bt"))
main_chunk(table.unpack(args, 5))
