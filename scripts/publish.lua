
local Path = require("lib.LuaPath.path")
Path.set_main_separator("/")
local arg_parser = require("lib.LuaArgParser.arg_parser")
local io_util = require("io_util")
local changelog_util = require("scripts.changelog_util")
local shell_util = require("shell_util")
local escape_arg = shell_util.escape_arg
local util = require("util")

local skip_able = {
  "skip_ensure_command_availability",
  "skip_ensure_main_branch",
  "skip_ensure_clean_working_tree",
  "skip_tests",
  "skip_date_stamp_changelog",
  "skip_write_phobos_version",
  "skip_cleanup_temp_dir",
  "skip_build",
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
if not args then util.abort() end
if args.help then return end

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

local function phobos(...)
  local command = table.concat({"phobos", ...}, " ")
  if args.verbose then
    print("  "..command)
  end
  return os.execute(command)
end

local main_branch = "main"
local current_branch

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
  ensure_command_is_available("7z", "7 zip (look for p7zip in your \z
    package manager on Linux or MacOS (ref: brew?), 7zip on windows)"
  )
  ensure_command_is_available("phobos", "Phobos (install the previous version of the Phobos standalone)")
  if missing_commands[1] then
    util.abort("Missing programs "..table.concat(missing_commands, ", "))
  end
end

-- ensure git is clean and on main
print("Checking git status")
do
  current_branch = assert(git("branch", "--show-current")[1]):gsub("\n$", "")
  if not args.skip_ensure_main_branch and current_branch ~= main_branch then
    util.abort("git must be on branch '"..main_branch.."', but is on '"..current_branch.."'.")
  end
  local git_status = git("status", "--porcelain")
  if not args.skip_ensure_clean_working_tree and git_status[1] then
    util.abort("git working tree must be clean")
  end
end

-- run all tests (currently testing is very crude, so just `tests/compile_test.lua`)
if not args.skip_tests then
  print("Running tests")
  local success, err = pcall(loadfile("tests/main.lua"), table.unpack{
    "--print-failed",
    "--print-stacktrace",
  })
  if not success then
    util.abort("Tests failed")
  end
  success, err = pcall(loadfile("tests/compile_test.lua"), table.unpack{
    "--test-disassembler",
    "--ensure-clean",
    "--test-formatter",
  })
  if not success then
    print(err)
    print()
    util.abort("Tests failed")
  end
end

-- get version from info.json
print("Reading info.json")
local info_json = io_util.read_file("info.json")
local info_json_version_pattern = "(\"version\"%s*:%s*\")(%d+%.%d+%.%d+)\""
local version_str = select(2, info_json:match(info_json_version_pattern))
if not version_str then
  util.abort("Unable to get version from info.json")
end
local version = changelog_util.parse_version(version_str)
if version_str ~= changelog_util.print_version(version) then
  util.abort("Version "..version_str.." has leading 0s. It should be "..changelog_util.print_version(version))
end

-- get version_block from changelog.txt for that version
print("Extracting version block for version "..version_str.." from changelog.txt")
local changelog = io_util.read_file("changelog.txt")
local current_version_block
for _, version_block in ipairs(changelog) do
  if changelog_util.compare_version(version_block.version, version) then
    current_version_block = version_block
    break
  end
end
if not current_version_block then
  util.abort("Could not find a version block for version "..version_str.." in changelog.txt")
end

-- date stamp that version block
if not args.skip_date_stamp_changelog then
  local date = os.date("!%Y-%m-%d")
  print("Setting date for version block for version "..version_str.." to "..date.." in changelog.txt")
  current_version_block.date = date
  io_util.write_file("changelog.txt", changelog_util.encode(changelog))
end

