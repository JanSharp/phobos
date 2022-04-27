
local framework = require("test_framework")
local assert = require("assert")
local virtual_io_util = require("lib.virtual_io_util")
local tutil = require("testing_util")
local spy = require("spy")

local io_util = require("io_util")
local profile_util = require("profile_util")
local Path = require("lib.path")
local constants = require("constants")
local util = require("util")

local compile_util = require("compile_util")

local _pho = constants.phobos_extension
local _lua = constants.lua_extension

local function use_lua_extension()
  _pho = constants.lua_extension
end

local function use_pho_extension()
  _pho = constants.phobos_extension
end

---set to `{}` in `before_each`
---@type table<string, CompileUtilOptions>
local all_compile_options

local function normalize_path(path)
  return Path.new(path):to_fully_qualified():normalize():str()
end

---@return CompileUtilOptions|nil
local function try_get_compile_options(filename, index)
  filename = normalize_path("src/"..filename.._pho)
  index = index or 1
  return all_compile_options[filename] and all_compile_options[filename][index]
end

---@return CompileUtilOptions
local function get_compile_options(filename, index)
  local options = try_get_compile_options(filename, index)
  if not options then
    util.debug_abort("Unable to get compile options for '"..filename
      ..(index and ("' (index "..index..")") or "'").."."
    )
  end
  return options
end

local function assert_file_compile_option(expected, filename, field_name)
  local compile_options = get_compile_options(filename)
  assert.contents_equals(expected, compile_options[field_name], field_name.." for compiled file "..filename)
end

local function assert_output_file(filename)
  if not io_util.exists("out/"..filename) then
    assert(false, "Missing output file 'out/"..filename.."'.")
  end
end

local function assert_no_output_file(filename)
  if io_util.exists("out/"..filename) then
    assert(false, "Output file 'out/"..filename.."' should not exist.")
  end
end

local function assert_lua_output_file(filename, source_name, out_filename)
  source_name = source_name or ("@src/"..filename.._pho)
  out_filename = (out_filename or filename).._lua
  assert_output_file(out_filename)
  if source_name then
    local got = compile_util.get_source_name(get_compile_options(filename))
    assert.equals(source_name, got, "source_name for output file 'out/"..out_filename.."'.")
  end
end

local function get_source(func)
  return debug.getinfo(func, "S").source
end

