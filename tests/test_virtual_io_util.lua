
local framework = require("test_framework")
local assert = require("assert")

local virtual_io_util = require("lib.virtual_io_util")
local Path = require("lib.path")
local io_util = require("io_util")
local vfs = require("lib.virtual_file_system")
local util = require("util")

do
  local scope = framework.scope:new_scope("virtual_io_util")
  function scope.before_all()
    virtual_io_util.hook()
  end
  function scope.after_all()
    virtual_io_util.unhook()
  end

  ---@type VirtualFileSystem
  local fs

  local function setup_new_fs()
    virtual_io_util.new_fs()
    fs = (nil)--[[@as VirtualFileSystem]]
    ---cSpell:ignore nups
    for i = 1, debug.getinfo(virtual_io_util.new_fs, "u").nups do
      local _, upval_value = debug.getupvalue(virtual_io_util.new_fs, i)
      if type(upval_value) == "table" and getmetatable(upval_value) == vfs.FS then
        fs = upval_value
        break
      end
    end
    util.debug_assert(fs, "Unable to get the internal virtual file system from the virtual_io_util.")
  end

  local get_path
  local function add_test(label, func)
    scope:add_test(label.." (string paths)", function()
      setup_new_fs()
      get_path = function(path)
        return path
      end
      func()
    end)
    scope:add_test(label.." (Path paths)", function()
      setup_new_fs()
      get_path = function(path)
        return Path.new(path)
      end
      func()
    end)
    scope:add_test(label.." (Missing paths)", function()
      setup_new_fs()
      get_path = function()
        return nil
      end
      assert.errors("Missing path argument%.", func)
    end)
  end

  add_test("mkdir_recursive 2 dirs", function()
    io_util.mkdir_recursive(get_path("/foo/bar"))
    local got_first = fs:exists("/foo")
    local got_second = fs:exists("/foo/bar")
    assert.equals(true, got_first, "existence of first dir")
    assert.equals(true, got_second, "existence of second dir")
  end)

  add_test("mkdir_recursive where a part of the path already exists", function()
    fs:add_dir("/foo")
    io_util.mkdir_recursive(get_path("/foo/bar"))
    local got = fs:exists("/foo/bar")
    assert.equals(true, got, "existence of dir")
  end)

  add_test("mkdir_recursive where dir already exists", function()
    fs:add_dir("/foo")
    io_util.mkdir_recursive(get_path("/foo"))
    local got_first = fs:exists("/foo")
    assert.equals(true, got_first, "existence of dir")
  end)

  add_test("rmdir_recursive empty dir", function()
    fs:add_dir("/foo")
    io_util.rmdir_recursive(get_path("/foo"))
    local got = fs:exists("/foo")
    assert.equals(false, got, "existence of removed dir")
  end)

  add_test("rmdir_recursive dir with 1 dir and 1 file", function()
    fs:add_dir("/foo")
    fs:add_dir("/foo/bar")
    fs:add_file("/foo/baz")
    io_util.rmdir_recursive(get_path("/foo"))
    local got = fs:exists("/foo")
    assert.equals(false, got, "existence of removed dir")
  end)

  add_test("rmdir_recursive dir with a symlink to a dir", function()
    fs:add_dir("/foo")
    fs:add_dir("/bar")
    fs:add_file("/bar/baz")
    fs:add_symlink("/bar", "/foo/bat")
    io_util.rmdir_recursive(get_path("/foo"))
    local got = fs:exists("/foo")
    local got_bar_baz = fs:exists("/bar/baz")
    assert.equals(false, got, "existence of removed dir")
    assert.equals(true, got_bar_baz, "the linked directory should still contain its contents")
  end)

  add_test("attempt to rmdir_recursive non existent dir", function()
    assert.errors("No such file or directory '/foo'%.", function()
      io_util.rmdir_recursive(get_path("/foo"))
    end)
  end)

  add_test("read_file", function()
    fs:add_file("/foo")
    fs:set_contents("/foo", "hello world")
    local got = io_util.read_file(get_path("/foo"))
    assert.equals("hello world", got, "contents")
  end)

  add_test("write_file to existing file", function()
    fs:add_file("/foo")
    io_util.write_file(get_path("/foo"), "hello world")
    local got = fs:get_contents("/foo")
    assert.equals("hello world", got, "contents after writing")
  end)

  add_test("write_file creating the file in the process", function()
    fs:add_dir("/foo")
    io_util.write_file(get_path("/foo/bar"), "hello world")
    local got = fs:get_contents("/foo/bar")
    assert.equals("hello world", got, "contents after writing")
  end)

  add_test("write_file creating the parent dir in the process", function()
    io_util.write_file(get_path("/foo/bar"), "hello world")
    local got = fs:get_contents("/foo/bar")
    assert.equals("hello world", got, "contents after writing")
  end)

  add_test("delete_file", function()
    fs:add_dir("/foo")
    io_util.delete_file(get_path("/foo"))
    local got = fs:exists("/foo")
    assert.equals(false, got, "existence of the supposed-to-be-deleted file")
  end)

  do
    local function assert_target_file(prev_modification)
      local got = fs:exists("/bar")---@type boolean|string
      assert.equals(true, got, "target file existence")
      got = fs:get_entry_type("/bar", true)
      assert.equals("file", got, "target file entry type")
      got = fs:get_contents("bar")
      assert.equals("hi", got, "target file contents")
      got = fs:get_modification("/bar")
      assert.not_equals(prev_modification, got, "modification of new file should be different")
    end

    add_test("copy file", function()
      fs:add_file("/foo")
      fs:set_contents("/foo", "hi")
      local modification = fs:get_modification("/foo")
      io_util.copy(get_path("/foo"), get_path("/bar"))
      assert_target_file(modification)
    end)

    add_test("copy symlink to file", function()
      fs:add_file("/baz")
      fs:set_contents("/baz", "hi")
      fs:add_symlink("/baz", "/foo")
      local modification = fs:get_modification("/foo")
      io_util.copy(get_path("/foo"), get_path("/bar"))
      assert_target_file(modification)
    end)

    add_test("move file", function()
      fs:add_file("/foo")
      fs:set_contents("/foo", "hi")
      local modification = fs:get_modification("/foo")
      io_util.move(get_path("/foo"), get_path("/bar"))
      local got = fs:exists("/foo")
      assert.equals(false, got, "existence of source file")
      assert_target_file(modification)
    end)

    add_test("move symlink to file", function()
      fs:add_file("/baz")
      fs:set_contents("/baz", "hi")
      fs:add_symlink("/baz", "/foo")
      local modification = fs:get_modification("/foo")
      io_util.move(get_path("/foo"), get_path("/bar"))
      local got = fs:exists("/foo")
      assert.equals(false, got, "existence of source symlink")
      assert_target_file(modification)
    end)
  end

  add_test("symlink", function()
    io_util.symlink(get_path("/foo"), get_path("/bar"))
    local got = fs:get_entry_type("/bar", true)
    assert.equals("symlink", got, "created entry type")
  end)

  add_test("exists", function()
    fs:add_file("/foo")
    local got_true = io_util.exists(get_path("/foo"))
    local got_false = io_util.exists(get_path("/bar"))
    assert.equals(true, got_true)
    assert.equals(false, got_false)
  end)

  add_test("enumerate", function()
    fs:add_file("/foo")
    local did_enter_loop = false
    for entry in io_util.enumerate(get_path("/")) do
      did_enter_loop = true
      assert.equals("foo", entry)
    end
    assert(did_enter_loop, "did not enter loop")
  end)

  add_test("set_working_dir", function()
    fs:add_dir("/foo")
    io_util.set_working_dir(get_path("/foo"))
    local got = fs:get_cwd()
    assert.equals("/foo", got, "working dir")
  end)

  -- note the use of scope:add_test because this is not using get_path
  scope:add_test("get_working_dir", function()
    setup_new_fs() -- again note this for the same reason
    fs:add_dir("/foo")
    fs:set_cwd("/foo")
    local got = io_util.get_working_dir()
    assert.equals("/foo", got, "working dir")
  end)

  -- again scope:add_test, see above
  scope:add_test("get_working_dir_path", function()
    setup_new_fs()
    fs:add_dir("/foo")
    fs:set_cwd("/foo")
    local got = io_util.get_working_dir_path()
    assert.contents_equals(Path.new("/foo"), got, "working dir path object")
  end)

  add_test("get_modification", function()
    local got_first = io_util.get_modification(get_path("/"))
    fs:add_file("/foo")
    local got_second = io_util.get_modification(get_path("/foo"))
    assert.equals(0, got_first, "modification of root before anything happened")
    assert.equals(1, got_second, "modification of a file created afterwards")
  end)

  scope:add_test("Path.enumerate", function()
    setup_new_fs()
    fs:add_file("/foo")
    local count = 0
    for entry in Path.new("/"):enumerate() do
      count = count + 1
      assert.equals("foo", entry)
    end
    assert.equals(1, count, "iteration count")
  end)

  scope:add_test("Path.enumerate with 2 entry", function()
    setup_new_fs()
    fs:add_file("bar")
    fs:add_file("foo")
    local count = 0
    for entry in Path.new("/"):enumerate() do
      count = count + 1
      if count == 1 then
        assert.equals("bar", entry, "second entry name")
      else
        assert.equals("foo", entry, "first entry name")
      end
    end
    assert.equals(2, count, "iteration count")
  end)

  do
    local function setup_fs_for_attr_tests()
      setup_new_fs()
      fs:add_file("/foo") -- modification 1
      fs:add_symlink("/foo", "/bar") -- modification 2
    end

    scope:add_test("Path.attr mode", function()
      setup_fs_for_attr_tests()
      local got = Path.new("/bar"):attr("mode")
      assert.equals("file", got, "mode of symlink to file")
    end)

    scope:add_test("Path.sym_attr mode", function()
      setup_fs_for_attr_tests()
      local got = Path.new("/bar"):sym_attr("mode")
      assert.equals("link", got, "mode of symlink to file")
    end)

    scope:add_test("Path.attr modification", function()
      setup_fs_for_attr_tests()
      local got = Path.new("/bar"):attr("modification")
      assert.equals(1, got, "modification of symlink to file")
    end)

    scope:add_test("Path.sym_attr modification", function()
      setup_fs_for_attr_tests()
      local got = Path.new("/bar"):sym_attr("modification")
      assert.equals(2, got, "modification of symlink to file")
    end)

    scope:add_test("Path.attr dev", function()
      setup_fs_for_attr_tests()
      local got = Path.new("/bar"):attr("dev")
      assert.equals(1, got, "dev of symlink to file")
    end)

    scope:add_test("Path.sym_attr dev", function()
      setup_fs_for_attr_tests()
      local got = Path.new("/bar"):sym_attr("dev")
      assert.equals(1, got, "dev of symlink to file")
    end)
  end

  scope:add_test("Path.sym_attr dev", function()
    setup_new_fs()
    fs:add_file("/foo")
    local got_true = Path.new("/foo"):exists()
    local got_false = Path.new("/bar"):exists()
    assert.equals(true, got_true, "existing file")
    assert.equals(false, got_false, "non existing file")
  end)

  scope:add_test("Path.to_fully_qualified using lfs.currentdir", function()
    setup_new_fs()
    fs:add_dir("/foo")
    fs:set_cwd("/foo")
    local got = Path.new("bar"):to_fully_qualified()
    assert.contents_equals(Path.new("/foo/bar"), got, "fully qualified path")
  end)
end
