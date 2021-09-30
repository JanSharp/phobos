
---@type LFS
local lfs = require("lfs")

local function escape_arg(arg)
  return '"'..arg:gsub("[$`\"\\]", "\\%0")..'"'
end

local function run(...)
  local pipe = assert(io.popen(table.concat({...}, " "), "r"))
  local result = {}
  for line in pipe:read("*a"):gmatch("[^\n]*\n") do
    result[#result+1] = line
  end
  pipe:close()
  return result
end

local function git(...)
  return run("git", ...)
end

local function gh(...)
  return run("gh", ...)
end

local foo = git("status", "--porcelain", "-b")
assert((foo[1]:find("^## master%.%.%.")))
local bar = gh()
local b

-- ensure git, gh (github cli) and 7z (7-zip) are available
-- ensure git is clean and on master
-- run all tests (currently testing is very crude, so just `tests/compile_test.lua`)
-- compile src to `out/release`
-- set the date for the latest changelog entry
-- extract the latest changelog entry into a file (for the github release)
--   also remember what version the latest is
-- create `phobos_{os}_{version}.zip`
--   add entries to all 3 zip
--     all files from `out/release`
--     readme.md
--     phobos_debug_symbols.md
--     changelog.txt
--     LICENSE.txt
--     LICENSE_THIRD_PARTY.txt
-- compile src to `temp/publish/factorio` (actually this will be done differently)
--   ignoring some files and dirs:
--     src/main.lua
--     src/lib/LFSClasses
--     src/lib/LuaArgParser
--     src/lib/LuaPath
--   also add an extra AST transformation to change all requires to include the `__phobos__.` prefix
--     (this is currently not possible)
-- create `phobos_{version}.zip` (for factorio)
--   add files (in a `phobos` sub dir)
--     info.json
--     all files from `temp/publish/factorio`
--     readme.md
--     changelog.txt
--     LICENSE.txt
--     LICENSE_THIRD_PARTY.txt (technically inaccurate but whatever?)
-- `gh release create ...`
--   with the 4 zips as files
--   with the previously evaluated version as the tag (format: `v{version}`)
--   with a title (same as the tag? probably)
--   with notes-file
-- using the factorio mod debug vscode extension publish the factorio mod to the mod portal
--   that won't be part of the script though. This script can be setup as the pre task
--   for the upload task in vscode though... i think. otherwise doing that part manually would work, i guess