---@param compile_options CompileUtilOptions
local function assert_inject_scripts(compile_options, expected_script_filenames)
  local inject_scripts = compile_options.inject_scripts
  for i = 1, #expected_script_filenames do
    local script = inject_scripts[i]
    assert.equals("function", type(script), "inject script type")
    ---cSpell:ignore nparams
    assert.equals(1, debug.getinfo(script, "u").nparams, "inject script nparams")
    local expected_source = "@"..normalize_path(expected_script_filenames[i])
    assert.equals(expected_source, get_source(script), "inject script source")
  end
  local extra_script = inject_scripts[#expected_script_filenames + 1]
  if extra_script then -- can't directly assert because get_source errors with nil arg
    assert(false, "Expected "..#expected_script_filenames.." inject scripts, got at least \z
      1 more with its source being '"..get_source(extra_script).."'"
    )
  end
end

do
  local scope = framework.scope:new_scope("profile_util")

  local profile
  local printed_messages

  function scope.before_all()
    virtual_io_util.hook()
    spy.hook(compile_util, "compile", function(options, context)
      local target = all_compile_options[options.filename]
      if not target then
        target = {}
        all_compile_options[options.filename] = target
      end
      target[#target+1] = options
    end)
    assert.push_err_msg_handler(function(msg)
      return (msg and (msg.." ") or "").."Virtual file system tree at time of error:\n"..tutil.get_fs_tree("/")
        .."\nprinted lines:\n"..table.concat(printed_messages, "\n")
    end)
  end
  function scope.after_all()
    virtual_io_util.unhook()
    spy.unhook_all()
    assert.pop_err_msg_handler()
  end

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
      assert.equals(expected_count, get_action_count("copying"), "Amount of files being copied.")
    end
    function assert_deleting_x_files(expected_count)
      assert.equals(expected_count, get_action_count("deleting"), "Amount of files being deleted.")
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

  local function create_file(filename, extension)
    filename = filename..(extension or "")
    io_util.write_file(filename, "contents of "..filename)
  end

  local function create_output_file(filename, extension)
    filename = "out/"..filename..(extension or "")
    io_util.write_file(filename, "")
  end

  local function create_lua_output_file(filename, extension)
    create_output_file(filename, extension or _lua)
  end

  local function create_inject_script_file(filename, extension, contents)
    io_util.write_file("scripts/"..filename..(extension or _pho), contents or "return function(ast) end")
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

  ---@param params IncludeCopyParams
  local function include_copy(path, params)
    params = params or {}
    params.profile = profile
    params.source_path = path
    params.output_path = params.output_path or path
    profile_util.include_copy(params)
    return params
  end

  ---@param params IncludeDeleteParams
  local function include_delete(path, params)
    params = params or {}
    params.profile = profile
    params.output_path = params.output_path or path
    profile_util.include_delete(params)
    return params
  end

  local exclude_file
  local exclude_dir
  do
    local function exclude(path, params)
      params = params or {}
      params.profile = profile
      params.source_path = Path.new(path):normalize():str()
      profile_util.exclude(params)
      return params
    end

    ---@param params ExcludeParams
    function exclude_file(path, params)
      return exclude("src/"..path.._pho, params)
    end

    ---@param params ExcludeParams
    function exclude_dir(path, params)
      return exclude("src/"..path, params)
    end
  end

  ---@param params ExcludeCopyParams
  local function exclude_copy(path, params)
    params = params or {}
    params.profile = profile
    params.source_path = Path.new("src/"..path):normalize():str()
    profile_util.exclude_copy(params)
  end

  ---@param params ExcludeDeleteParams
  local function exclude_delete(path, params)
    params = params or {}
    params.profile = profile
    params.output_path = Path.new("src/"..path):normalize():str()
    profile_util.exclude_delete(params)
  end

  -- end of util functions

  -- process_include

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
    assert_lua_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include 2 files", function()
    create_source_file("foo")
    create_source_file("bar")
    create_source_file("baz")
    include_file("foo")
    include_file("baz")
    run()
    assert_lua_output_file("foo")
    assert_lua_output_file("baz")
    assert_action_counts(2, 0, 0)
  end)

  add_test("include 2 files, one with the phobos extension, one with lua extension", function()
    create_source_file("foo")
    include_file("foo")
    use_lua_extension()
    create_source_file("bar")
    include_file("bar")
    use_pho_extension()
    run()
    assert_lua_output_file("foo")
    use_lua_extension()
    assert_lua_output_file("bar")
    use_pho_extension()
    assert_action_counts(2, 0, 0)
  end)

  add_test("include dir with 1 file", function()
    create_source_file("foo")
    include_dir(".")
    run()
    assert_lua_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include 2 dirs with 3 files total", function()
    create_source_file("one/foo")
    create_source_file("one/bar")
    create_source_file("two/baz")
    include_dir("one")
    include_dir("two")
    run()
    assert_lua_output_file("one/foo")
    assert_lua_output_file("one/bar")
    assert_lua_output_file("two/baz")
    assert_action_counts(3, 0, 0)
  end)

  add_test("include 1 dir with lua, phobos and other files", function()
    create_source_file("foo")
    use_lua_extension()
    create_source_file("bar")
    use_pho_extension()
    create_source_file("baz", ".txt")
    include_dir(".")
    run()
    assert_lua_output_file("foo")
    use_lua_extension()
    assert_lua_output_file("bar")
    use_pho_extension()
    assert_action_counts(2, 0, 0)
  end)

  add_test("include 1 dir then include 1 file within the same dir", function()
    create_source_file("foo")
    create_source_file("bar")
    include_dir(".", {error_message_count = 10})
    include_file("foo", {error_message_count = 100})
    run()
    assert_lua_output_file("foo")
    assert_lua_output_file("bar")
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

  add_test("include path that does not exist", function()
    include_file("foo")
    assert.errors("No such file or directory '"..normalize_path("src/foo".._pho), run)
  end)

  do
    local function add_invalid_output_path_tests(label, include_func)
      add_test(label.." with absolute output_path", function()
        include_func("foo", {output_path = "/foo"})
        assert.errors("'output_path' must be a relative path (output_path: '/foo').", run, nil, true)
      end)

      add_test(label.." with output_path outside of output dir using '..'", function()
        include_func("foo", {output_path = ".././foo"})
        assert.errors("Attempt to output files outside of the output directory. \z
          (output_path: '.././foo', normalized: '../foo').", run, nil, true
        )
      end)
    end

    add_invalid_output_path_tests("include", include_file)
    add_invalid_output_path_tests("include_copy", include_copy)
    add_invalid_output_path_tests("include_delete", include_delete)
  end

  add_test("include the same file twice with the same output path", function()
    create_source_file("foo")
    include_file("foo")
    include_file("foo") -- overwrites the previous one
    run()
    assert_lua_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include the same file twice with different output paths", function()
    create_source_file("foo")
    include_file("foo")
    include_file("foo", {output_path = "bar".._lua}) -- overwrites the previous one
    run()
    assert_lua_output_file("foo", nil, "bar")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include dir with 3 files, 2 matching a filename_pattern", function()
    create_source_file("foo")
    create_source_file("bar")
    create_source_file("baz")
    include_dir(".", {filename_pattern = "^/ba[rz]%".._pho.."$"})
    run()
    assert_lua_output_file("bar")
    assert_lua_output_file("baz")
    assert_action_counts(2, 0, 0)
  end)

  add_test("include a file matching a filename_pattern", function()
    create_source_file("foo")
    include_file("foo", {filename_pattern = ".?"})
    run()
    assert_lua_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include 1 file not matching a filename_pattern, still included", function()
    create_source_file("foo")
    include_file("foo", {filename_pattern = "food"})
    run()
    assert_lua_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include_copy 1 dir with filename_pattern", function()
    create_file("docs/foo")
    create_file("docs/bar")
    create_file("docs/baz")
    include_copy("docs", {filename_pattern = "ba[rz]"})
    run()
    assert_output_file("docs/bar")
    assert_output_file("docs/baz")
    assert_action_counts(0, 2, 0)
  end)

  add_test("include_copy 1 file not matching a filename_pattern, still included", function()
    create_file("docs/foo")
    include_copy("docs/foo", {filename_pattern = "bar"})
    run()
    assert_output_file("docs/foo")
    assert_action_counts(0, 1, 0)
  end)

  add_test("include_delete 1 dir with filename_pattern", function()
    create_output_file("docs/foo")
    create_output_file("docs/bar")
    create_output_file("docs/baz")
    include_delete("docs", {filename_pattern = "ba[rz]"})
    run()
    assert_no_output_file("docs/bar")
    assert_no_output_file("docs/baz")
    assert_action_counts(0, 0, 2)
  end)

  add_test("include_delete 1 file not matching a filename_pattern, still included", function()
    create_output_file("docs/foo")
    include_delete("docs/foo", {filename_pattern = "bar"})
    run()
    assert_no_output_file("docs/foo")
    assert_action_counts(0, 0, 1)
  end)

  add_test("include dir containing a non lua or phobos file", function()
    create_source_file("foo", _lua.."x")
    include_dir(".")
    run()
    assert_action_counts(0, 0, 0)
  end)

  add_test("include dir containing a non lua or phobos file but matching a filename_pattern", function()
    create_source_file("foo", _lua.."x")
    include_dir(".", {filename_pattern = "foo"})
    run()
    assert_action_counts(0, 0, 0)
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
        assert_lua_output_file(({
          "foo",
          "one/bar",
          "one/two/baz",
          "one/two/three/bat",
        })[i])
      end
      assert_action_counts(depth, 0, 0)
    end
    add_test("include 1 dir with recursion_depth 0, so nothing", function()
      test_recursion_depth(0)
    end)
    add_test("include 1 dir with recursion_depth 1", function()
      test_recursion_depth(1)
    end)
    add_test("include 1 dir with recursion_depth 2", function()
      test_recursion_depth(2)
    end)
    add_test("include 1 dir with recursion_depth 3", function()
      test_recursion_depth(3)
    end)
  end

  add_test("include 1 file with recursion_depth 0, still included", function()
    create_source_file("foo")
    include_file("foo", {recursion_depth = 0})
    run()
    assert_lua_output_file("foo")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include_copy 1 dir with recursion_depth 3", function()
    create_file("foo")
    create_file("one/bar")
    create_file("one/two/baz")
    create_file("one/two/three/bat")
    include_copy(".", {recursion_depth = 3})
    run()
    assert_output_file("foo")
    assert_output_file("one/bar")
    assert_output_file("one/two/baz")
    assert_action_counts(0, 3, 0)
  end)

  add_test("include_copy 1 file with recursion_depth 0, still included", function()
    create_file("foo")
    include_copy("foo", {recursion_depth = 0})
    run()
    assert_output_file("foo")
    assert_action_counts(0, 1, 0)
  end)

  add_test("include_delete 1 dir with recursion_depth 3", function()
    create_output_file("foo")
    create_output_file("one/bar")
    create_output_file("one/two/baz")
    create_output_file("one/two/three/bat")
    include_delete(".", {recursion_depth = 3})
    run()
    assert_no_output_file("foo")
    assert_no_output_file("one/bar")
    assert_no_output_file("one/two/baz")
    assert_action_counts(0, 0, 3)
  end)

  add_test("include_delete 1 file with recursion_depth 0, still included", function()
    create_output_file("foo")
    include_delete("foo", {recursion_depth = 0})
    run()
    assert_no_output_file("foo")
    assert_action_counts(0, 0, 1)
  end)

  add_test("include 1 file with false use_load", function()
    create_source_file("foo")
    include_file("foo", {use_load = false})
    run()
    assert_lua_output_file("foo")
    assert_file_compile_option(false, "foo", "use_load")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include 1 file with true use_load", function()
    create_source_file("foo")
    include_file("foo", {use_load = true})
    run()
    assert_lua_output_file("foo")
    assert_file_compile_option(true, "foo", "use_load")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include 1 file with 10 error_message_count", function()
    create_source_file("foo")
    include_file("foo", {error_message_count = 10})
    run()
    assert_lua_output_file("foo")
    assert_file_compile_option(10, "foo", "error_message_count")
    assert_action_counts(1, 0, 0)
  end)

  add_test("include 1 file with 1 inject script", function()
    create_source_file("foo")
    create_inject_script_file("inject")
    local inject_scripts = {"scripts/inject".._pho}
    include_file("foo", {inject_scripts = inject_scripts})
    run()
    assert_lua_output_file("foo")
    assert_inject_scripts(get_compile_options("foo"), inject_scripts)
    assert_action_counts(1, 0, 0)
  end)

  add_test("include 1 file with 3 inject scripts", function()
    create_source_file("foo")
    create_inject_script_file("inject_foo")
    create_inject_script_file("inject_bar")
    create_inject_script_file("inject_baz")
    local inject_scripts = {
      "scripts/inject_foo".._pho,
      "scripts/inject_bar".._pho,
      "scripts/inject_baz".._pho,
    }
    include_file("foo", {inject_scripts = inject_scripts})
    run()
    assert_lua_output_file("foo")
    assert_inject_scripts(get_compile_options("foo"), inject_scripts)
    assert_action_counts(1, 0, 0)
  end)

  do
    local function test_inject_script_instances(do_copy)
      create_source_file("foo")
      create_source_file("bar")
      create_inject_script_file("inject")
      local inject_scripts = {"scripts/inject".._pho}
      include_file("foo", {inject_scripts = inject_scripts})
      include_file("bar", {inject_scripts = do_copy and util.shallow_copy(inject_scripts) or inject_scripts})
      run()
      assert_lua_output_file("foo")
      assert_lua_output_file("bar")
      local foo_options = get_compile_options("foo")
      local bar_options = get_compile_options("bar")
      assert_inject_scripts(foo_options, inject_scripts)
      assert_inject_scripts(bar_options, inject_scripts)
      if do_copy then
        assert.not_equals(foo_options.inject_scripts, bar_options.inject_scripts,
          "inject_scripts table instance"
        )
        assert.equals(foo_options.inject_scripts[1], bar_options.inject_scripts[1],
          "inject_scripts first and only function instance"
        )
      else
        assert.equals(foo_options.inject_scripts, bar_options.inject_scripts, "inject_scripts table instance")
      end
      assert_action_counts(2, 0, 0)
    end

    add_test("include 2 files with the exact same inject scripts", function()
      test_inject_script_instances(false)
    end)

    add_test("include 2 files with the same inject scripts but different table instances", function()
      test_inject_script_instances(true)
    end)
  end

  add_test("inject script file that does not return a function", function()
    create_source_file("foo")
    create_inject_script_file("inject", nil, "return 100")
    include_file("foo", {inject_scripts = {"scripts/inject".._pho}})
    assert.errors("AST inject scripts must return a function. \z
      (script file: "..normalize_path("scripts/inject".._pho)..")",
      run, nil, true
    )
  end)

  add_test("inject script file that does not exist", function()
    create_source_file("foo")
    include_file("foo", {inject_scripts = {"scripts/inject".._pho}})
    assert.errors("No such file or directory '"..normalize_path("scripts/inject".._pho).."'%.", run)
  end)

  add_test("include_copy 1 file", function()
    create_file("foo")
    include_copy("foo")
    run()
    assert_output_file("foo")
    assert_action_counts(0, 1, 0)
  end)

  add_test("include_copy 1 file and rename it", function()
    create_file("foo")
    include_copy("foo", {output_path = "bar"})
    run()
    assert_output_file("bar")
    assert_action_counts(0, 1, 0)
  end)

  add_test("include_copy 2 files", function()
    create_file("foo")
    create_file("bar")
    include_copy("foo")
    include_copy("bar")
    run()
    assert_output_file("foo")
    assert_output_file("bar")
    assert_action_counts(0, 2, 0)
  end)

  add_test("include_copy the same file twice the same output path", function()
    create_file("foo")
    include_copy("foo")
    include_copy("foo") -- overwrites/does nothing
    run()
    assert_output_file("foo")
    assert_action_counts(0, 1, 0)
  end)

  add_test("include_copy the same file twice, with different output paths", function()
    create_file("foo")
    include_copy("foo")
    include_copy("foo", {output_path = "foo2"}) -- doesn't overwrite, copy the file twice
    run()
    assert_output_file("foo")
    assert_output_file("foo2")
    assert_action_counts(0, 2, 0)
  end)

  add_test("include_copy 1 dir with 1 files", function()
    create_file("docs/foo")
    include_copy("docs")
    run()
    assert_output_file("docs/foo")
    assert_action_counts(0, 1, 0)
  end)

  add_test("include_copy 1 dir with 3 files", function()
    create_file("docs/foo")
    create_file("docs/bar")
    create_file("docs/baz")
    include_copy("docs")
    run()
    assert_output_file("docs/foo")
    assert_output_file("docs/bar")
    assert_output_file("docs/baz")
    assert_action_counts(0, 3, 0)
  end)

  add_test("include_copy 2 dirs with 3 files total", function()
    create_file("docs1/foo")
    create_file("docs1/bar")
    create_file("docs2/baz")
    include_copy("docs1")
    include_copy("docs2")
    run()
    assert_output_file("docs1/foo")
    assert_output_file("docs1/bar")
    assert_output_file("docs2/baz")
    assert_action_counts(0, 3, 0)
  end)

  add_test("include_copy path that does not exist", function()
    include_copy("docs/foo")
    assert.errors("No such file or directory '"..normalize_path("docs/foo"), run)
  end)

  add_test("include_delete 1 file", function()
    create_output_file("foo")
    include_delete("foo")
    run()
    assert_no_output_file("foo")
    assert_action_counts(0, 0, 1)
  end)

  add_test("include_delete 2 files", function()
    create_output_file("foo")
    create_output_file("bar")
    include_delete("foo")
    include_delete("bar")
    run()
    assert_no_output_file("foo")
    assert_no_output_file("bar")
    assert_action_counts(0, 0, 2)
  end)

  add_test("include_delete the same file twice", function()
    create_output_file("foo")
    include_delete("foo")
    include_delete("foo")
    run()
    assert_no_output_file("foo")
    assert_action_counts(0, 0, 1)
  end)

  add_test("include_delete 1 dir with 1 file", function()
    create_output_file("foo")
    include_delete(".")
    run()
    assert_no_output_file("foo")
    assert_action_counts(0, 0, 1)
  end)

  add_test("include_delete 1 dir with 3 files", function()
    create_output_file("foo/bar")
    create_output_file("foo/baz")
    create_output_file("foo/bat")
    include_delete("foo")
    run()
    assert_no_output_file("foo/bar")
    assert_no_output_file("foo/baz")
    assert_no_output_file("foo/bat")
    assert_action_counts(0, 0, 3)
  end)

  add_test("include_delete 2 dirs with 3 files total", function()
    create_output_file("one/foo")
    create_output_file("two/bar")
    create_output_file("two/baz")
    include_delete("one")
    include_delete("two")
    run()
    assert_no_output_file("one/foo")
    assert_no_output_file("two/bar")
    assert_no_output_file("two/baz")
    assert_action_counts(0, 0, 3)
  end)

  add_test("include_delete path that does not exist", function()
    include_delete("foo")
    run()
    assert_action_counts(0, 0, 0)
  end)

  -- process_exclude

  add_test("exclude 1 file", function()
    create_source_file("foo")
    include_file("foo")
    exclude_file("foo")
    run()
    assert_action_counts(0, 0, 0)
  end)

  add_test("exclude 1 dir with 3 files", function()
    create_source_file("hi/foo")
    create_source_file("hi/bar")
    create_source_file("hi/baz")
    include_dir("hi")
    exclude_dir("hi")
    run()
    assert_action_counts(0, 0, 0)
  end)

  -- add_test("include 2 files with the same name but different extensions, outputting to the same file", function()
  --   create_source_file("foo")
  --   create_source_file("foo", _lua)
  --   include_dir(".")
  --   run()
  --   assert_output_file("foo")
  --   assert_action_counts(1, 0, 0)
  -- end)

  -- NOTE: writing of tests has been put on hold because I'm not sure [...]
  -- 1) if the profile util structure makes sense and is good. It doesn't follow the "value is the boundary"
  --   strategy very well
  -- 2) if the profile util and profiles in general are going to stay like this at all. I'm thinking of
  --   completely redoing them with a much more generic include and exclude system to allow for
  --   reuse of that system for formatting, disassembling, outputting as disassembly directly, and so on

  -- TODO: outputting to the same file when compiling
  -- TODO: excluding files or directories that don't exist
  -- TODO: inject script incremental logic
end
