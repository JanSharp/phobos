
local framework = require("test_framework")
local assert = require("assert")
local virtual_io_util = require("lib.virtual_io_util")
local tutil = require("testing_util")

local io_util = require("io_util")
local profile_util = require("profile_util")
local Path = require("lib.path")
local constants = require("constants")

local compile_util = require("compile_util")

local _pho = constants.phobos_extension
local _lua = constants.lua_extension

---set to `{}` in `before_each`
---@type table<string, CompileUtilOptions>
local all_compile_options

local mock_compile_util
local restore_compile_util
do
  local original_compile = compile_util.compile

  function mock_compile_util()
    function compile_util.compile(options, context)
      all_compile_options[options.filename] = options
      return compile_util.get_source_name(options)
    end
  end

  function restore_compile_util()
    compile_util.compile = original_compile
  end
end

local function assert_output_file(filename, source_name)
  source_name = source_name or ("@src/"..filename.._pho)
  filename = "out/"..filename.._lua
  if not io_util.exists(filename) then
    assert(false, "Missing output file '"..filename.."'. Virtual file system tree:\n"..tutil.get_fs_tree("/"))
  end
  if source_name then
    local got = io_util.read_file(filename)
    assert.equals(source_name, got, "source_name for output file '"..filename.."'.")
  end
end

local function get_compile_options(filename)
  return all_compile_options[Path.new("src/"..filename.._pho):to_fully_qualified():normalize():str()]
end

local function assert_file_compile_option(expected, filename, field_name)
  local compile_options = get_compile_options(filename)
  assert.contents_equals(expected, compile_options[field_name], field_name.." for compiled file "..filename)
end

