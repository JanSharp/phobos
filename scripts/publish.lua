
---@type LFS
local lfs = require("lfs")
local Path = require("lib.LuaPath.path")
Path.use_forward_slash_as_main_separator_on_windows()
local arg_parser = require("lib.LuaArgParser.arg_parser")
local io_util = require("io_util")
local changelog_util = require("scripts.changelog_util")

local skip_able = {
  "skip_ensure_command_availability",
  "skip_ensure_clean_working_tree",
  "skip_tests",
  "skip_build",
  "skip_date_stamp_changelog",
  "skip_cleanup_temp_dir",
  "skip_package",
  "skip_preparation_commit",
  "skip_github_release",
  "skip_increment_version",
  "skip_increment_commit",
}

local args = arg_parser.parse_and_print_on_error_or_help({...}, {
  options = {
    {
      field = "verbose",
      long = "verbose",
      short = "v",
      description = "print all commands (io.popen) that get run,\n\z
        print changes of the working directory\n\z
        and use verbose flag when building.\n\z
        Verbose prints are indented by 2 spaces, except those from building.",
      flag = true,
    },
    (function()
      local result = {}
      for i, name in ipairs(skip_able) do
        result[i] = {
          field = name,
          long = string.gsub(name, "_", "-"),
          ---cSpell:disable-next-line
          short = string.sub("abcdefgijklmnopqrstuwxyz", i, i), -- no h, v
          flag = true,
        }
      end
      return table.unpack(result)
    end)(),
  },
})
if not args then return end

local function escape_arg(arg)
  return '"'..arg:gsub("[$`\"\\]", "\\%0")..'"'
end

local function run(...)
  local command = table.concat({...}, " ")
  if args.verbose then
    print("  "..command)
  end
  local pipe = assert(io.popen(command, "r"))
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

local function seven_zip(...)
  return run("7z", ...)
end

local main_branch = "master"