local function write_phobos_version()
  if not args.skip_write_phobos_version then
    print("Writing version "..version_str.." to src/phobos_version.lua")
    io_util.write_file("src/phobos_version.lua", string.format("\n\z
      ----------------------------------------------------------------------------------------------------\n\z
      -- This file is generated by the publish script\n\z
      ----------------------------------------------------------------------------------------------------\n\z
      return {\n  \z
        major = %d,\n  \z
        minor = %d,\n  \z
        patch = %d,\n\z
      }\n\z
      ",
      version.major,
      version.minor,
      version.patch
    ))
  end
end

write_phobos_version()

-- prepare temp dir
print("Creating or Cleaning up 'temp/publish' dir")
if not args.skip_cleanup_temp_dir then
  if Path.new("temp/publish"):exists() then
    io_util.rmdir_recursive("temp/publish")
  end
end
io_util.mkdir_recursive("temp/publish")

if not args.skip_build then
  print("Building standalone and factorio publish builds")
  if not phobos(
    "--profile-names",
    "publish_linux",
    "publish_osx",
    "publish_windows",
    "publish_raw",
    "publish_factorio"
  )
  then
    util.abort("A build failed, aborting.")
  end
end

-- create zip packages
if not args.skip_package then
  ---cSpell:ignore tzip
  -- -tzip defines the zip archive type to be "zip". whatever that exactly means
  -- -mx9 is the highest compression level
  -- -r means recursive

  -- no longer relevant, but still good info:
  -- -m0=PPMd is some better algorithm specifically made for text files
  --   it makes a measurable difference in zip file size, but it cannot be loaded by factorio
  --   this leads me to believe that it's too new for the majority of tools to
  --   support it at this point so i've disabled all of them for now

  local function chdir(path)
    if args.verbose then
      print("  Changing working dir to "..path)
    end
    io_util.set_working_dir(path)
  end

  local root_path = io_util.get_working_dir_path()

  local function create_zip(name, package_name)
    local zip_filename = package_name.."_"..version_str..".zip"
    print("Packaging "..zip_filename)
    chdir((root_path / ("temp/publish/publish_"..name)):str())
    seven_zip("a", "-tzip", "-mx9", "-r", escape_arg("../"..zip_filename), escape_arg("*"))
    chdir(root_path:str())
    -- If the src files were to be added to the packages it would be done in the build profiles
  end

  create_zip("linux", "phobos_linux")
  create_zip("osx", "phobos_osx")
  create_zip("windows", "phobos_windows")
  create_zip("raw", "phobos_raw")
  create_zip("factorio", "phobos")
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
  io_util.write_file(github_release_notes_filename, table.concat(out))

  -- create github release
  print("Creating github release v"..version_str)
  gh("release", "create", escape_arg("v"..version_str),
    escape_arg("temp/publish/phobos_windows_"..version_str..".zip#Phobos for windows"),
    escape_arg("temp/publish/phobos_linux_"..version_str..".zip#Phobos for linux"),
    escape_arg("temp/publish/phobos_osx_"..version_str..".zip#Phobos for osx"),
    escape_arg("temp/publish/phobos_raw_"..version_str..".zip#Phobos Raw (cmd tools and library)"),
    escape_arg("temp/publish/phobos_"..version_str..".zip#Phobos Factorio Mod"),
    "--repo", escape_arg("JanSharp/phobos"),
    "--target", escape_arg(current_branch),
    "--notes-file", escape_arg(github_release_notes_filename),
    "--title", escape_arg("v"..version_str)
  )
  git("pull", "--tags")
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
    io_util.write_file("info.json", info_json)
  end

  -- add new version block in changelog.txt
  print("Adding new version block for "..version_str)
  table.insert(changelog, 1, {version = version, categories = {}})
  do
    io_util.write_file("changelog.txt", changelog_util.encode(changelog))
  end

  write_phobos_version()
end

-- create commit for moving to new version
if not args.skip_increment_commit then
  print("Creating commit for moving to version "..version_str)
  git("add", escape_arg("*"))
  git("commit", "-m", escape_arg("Move to version "..version_str))
end
