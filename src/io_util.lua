
---@type LFS
local lfs = require("lfs")
local Path = require("lib.path")
local shell_util = require("shell_util")
local util = require("util")

local function mkdir_recursive(path)
  path = Path.new(path)

  -- i thought for sure you could just mkdir multiple dir levels at once... but i guess not?
  for i = 1, #path do
    if not path:sub(1, i):exists() then
      -- this might fail, for example for drive letters,
      -- but that doesn't matter, as long as the output file
      -- can get created (=> asserted)
      util.debug_assert(lfs.mkdir(path:sub(1, i):str()))
    end
  end
end

---There has to be a better way to delete directories that are not empty, right?
local function rmdir_recursive(path)
  path = Path.new(path)
  ---cSpell:ignore readdir, findfirst, findnext
  -- I figured out that lfs is using `readdir` on Unix systems and `_findfirst` and `_findnext` on windows:
  -- https://www.ibm.com/docs/en/zos/2.3.0?topic=functions-readdir-read-entry-from-directory
  -- https://docs.microsoft.com/en-us/cpp/c-runtime-library/reference/findfirst-functions?view=msvc-170
  -- `readdir` suggests that it might work just fine when the directory got modified while iterating,
  -- but it's not clear.
  -- the remarks for `_findfirst` and `_findnext` say nothing about how it behaves when the directory
  -- got modified during iteration, which means I'm just going to assume that it is undefined behavior.
  -- So that is why I'm putting stuff in tables and then deleting afterwards
  local dirs = {}
  local files = {}
  for entry in path:enumerate() do
    -- since symlinkattributes is the same as attributes on windows this will actually delete
    -- all files in symlinked directories, while on Unix this will only delete the symlink.
    -- that is if os.remove can actually delete symlinks, who knows
    if (path / entry):sym_attr("mode") == "directory" then
      dirs[#dirs+1] = path / entry
    else
      files[#files+1] = path / entry
    end
  end
  for _, dir_path in ipairs(dirs) do
    rmdir_recursive(dir_path)
  end
  for _, file_path in ipairs(files) do
    util.debug_assert(os.remove(file_path:str()))
  end
  util.debug_assert(lfs.rmdir(path:str()))
end

---cSpell:ignore fopen

-- Notice how both read_file and write_file are always using "binary" mode, never "text" mode.
-- First of all lets explain what those modes mean. On anything but windows they mean nothing.
-- https://docs.microsoft.com/en-us/cpp/c-runtime-library/text-and-binary-mode-file-i-o?view=msvc-170
-- https://docs.microsoft.com/en-us/cpp/c-runtime-library/reference/fopen-wfopen?view=msvc-170
-- on the fopen page, which is the function `io.open` uses in Lua, it mentions
-- "translations involving carriage-return and line feed characters are suppressed."
-- which is about as much as I managed to find out about binary vs text mode. Going by how it is phrased it
-- might very well be the only thing it means.
-- Binary mode just reads and writes files as is, which is what every other system does even in "text" mode.
--
-- Now that we have clarified what binary and text mode really mean, why does Phobos always use binary mode?
-- Imagine you compile something using Phobos using the "use load" feature, which means the output is text,
-- technically speaking. However this "text" file just consists of a small wrapper around one big string
-- which contains the actual bytecode. This bytecode is formatted using string.format with the %q pattern.
-- This can result in newlines within the bytecode-string. Then imagine loading and running this file on any
-- system that isn't windows. The file gets read in binary mode, since that's the only thing that exists on
-- that system, which means '\r\n' end up being read as-is, which then means Lua has to detect and handle them
-- correctly as a single newline. Luckily Lua does this, which means this won't be a problem (and I cannot
-- think of an edge case where it would actually cause problems) however look at the size of this comment
-- just to explain one scenario caused by text vs binary mode. Then also consider the fact that whenever we
-- write files have to manually tell it to use binary mode when writing bytecode files, because Lua
-- won't give '\r\n' special treatment in that case (it explicitly switches to binary mode when reading
-- bytecode files), and tell it to use text mode when writing "text" files.
-- It's added complexity which can only ever cause more problems and it doesn't solve any problems.
--
-- The _only time_ using text mode is reasonable is when _writing_ pure code files, for example when
-- formatting code. That's it. Because those files will be read and edited by programmers, which most likely
-- want their line endings to be whatever their system uses... Though I myself found myself wanting '\n' even
-- in windows, but I digress.
--
-- Oh btw, Phobos also handles '\r\n', '\r', '\n' and even '\n\r' just like Lua does, and its output will
-- always purely use '\n'.

local function read_file(path)
  path = Path.new(path)

  -- see above comment for explanation for using binary mode
  local file = util.debug_assert(io.open(path:str(), "rb"))
  local contents = file:read("*a")
  util.debug_assert(file:close())

  return contents
end

