
local framework = require("test_framework")
local assert = require("assert")
local virtual_io_util = require("lib.virtual_io_util")

local io_util = require("io_util")
local cache = require("cache")
local profile_util = require("profile_util")
local phobos_version = require("phobos_version")
local constants = require("constants")
local util = require("util")
local Path = require("lib.path")
local binary = require("binary_serializer")

local action_enum = constants.action_enum

local function compare_profile(expected_profile, got_profile)
  expected_profile.include_exclude_copy_definitions = nil
  expected_profile.include_exclude_definitions = nil
  expected_profile.include_exclude_delete_definitions = nil
  expected_profile.inject_scripts = nil
  expected_profile.on_pre_profile_ran = nil
  expected_profile.on_post_profile_ran = nil
  local optimizations = expected_profile.optimizations
  optimizations.fold_const = optimizations.fold_const or false
  optimizations.fold_control_statements = optimizations.fold_control_statements or false
  optimizations.tail_calls = optimizations.tail_calls or false
  assert.contents_equals(expected_profile, got_profile, "save loaded profile")
end

local function compare_file_list(expected_file_list, got_file_list)
  assert.contents_equals(expected_file_list, got_file_list, "save loaded file_list")
end

do
  local scope = framework.scope:new_scope("cache")
  function scope.before_all()
    virtual_io_util.hook()
  end
  function scope.after_all()
    virtual_io_util.unhook()
  end

  local profile
  local all_inject_scripts
  local file_list
  local next_inject_scripts_id
  local next_inject_scripts_file_modification

  local make_profile
  local make_all_inject_scripts
  local make_file_list

  local function before_each()
    virtual_io_util.new_fs()
    io_util.mkdir_recursive("/test")
    io_util.set_working_dir("/test")
    make_profile{}
    make_all_inject_scripts()
    make_file_list()
    next_inject_scripts_id = 0
    next_inject_scripts_file_modification = 0
  end

  local function save_cache()
    cache.save(profile, all_inject_scripts, file_list)
  end

  local function load_cache()
    -- no tailcall, they make stack traces so much less readable
    local got_profile, got_file_list, err = cache.load(profile.root_dir, profile.cache_dir)
    return got_profile, got_file_list, err
  end

  local function normalize_filename(filename)
    return Path.combine(profile.root_dir, filename):normalize():str()
  end

  local function get_cache_filename(filename)
    return normalize_filename(Path.new(profile.cache_dir) / filename)
  end

  local function get_metadata_filename()
    return get_cache_filename("phobos_metadata.dat")
  end

  local function assert_save()
    save_cache()
    local got = io_util.exists(get_metadata_filename())
    assert(got, "cache.save did not create the metadata file '"..get_metadata_filename().."'.")
  end

  local function assert_save_load()
    assert_save()
    local got_profile, got_file_list, err = load_cache()
    if not got_profile then
      assert(false, "Failed to load cache: "..err)
    end
    compare_profile(profile, got_profile)
    compare_file_list(file_list, got_file_list)
  end

  local function assert_load_warning(warning_pattern)
    local got_profile, got_file_list, err = load_cache()
    assert.contents_equals({}, {
      profile = got_profile,
      file_list = got_file_list,
    }, "Unexpected success, expected warning with the pattern "..warning_pattern)
    assert.errors_with_pattern(warning_pattern, function()
      error(err)
    end)
  end

  local function add_test(label, func)
    scope:add_test(label, function()
      before_each()
      func()
    end)
  end

  ---@param params NewProfileInternalParams
  function make_profile(params)
    params.name = params.name or "test_profile"
    params.output_dir = params.output_dir or "out"
    params.cache_dir = params.cache_dir or "cache"
    params.root_dir = params.root_dir or io_util.get_working_dir()
    profile = profile_util.new_profile(params)
    ---@diagnostic disable-next-line:undefined-field
    profile.phobos_version = params.phobos_version or phobos_version
  end

  function make_all_inject_scripts()
    all_inject_scripts = {}
  end

  ---adds to `all_inject_scripts`
  local function add_inject_scripts(usage_count)
    local inject_scripts = {
      id = next_inject_scripts_id,
      usage_count = util.debug_assert(usage_count),
      filenames = {},
      required_files = {},
      modification_lut = {},
    }
    all_inject_scripts[#all_inject_scripts+1] = inject_scripts
    next_inject_scripts_id = next_inject_scripts_id + 1
    return inject_scripts
  end

  ---adds to latest in `all_inject_scripts`
  local function add_inject_script(inject_scripts, filename)
    inject_scripts.filenames[#inject_scripts.filenames+1] = normalize_filename(filename)
  end

  ---adds to latest in `all_inject_scripts`
  local function add_inject_script_required_file(inject_scripts, filename)
    filename = normalize_filename(filename)
    local file = {
      filename = filename,
      modification = next_inject_scripts_file_modification,
    }
    next_inject_scripts_file_modification = next_inject_scripts_file_modification + 1
    inject_scripts.required_files[#inject_scripts.required_files+1] = file
    inject_scripts.modification_lut[filename] = file.modification
  end

  function make_file_list()
    file_list = {}
  end

  local function get_source_filename(params)
    local source_filename = util.assert_params_field(params, "source_filename")
    return normalize_filename(source_filename)
  end

  local function get_output_filename(params)
    local output_filename = util.assert_params_field(params, "output_filename")
    return normalize_filename(Path.new(profile.output_dir) / output_filename)
  end

  local function add_compile_file(params)
    file_list[#file_list+1] = {
      action = action_enum.compile,
      source_filename = get_source_filename(params),
      relative_source_filename = util.assert_params_field(params, "relative_source_filename"),
      output_filename = get_output_filename(params),
      source_name = util.assert_params_field(params, "source_name"),
      use_load = util.assert_params_field(params, "use_load"),
      error_message_count = util.assert_params_field(params, "error_message_count"),
      inject_scripts = util.assert_params_field(params, "inject_scripts"),
    }
  end

  local function add_test_compile_file(inject_scripts)
    add_compile_file{
      source_filename = "src/foo.pho",
      relative_source_filename = "foo.pho",
      output_filename = "foo.lua",
      source_name = "@?",
      use_load = true,
      error_message_count = 7,
      inject_scripts = inject_scripts,
    }
  end

  local function add_copy_file(params)
    file_list[#file_list+1] = {
      action = action_enum.copy,
      source_filename = get_source_filename(params),
      output_filename = get_output_filename(params),
    }
  end

  local function add_delete_file(params)
    file_list[#file_list+1] = {
      action = action_enum.delete,
      output_filename = get_output_filename(params),
    }
  end

  add_test("minimal profile, no files", function()
    assert_save_load()
  end)

  add_test("non default profile, no files", function()
    make_profile{
      incremental = false,
      error_message_count = 1000,
      optimizations = profile_util.get_all_optimizations(),
      measure_memory = true,
      use_load = true,
    }
    assert_save_load()
  end)

  add_test("profile with inject scripts and functions which get ignored, no files", function()
    make_profile{
      inject_scripts = {"path to some inject script"},
      on_pre_profile_ran = function() error("some nonsense") end,
      on_post_profile_ran = function() error("even more nonsense") end,
    }
    assert_save_load()
  end)

  add_test("profile with inject_scripts with usage_count 0 (technically invalid)", function()
    add_inject_scripts(0)
    assert.errors_with_pattern("Attempt to save cache with inject_scripts with usage_count == 0%..*", save_cache)
  end)

  add_test("compile file actions", function()
    local inject_scripts = add_inject_scripts(2)
    add_test_compile_file(inject_scripts)
    add_compile_file{
      source_filename = "src/bar/baz.pho",
      relative_source_filename = "baz.pho",
      output_filename = "bar/baz.lua",
      source_name = "@bar/?",
      use_load = false,
      error_message_count = 10000,
      inject_scripts = inject_scripts,
    }
    assert_save_load()
  end)

  add_test("a copy file action", function()
    add_copy_file{
      source_filename = "src/foo.pho",
      output_filename = "foo.lua",
    }
    assert_save_load()
  end)

  add_test("a delete file action", function()
    add_delete_file{
      output_filename = "delete_me.txt",
    }
    assert_save_load()
  end)

  add_test("invalid file action", function()
    file_list[#file_list+1] = {
      action = 255, -- any larger and we get an out of bounds error for uint8
    }
    assert.errors("Invalid file action '255'.", save_cache)
  end)

  add_test("inject script filenames", function()
    local inject_scripts = add_inject_scripts(1)
    add_inject_script(inject_scripts, "scripts/inject.pho")
    add_inject_script(inject_scripts, "scripts/inject_move.pho")
    add_test_compile_file(inject_scripts)
    assert_save_load()
  end)

  add_test("different inject_scripts for 2 compile file actions", function()
    local inject_scripts_one = add_inject_scripts(1)
    add_inject_script(inject_scripts_one, "scripts/inject.pho")
    local inject_scripts_two = add_inject_scripts(1)
    add_inject_script(inject_scripts_two, "scripts/inject_move.pho")
    add_test_compile_file(inject_scripts_one)
    add_test_compile_file(inject_scripts_two)
    assert_save_load()
  end)

  add_test("inject scripts with required files", function()
    local inject_scripts = add_inject_scripts(1)
    add_inject_script(inject_scripts, "scripts/inject.pho")
    add_inject_script_required_file(inject_scripts, "scripts/inject_lib.pho")
    add_inject_script_required_file(inject_scripts, "scripts/inject_other_lib.pho")
    add_test_compile_file(inject_scripts)
    assert_save_load()
  end)

  add_test("load absent cache", function()
    local got = {load_cache()} -- nil, nil, nil
    assert.contents_equals({}, got, "load results")
  end)

  add_test("load invalid cache, too short to read signature and version", function()
    io_util.write_file(get_metadata_filename(), "????????") -- 8 `?`
    assert_load_warning("Invalid cache metadata, it is too short%.")
  end)

  add_test("load invalid cache signature", function()
    io_util.write_file(get_metadata_filename(), "??????????") -- 10 `?`
    assert_load_warning("Invalid cache metadata signature%.")
  end)

  add_test("load cache with a newer version", function()
    io_util.write_file(get_metadata_filename(), constants.phobos_signature.."\xfe\xff") -- little endian
    assert_load_warning(
      "Cannot load cache version "..(0xfffe).." from a newer version of Phobos%."
    )
  end)

  do
    local function test_cache_too_short(filename)
      assert_save()
      local contents = io_util.read_file(get_cache_filename(filename))
      io_util.write_file(get_cache_filename(filename), contents:sub(1, -2))
      assert_load_warning("Corrupted cache:.*Attempt to read .*")
    end

    add_test("load corrupted cache (too short phobos_metadata.dat)", function()
      test_cache_too_short("phobos_metadata.dat")
    end)

    add_test("load corrupted cache (too short files.dat)", function()
      test_cache_too_short("files.dat")
    end)
  end

  do
    local function test_expected_end_of_binary_data(filename)
      assert_save()
      local contents = io_util.read_file(get_cache_filename(filename))
      io_util.write_file(get_cache_filename(filename), contents.."\0")
      assert_load_warning("Corrupted cache:.*Expected end of binary data in cache file '"..filename.."'%.")
    end

    add_test("load corrupted cache (too long phobos_metadata.dat)", function()
      test_expected_end_of_binary_data("phobos_metadata.dat")
    end)

    add_test("load corrupted cache (too long files.dat)", function()
      test_expected_end_of_binary_data("files.dat")
    end)
  end

  add_test("load corrupted cache (invalid inject script ids)", function()
    local inject_scripts = add_inject_scripts(1)
    all_inject_scripts[#all_inject_scripts] = nil
    add_test_compile_file(inject_scripts)
    assert_save()
    assert_load_warning("Corrupted cache:.*Invalid inject script ids%.")
  end)

  add_test("load corrupted cache (invalid file action)", function()
    add_delete_file{output_filename = "foo"}
    assert_save()
    -- Replace the file action in the binary string with an invalid one.
    -- This relies on the binary layout of the output, so it
    -- might need to be changed in future versions.
    local filename = get_output_filename{output_filename = "foo"}
    local ser = binary.new_serializer()
    ser:write_uint8(255)
    ser:write_string(filename)
    local replacement_str = ser:tostring()
    local contents = io_util.read_file(get_cache_filename("files.dat"))
    contents = contents:sub(1, -#replacement_str - 1)..replacement_str
    io_util.write_file(get_cache_filename("files.dat"), contents)
    assert_load_warning("Corrupted cache:.*Invalid file action '255'%.")
  end)
end