-- ensure git, gh (github cli) and 7z (7-zip) are available
if not args.skip_ensure_command_availability then
  print("Ensuring 'git', 'gh' and '7z' are available")
  local missing_commands = {}
  local function ensure_command_is_available(command, name, arg)
    if not os.execute(command..(arg and " "..arg or "")) then
      missing_commands[#missing_commands+1] = "'"..command.."' ("..name..")"
    end
  end
  ensure_command_is_available("git", "git", "status -s")
  ensure_command_is_available("gh", "github cli")
  ensure_command_is_available("7z", "7-zip")
  if missing_commands[1] then
    error("Missing programs "..table.concat(missing_commands, ", "))
  end
end

-- ensure git is clean and on master
print("Checking git status")
local foo = git("status", "--porcelain", "-b")
if not foo[1]:find("^## "..main_branch.."%.%.%.") then
  error("git must be on branch "..main_branch..".")
end
if not args.skip_ensure_clean_working_tree and foo[2] then
  error("git working tree must be clean")
end

-- run all tests (currently testing is very crude, so just `tests/compile_test.lua`)
if not args.skip_tests then
  print("Running tests")
  local success, err = pcall(loadfile("tests/compile_test.lua"), table.unpack{
    "--test-disassembler",
    "--ensure-clean",
    "--test-formatter",
  })
  if not success then
    print(err)
    print()
    error("Tests failed")
  end
end

if not args.skip_build then
  -- compile src to `out/src/release`
  print("Building src")
  loadfile("scripts/build_src.lua")(table.unpack{
    "--profile", "release",
    args.verbose and "--verbose" or nil,
  })

  -- compile src to `out/factorio/release/phobos`
  print("Building Factorio Mod")
  loadfile("scripts/build_factorio_mod.lua")(table.unpack{
    "--profile", "release",
    "--include-src-in-source-name",
    args.verbose and "--verbose" or nil,
  })
end

-- get version from info.json
print("Reading info.json")
local info_json
do
  local file = assert(io.open("info.json", "r"))
  info_json = file:read("*a")
  assert(file:close())
end
local info_json_version_pattern = "(\"version\"%s*:%s*\")(%d+%.%d+%.%d+)\""
local version_str = select(2, info_json:match(info_json_version_pattern))
if not version_str then
  error("Unable to get version from info.json")
end
local version = changelog_util.parse_version(version_str)
if version_str ~= changelog_util.print_version(version) then
  error("Version "..version_str.." has leading 0s. It should be "..changelog_util.print_version(version))
end

-- get version_block from changelog.txt for that version
print("Extracting version block for version "..version_str.." from changelog.txt")
local changelog
do
  local file = assert(io.open("changelog.txt"))
  changelog = changelog_util.decode(file:read("*a"))
  assert(file:close())
end
local current_version_block
for _, version_block in ipairs(changelog) do
  if changelog_util.compare_version(version_block.version, version) then
    current_version_block = version_block
    break
  end
end
if not current_version_block then
  error("Could not find a version block for version "..version_str.." in changelog.txt")
end

-- date stamp that version block
if not args.skip_date_stamp_changelog then
  local date = os.date("!%Y-%m-%d")
  print("Setting date for version block for version "..version_str.." to "..date.." in changelog.txt")
  current_version_block.date = date
  local file = assert(io.open("changelog.txt", "w"))
  assert(file:write(changelog_util.encode(changelog)))
  assert(file:close())
end

-- prepare temp dir
print("Creating or Cleaning up 'temp/publish' dir")
io_util.mkdir_recursive("temp/publish")
if not args.skip_cleanup_temp_dir then
  for entry in lfs.dir("temp/publish") do
    if entry ~= "." and entry ~= ".." then
      assert(os.remove("temp/publish/"..entry))
    end
  end
end

-- create zip packages
if not args.skip_package then
  ---cSpell:ignore tzip
  -- -tzip defines the zip archive type to be "zip". whatever that exactly means

  -- ** IMPORTANT **
  -- -m0=PPMd is some better algorithm specifically made for text files
  -- it makes a measurable difference in zip file size, but it cannot be loaded by factorio
  -- this leads me to believe that it's too new for the majority of tools to
  -- support it at this point so i've disabled all of them for now

  -- -mx9 is the highest compression level
  -- -r means recursive

  local function chdir(path)
    if args.verbose then
      print("  Changing working dir to "..path)
    end
    lfs.chdir(path)
  end

  local root_path = Path.new(lfs.currentdir():gsub("\\", "/"))
  local root_filenames = {
    "README.md",
    "phobos_debug_symbols.md",
    "changelog.txt",
    "LICENSE.txt",
    "LICENSE_THIRD_PARTY.txt",
  }

  local function create_zip(platform, no_lua_binaries)
    local zip_path = Path.combine("temp/publish", "phobos_"..platform.."_"..version_str..".zip")
    print("Packaging "..zip_path:str())

    chdir((root_path / "out/src/release"):str())
    seven_zip("a", "-tzip", "-mx9", "-r", ("../../.." / zip_path):str(), "*.lua")
    if not no_lua_binaries then
      chdir((root_path / "bin" / platform):str())
      seven_zip("a", "-tzip", "-mx9", "-r", ("../.." / zip_path):str(), "*")
    end
    chdir(root_path:str())

    -- not adding src files by default because the chances of someone needing them in
    -- regular distributions is incredibly slim. It can allow for debugging, but since
    -- the debug symbols still point to `src/` files you can manually add a `src` folder
    -- and copy all the src files for that release into it if it's really needed
    -- -- ~TODO: maybe ignore (don't add) the files that were ignored for this build?
    -- seven_zip("a", "-tzip", "-mx9", "-r", --[["-m0=PPMd",]] zip_path:str(), "src/*.lua")

    seven_zip("a", "-tzip", "-mx9", zip_path:str(), table.unpack(root_filenames))
  end

  create_zip("linux")
  create_zip("osx")
  create_zip("windows")
  create_zip("raw", true)

  -- create factorio mod zip
  do
    local zip_path = Path.combine("temp/publish", "phobos_"..version_str..".zip")
    print("Packaging "..zip_path:str())

    local build_root = Path.new("out/factorio/release/phobos")
    chdir((root_path / build_root):str())
    -- "-m0=PPMd" because for factorio mods lua files have to be text files (for now)
    -- so this is more size efficient
    seven_zip("a", "-tzip", "-mx9", "-r", --[["-m0=PPMd",]] ("../../../.." / zip_path):str(), "*.lua")
    chdir(root_path:str())

    seven_zip((function()
      local result = {"a", "-tzip", "-mx9", "-r", --[["-m0=PPMd"]]}
      for _, ignore in ipairs(require("scripts.factorio_build_ignore_list")) do
        result[#result+1] = "-x!src/"..(ignore:find("%.lua$") and ignore or (ignore.."/"))
      end
      result[#result+1] = zip_path:str()
      result[#result+1] = "src/*.lua"
      return table.unpack(result)
    end)())

    root_filenames[#root_filenames+1] = "info.json"
    seven_zip("a", "-tzip", "-mx9", zip_path:str(), table.unpack(root_filenames))

    -- move all files in the zip archive into a `phobos` sub dir

    -- create list of all files that are in the archive
    -- (unfortunately `7z l` doesn't give machine readable output, so this is easier)
    local filenames = root_filenames
    local walk_root
    local function walk_dir(extension, sub_dir)
      for entry in lfs.dir((walk_root / sub_dir):str()) do
        if entry ~= "." and entry ~= ".." then
          local entry_path = walk_root / sub_dir / entry
          local relative_entry_path = entry_path:sub(#walk_root + 1)
          local mode = entry_path:attr("mode")
          if mode == "file" and entry_path:extension() == extension then
            filenames[#filenames+1] = relative_entry_path:str()
          elseif mode == "directory" then
            walk_dir(extension, relative_entry_path:str())
          end
        end
      end
    end
    walk_root = build_root
    walk_dir(".lua")
    walk_root = Path.new(".")
    walk_dir(".lua", Path.new("src"))

    -- create list file for 7z. lines alternate between source name and target name
    local list_file_lines = {}
    for _, filename in ipairs(filenames) do
      list_file_lines[#list_file_lines+1] = filename
      list_file_lines[#list_file_lines+1] = "phobos/"..filename
    end
    local list_file_filename = "temp/publish/rename_list_file.txt"
    local list_file = assert(io.open(list_file_filename, "w"))
    list_file:write(table.concat(list_file_lines, "\n"))
    assert(list_file:close())

    seven_zip("rn", "-tzip", zip_path:str(), "@"..list_file_filename)
  end
end

-- create a git commit which will be the commit tagged for the release
-- (usually this will just be the changelog date change, but it might be any changes, including none)
if not args.skip_preparation_commit then
  print("Creating and pushing git commit for version "..version_str)
  git("add", "*")
  git("commit", "-m", escape_arg("Prepare for version "..version_str), "--allow-empty")
  git("push")
end

-- generate notes for github release
if not args.skip_github_release then
  local github_release_notes_filename = "temp/publish/github_release_notes.md"
  print("Generating notes for github release")
  local out = {}
  local function add(str)
    out[#out+1] = str
  end

  add("\z
    # Release Types\n\z
    - `Phobos for <platform>` contains all files required to run Phobos as a command line tool.\n  \z
      This includes built binaries for Lua and LuaFileSystem which are required to run Phobos.\n\z
    - `Phobos Raw` contains the same as above, except built Lua and LuaFileSystem binaries.\n  \z
      This is useful when you wish to use your own build of Lua and LuaFileSystem,\n  \z
      or when you wish to use Phobos as a library for your project.\n  \z
      (Note: Library package _might_ be its own package in the future.)\n\z
    - `Phobos Factorio Mod` is the same package which is uploaded to the Factorio Mod Portal.\n  \z
      In short, it is the library equivalent of Phobos within Factorio, but see the README for more info.\n\z
    \n\z
    # Changelog\z
  ")
  add("\n")

  for _, category in ipairs(current_version_block.categories) do
    add("## ")
    add(category.name)
    add("\n")
    for _, entry in ipairs(category.entries) do
      local line_start = "- "
      for i, line in ipairs(entry) do
        add(line_start)
        add(line)
        if entry[i + 1] then
          add("\\")
        end
        add("\n")
        line_start = "  "
      end
    end
  end

  out[#out] = nil
  local file = assert(io.open(github_release_notes_filename, "w"))
  assert(file:write(table.concat(out)))
  assert(file:close())

  -- create github release
  print("Creating github release v"..version_str)
  gh("release", "create", "v"..version_str,
    escape_arg("temp/publish/phobos_windows_"..version_str..".zip#Phobos for windows"),
    escape_arg("temp/publish/phobos_linux_"..version_str..".zip#Phobos for linux"),
    escape_arg("temp/publish/phobos_osx_"..version_str..".zip#Phobos for osx"),
    escape_arg("temp/publish/phobos_raw_"..version_str..".zip#Phobos Raw (cmd tools and library)"),
    escape_arg("temp/publish/phobos_"..version_str..".zip#Phobos Factorio Mod"),
    "--repo", "JanSharp/phobos",
    "--notes-file", github_release_notes_filename,
    "--title", "v"..version_str
  )
end

-- increment version in info.json
if not args.skip_increment_version then
  print("Incrementing version in info.json")
  version.patch = version.patch + 1
  version_str = changelog_util.print_version(version)
  info_json = info_json:gsub(info_json_version_pattern, function(prefix)
    return prefix..version_str..'"'
  end)
  do
    local file = assert(io.open("info.json", "w"))
    assert(file:write(info_json))
    assert(file:close())
  end

  -- add new version block in changelog.txt
  print("Adding new version block for "..version_str)
  table.insert(changelog, 1, {version = version, categories = {}})
  do
    local file = assert(io.open("changelog.txt", "w"))
    assert(file:write(changelog_util.encode(changelog)))
    assert(file:close())
  end
end

-- create commit for moving to new version
if not args.skip_increment_commit then
  print("Creating commit for moving to version "..version_str)
  git("add", "*")
  git("commit", "-m", escape_arg("Move to version "..version_str))
end
