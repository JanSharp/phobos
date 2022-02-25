
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")

local function mkdir_recursive(path)
  path = Path.new(path)

  -- i thought for sure you could just mkdir multiple dir levels at once... but i guess not?
  for i = 1, #path do
    if not path:sub(1, i):exists() then
      -- this might fail, for example for drive letters,
      -- but that doesn't matter, as long as the output file
      -- can get created (=> asserted)
      lfs.mkdir(path:sub(1, i):str())
    end
  end
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
  local file = assert(io.open(path:str(), "rb"))
  local contents = file:read("*a")
  assert(file:close())

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

local function copy(from, to)
  from = Path.new(from)
  to = Path.new(to)

  mkdir_recursive(to:sub(1, -2))

  local contents = read_file(from)
  write_file(to, contents)
end

local function move(from, to)
  from = Path.new(from)
  to = Path.new(to)

  copy(from, to)

  os.remove(from:str())
end

return {
  mkdir_recursive = mkdir_recursive,
  read_file = read_file,
  write_file = write_file,
  copy = copy,
  move = move,
}