local function write_file(path, contents)
  path = Path.new(path)

  mkdir_recursive(path:sub(1, -2))

  -- see above comment for explanation for using binary mode
  local file = assert(io.open(path:str(), "wb"))
  assert(file:write(contents))
  assert(file:close())
end

if not os.execute() then
  util.abort("Phobos requires a shell to be available (by/from the operating system) \z
    in order to copy files."
  )
end

local function execute_copy(command, from_arg, to_arg)
  local success, exit_code, code = os.execute(command)
  if not success then
    util.abort("Failed to copy file from "..from_arg.." to "..to_arg..". There might be an \z
      error message printed above (to stderr or stdout on non windows, just stderr on windows, \z
      because stdout is redirected to NUL). Aside from that, here is the exit code: '"
      ..exit_code.."' and code: '"..code.."' returned by 'os.execute' when executing the command: "
      ..command
    )
  end
end

local function copy(from, to)
  from = Path.new(from)
  to = Path.new(to)

  -- i'm not even sure if this is needed now that we're using os specific commands,
  -- but I don't feel like testing it right now.
  mkdir_recursive(to:sub(1, -2))

  -- have to use \ as the separator on windows because / is only supported by the windows api,
  -- not by cmd.exe or batch commands
  local from_arg = shell_util.escape_arg(from:str("\\"))
  local to_arg = shell_util.escape_arg(to:str("\\"))
  if Path.is_windows() then
    ---CSpell:ignore Xcopy
    -- https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/xcopy
    -- /q make it quiet, /k copy read only state, /r copy read only files, /h copy hidden files
    -- /y to overwrite without confirmation
    -- using /x or /o (see link above for what they do) apparently requires admin rights,
    -- according to one stack overflow thread I found. But luckily we don't need those to copy
    -- UNIX file permissions, which is all I was going for.
    -- >NUL to make it silent, because /q apparently doesn't actually make it quiet
    execute_copy("Xcopy "..from_arg.." "..to_arg.." /q /k /r /h /y >NUL", from_arg, to_arg)
    -- xcopy is prompting if the destination is a file or directory, and there is no way to
    -- tell it beforehand that it's a file from what I can tell/found online. I mean there has
    -- to be a way, otherwise that makes no sense at all, but like I said, couldn't figure out how.

    -- here's a functional version using 'copy' instead of 'xcopy', but 'copy' does not
    -- appear to copy UNIX file permissions, which means I can't use it, even though 'copy' is
    -- made specifically to copy files while 'xcopy' is for files and directories. So be it, i guess.
    -- https://docs.microsoft.com/en-us/windows-server/administration/windows-commands/copy
    -- /y to overwrite without confirmation, /b because I want a binary copy... what the heck even
    -- is an ASCII copy? I don't even want to know.
    -- >NUL to redirect standard output to make it silent.
    -- execute_copy("copy /y "..from_arg.." "..to_arg.." /b >NUL", from_arg, to_arg)
  else
    ---cSpell:ignore xattr
    -- -p  same as --preserve=mode,ownership,timestamps
    --
    -- --preserve[=ATTR_LIST]
    --     preserve the specified attributes (default: mode,ownership,timestamps),
    --     if possible additional attributes: context, links, xattr, all
    --
    -- '\' prefix to prevent 'cp' from being resolved as an alias,
    -- because apparently cp='cp -i' is a common alias,
    -- but we don't want interactive mode, we want to silently overwrite.
    execute_copy("\\cp -p "..from_arg.." "..to_arg, from_arg, to_arg)
  end
end

local function move(from, to)
  from = Path.new(from)
  to = Path.new(to)

  copy(from, to)

  util.debug_assert(os.remove(from:str()))
end

local function symlink(old, new)
  old = Path.new(old)
  new = Path.new(new)

  util.debug_assert(lfs.link(old:str(), new:str(), true))
end

local function exists(path)
  return Path.new(path):exists()
end

local function enumerate(path)
  return Path.new(path):enumerate()
end

local function set_working_dir(path)
  util.debug_assert(lfs.chdir(path))
end

local function get_working_dir()
  local path = util.debug_assert(lfs.currentdir())
  if Path.is_windows() then
    path = path:gsub("\\", "/")
  end
  return path
end

local function get_working_dir_path()
  local path = util.debug_assert(lfs.currentdir())
  if Path.is_windows() then
    path = path:gsub("\\", "/")
  end
  return Path.new(path)
end

local function get_modification(path)
  path = Path.new(path)
  return util.debug_assert(path:attr("modification"))
end

return {
  mkdir_recursive = mkdir_recursive,
  rmdir_recursive = rmdir_recursive,
  read_file = read_file,
  write_file = write_file,
  copy = copy,
  move = move,
  symlink = symlink,
  exists = exists,
  enumerate = enumerate,
  set_working_dir = set_working_dir,
  get_working_dir = get_working_dir,
  get_working_dir_path = get_working_dir_path,
  get_modification = get_modification,
}
