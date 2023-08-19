
-- A tiny script usable with the phobos_dev launch_scripts to run a file at an absolute path, since the
-- phobos_dev scripts require it to be a path relative to the root of the phobos project.
-- I'm doing this instead of changing the dev scripts because trying to figure out how to change this in a
-- MSDos batch script just does not interest me whatsoever.

local args = {...}
local main_chunk = assert(loadfile(args[1], "bt"))
main_chunk(table.unpack(args, 2))