do
  local scope = framework.scope:new_scope("profile_util")
  function scope.before_all()
    virtual_io_util.hook()
    mock_compile_util()
  end
  function scope.after_all()
    virtual_io_util.unhook()
    restore_compile_util()
  end

  local profile
  local printed_messages

  local assert_action_counts
  do
    local assert_compiling_x_files
    local assert_copying_x_files
    local assert_deleting_x_files
    local function get_action_count(action_str)
      local pattern = action_str.." (%d+)"
      for _, msg in ipairs(printed_messages) do
        local match = msg:match(pattern)
        if match then
          return tonumber(match)
        end
      end
      assert(false, "Unable to find '"..pattern.."' in printed messages.")
    end
    function assert_compiling_x_files(expected_count)
      assert.equals(expected_count, get_action_count("compiling"), "Amount of files being compiled.")
    end
    function assert_copying_x_files(expected_count)
      assert.equals(expected_count, get_action_count("copying"), "Amount of files being compiled.")
    end
    function assert_deleting_x_files(expected_count)
      assert.equals(expected_count, get_action_count("deleting"), "Amount of files being compiled.")
    end
    function assert_action_counts(compile, copy, delete)
      assert_compiling_x_files(compile)
      assert_copying_x_files(copy)
      assert_deleting_x_files(delete)
    end
  end

  ---@param params NewProfileInternalParams
  local function make_profile(params)
    params.name = params.name or "test_profile"
    params.output_dir = params.output_dir or "out"
    params.cache_dir = params.cache_dir or "cache"
    params.root_dir = params.root_dir or io_util.get_working_dir()
    profile = profile_util.new_profile(params)
  end

  local function before_each()
    virtual_io_util.new_fs()
    io_util.mkdir_recursive("/test/src")
    io_util.set_working_dir("/test")
    make_profile{}
    all_compile_options = {}
    printed_messages = {}
  end

  local function add_test(label, func)
    scope:add_test(label, function()
      before_each()
      func()
    end)
  end

  local function run()
    profile_util.run_profile(profile, function(msg)
      printed_messages[#printed_messages+1] = msg
    end)
  end

  local function create_source_file(filename, extension)
    io_util.write_file("src/"..filename..(extension or _pho), "")
  end

  ---@param filename string @ used to evaluate source and output args
  ---@param params IncludeParams
  local function include_file(filename, params)
    params = params or {}
    params.profile = profile
    params.source_path = params.source_path or ("src/"..filename.._pho)
    params.source_name = params.source_name or ("@src/"..filename.._pho)
    params.output_path = params.output_path or (filename.._lua)
    profile_util.include(params)
    return params
  end

  ---@param dir string @ used to evaluate source and output args
  ---@param params IncludeParams
  local function include_dir(dir, params)
    params = params or {}
    params.profile = profile
    params.source_path = Path.new("src/"..dir):normalize():str()
    params.source_name = "@"..params.source_path..'/?'
    params.output_path = dir
    profile_util.include(params)
    return params
  end

  -- end of util functions

  add_test("run basic profile that does nothing", function()
    run()
    assert_action_counts(0, 0, 0)
  end)

  add_test("include 1 file", function()
    create_source_file("foo")
    create_source_file("bar")
    create_source_file("baz")
    include_file("foo")
    run()
    assert_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include 2 files", function()
    create_source_file("foo")
    create_source_file("bar")
    create_source_file("baz")
    include_file("foo")
    include_file("baz")
    run()
    assert_output_file("foo")
    assert_output_file("baz")
    assert_action_counts(2, 0, 0)
  end)

  add_test("include 2 files, one with the phobos extension, one with lua extension", function()
    create_source_file("foo", _pho)
    create_source_file("bar", _lua)
    include_file("foo")
    include_file("bar", {
      source_path = "src/bar".._lua,
      source_name = "@src/bar".._lua,
    })
    run()
    assert_output_file("foo")
    assert_output_file("bar", "@src/bar".._lua)
    assert_action_counts(2, 0, 0)
  end)

  add_test("include dir with 1 file", function()
    create_source_file("foo")
    include_dir(".")
    run()
    assert_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include 2 dirs", function()
    create_source_file("one/foo")
    create_source_file("one/bar")
    create_source_file("two/baz")
    include_dir("one")
    include_dir("two")
    run()
    assert_output_file("one/foo")
    assert_output_file("one/bar")
    assert_output_file("two/baz")
    assert_action_counts(3, 0, 0)
  end)

  add_test("include 1 dir with lua, phobos and other files", function()
    create_source_file("foo", _pho)
    create_source_file("bar", _lua)
    create_source_file("baz", ".txt")
    include_dir(".")
    run()
    assert_output_file("foo")
    assert_output_file("bar", "@src/bar".._lua)
    assert_action_counts(2, 0, 0)
  end)

  add_test("include 1 dir then include 1 file within the same dir", function()
    create_source_file("foo")
    create_source_file("bar")
    include_dir(".", {error_message_count = 10})
    include_file("foo", {error_message_count = 100})
    run()
    assert_output_file("foo")
    assert_output_file("bar")
    assert_file_compile_option(100, "foo", "error_message_count")
    assert_file_compile_option(10, "bar", "error_message_count")
    assert_action_counts(2, 0, 0)
  end)

  add_test("include a file with invalid output_path file extension", function()
    create_source_file("foo")
    include_file("foo", {output_path = "foo".._lua.."x"})
    assert.errors("When including a single file for compilation the output file extension must be '"
      .._lua.."'. (output_path: 'foo".._lua.."x')",
      run, nil, true
    )
  end)

  add_test("include a file with invalid source_name, containing '?'", function()
    create_source_file("foo")
    local include_def = include_file("foo", {source_name = "@?"})
    assert.errors("When including a single file for compilation the 'source_name' must not contain '?'. \z
      It must instead define the entire source_name - it is not a pattern. \z
      (source_path: '"..include_def.source_path.."', source_name: '"..include_def.source_name.."')",
      run, nil, true
    )
  end)

  add_test("include dir with 3 files, 2 matching a file_pattern", function()
    create_source_file("foo")
    create_source_file("bar")
    create_source_file("baz")
    include_dir(".", {filename_pattern = "^/ba[rz]%".._pho.."$"})
    run()
    assert_output_file("bar")
    assert_output_file("baz")
    assert_action_counts(2, 0, 0)
  end)

  add_test("include a file matching a file_pattern", function()
    create_source_file("foo")
    include_file("foo", {filename_pattern = ".?"})
    run()
    assert_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include a file not matching a file_pattern, still included", function()
    create_source_file("foo")
    include_file("foo", {filename_pattern = "food"})
    run()
    assert_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  do
    local function test_recursion_depth(depth)
      create_source_file("foo")
      create_source_file("one/bar")
      create_source_file("one/two/baz")
      create_source_file("one/two/three/bat")
      include_dir(".", {recursion_depth = depth})
      run()
      for i = 1, depth do
        assert_output_file(({
          "foo",
          "one/bar",
          "one/two/baz",
          "one/two/three/bat",
        })[i])
      end
      assert_action_counts(depth, 0, 0)
    end
    add_test("include dir with recursion_depth 0, so nothing", function()
      test_recursion_depth(0)
    end)
    add_test("include dir with recursion_depth 1", function()
      test_recursion_depth(1)
    end)
    add_test("include dir with recursion_depth 2", function()
      test_recursion_depth(2)
    end)
    add_test("include dir with recursion_depth 3", function()
      test_recursion_depth(3)
    end)
  end

  add_test("include file with recursion_depth 0, still included", function()
    create_source_file("foo")
    include_file("foo", {recursion_depth = 0})
    run()
    assert_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  -- TODO: use load
  -- TODO: inject scripts, ha ha
  -- TODO: outputting to the same file when compiling
end
