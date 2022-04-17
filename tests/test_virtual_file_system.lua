
local framework = require("test_framework")
local assert = require("assert")

local vfs = require("lib.virtual_file_system")

local function assert_entry_type_error(expected_type, got_type, path, got_func)
  assert.errors("Expected entry type '"..expected_type.."', got '"..got_type
    .."' for entry '"..path.."'.", got_func, nil, true
  )
end

do
  local scope = framework.scope:new_scope("virtual_file_system")

  ---@type VirtualFileSystem
  local fs

  local function add_test(name, func)
    scope:add_test(name, function()
      fs = vfs.new_fs()
      func()
    end)
  end

  add_test("get default cwd using get_cwd", function()
    local got = fs:get_cwd()
    assert.equals("/", got)
  end)

  add_test("set_cwd to root and get it", function()
    fs:set_cwd("/")
    local got = fs:get_cwd()
    assert.equals("/", got)
  end)

  add_test("set_cwd to /foo and get it", function()
    fs:add_dir("/foo")
    fs:set_cwd("/foo")
    local got = fs:get_cwd()
    assert.equals("/foo", got)
  end)

  add_test("set_cwd to symlink to /foo and get it", function()
    fs:add_dir("/foo")
    fs:add_symlink("/foo", "/bar")
    fs:set_cwd("/bar")
    local got = fs:get_cwd()
    assert.equals("/bar", got)
  end)

  add_test("set_cwd to symlink to symlink to /foo and get it", function()
    fs:add_dir("/foo")
    fs:add_symlink("/foo", "/bar")
    fs:add_symlink("/bar", "/baz")
    fs:set_cwd("/baz")
    local got = fs:get_cwd()
    assert.equals("/baz", got)
  end)

  add_test("non string path to set_cwd", function()
    assert.errors("Expected string path, got 'nil'%.", function()
      fs:set_cwd()
    end)
  end)

  add_test("invalid path attempting to .. out of root to set_cwd", function()
    assert.errors("Trying to move up an entry.*", function()
      fs:set_cwd("..")
    end)
  end)

  do
    local function test_invalid_symbol(symbol)
      assert.errors("Invalid entry name 'foo"..symbol.."bar', contains '"..symbol.."'.", function()
        fs:set_cwd("foo"..symbol.."bar")
      end, nil, true)
    end

    add_test("invalid path containing '?' to set_cwd", function()
      test_invalid_symbol("?")
    end)
    add_test("invalid path containing '*' to set_cwd", function()
      test_invalid_symbol("*")
    end)
    add_test("invalid path containing '\\' to set_cwd", function()
      test_invalid_symbol("\\")
    end)
  end

  add_test("attempt to set_cwd to file", function()
    fs:add_file("/foo")
    assert_entry_type_error("directory", "file", "/foo", function()
      fs:set_cwd("/foo")
    end)
  end)

  add_test("attempt to set_cwd to symlink to file", function()
    fs:add_file("/foo")
    fs:add_symlink("/foo", "/bar")
    assert_entry_type_error("directory", "file", "/foo", function()
      fs:set_cwd("/bar")
    end)
  end)

  add_test("set_cwd to relative path and get_cwd", function()
    fs:add_dir("/foo")
    fs:set_cwd("foo")
    local got = fs:get_cwd()
    assert.equals("/foo", got)
  end)

  add_test("set_cwd to relative path twice and get_cwd", function()
    fs:add_dir("/foo")
    fs:add_dir("/foo/bar")
    fs:set_cwd("foo")
    fs:set_cwd("bar")
    local got = fs:get_cwd()
    assert.equals("/foo/bar", got)
  end)

  add_test("add_file and check using get_entry_type", function()
    fs:add_file("/foo")
    local got = fs:get_entry_type("/foo")
    assert.equals("file", got, "entry type")
  end)

  add_test("get_contents of new file", function()
    fs:add_file("/foo")
    local got = fs:get_contents("/foo")
    assert.equals("", got)
  end)

  add_test("set_contents and get_contents", function()
    fs:add_file("/foo")
    fs:set_contents("/foo", "hello world!")
    local got = fs:get_contents("/foo")
    assert.equals("hello world!", got)
  end)

  add_test("attempt to add_file '/'", function()
    assert.errors("Attempt to add/create root%.", function()
      fs:add_file("/")
    end)
  end)

  add_test("add_file to symlink to dir", function()
    fs:add_symlink("/", "/foo")
    fs:add_file("/foo/bar")
    local got_normal = fs:get_entry_type("/bar")
    local got_linked = fs:get_entry_type("/foo/bar")
    assert.equals(got_normal, "file")
    assert.equals(got_linked, "file")
  end)

  add_test("add_file that already exists", function()
    fs:add_file("/foo")
    assert.errors("Attempt to create entry 'foo' in '/' which already exists.", function()
      fs:add_file("/foo")
    end)
  end)

  add_test("attempt to add_file to file", function()
    fs:add_file("/foo")
    assert_entry_type_error("directory", "file", "/foo", function()
      fs:add_file("/foo/bar")
    end)
  end)

  add_test("attempt to add_file to symlink to file", function()
    fs:add_file("/foo")
    fs:add_symlink("/foo", "/bar")
    assert_entry_type_error("directory", "file", "/foo", function()
      fs:add_file("/bar/baz")
    end)
  end)

  add_test("add_dir and check using get_entry_type", function()
    fs:add_dir("/foo")
    local got = fs:get_entry_type("/foo")
    assert.equals("directory", got)
  end)

  add_test("add_symlink and check using get_entry_type", function()
    fs:add_symlink("/", "/foo")
    local got = fs:get_entry_type("/foo", true)
    assert.equals("symlink", got)
  end)

  add_test("add_symlink with relative target", function()
    fs:add_dir("/foo")
    fs:add_file("/foo/bar")
    fs:add_symlink("bar", "/foo/baz")
    local got_resolved = fs:get_entry_type("/foo/baz")
    local got_actual = fs:get_entry_type("/foo/baz", true)
    assert.equals("file", got_resolved, "symlink target")
    assert.equals("symlink", got_actual, "symlink itself")
  end)

  add_test("add_symlink with invalid old name", function()
    assert.errors("Invalid entry name.*", function()
      fs:add_symlink("?", "/foo")
    end)
  end)

  add_test("add_symlink using .. in relative target", function()
    fs:add_dir("/foo")
    fs:add_file("/bar")
    fs:add_symlink("../bar", "/foo/baz")
    local got_resolved = fs:get_entry_type("/foo/baz")
    local got_actual = fs:get_entry_type("/foo/baz", true)
    assert.equals("file", got_resolved, "symlink target")
    assert.equals("symlink", got_actual, "symlink itself")
  end)

  add_test("add_symlink to invalid location which then becomes valid", function()
    fs:add_symlink("/foo", "/bar")
    fs:add_file("/foo")
    local got = fs:get_entry_type("/bar")
    assert.equals("file", got)
  end)

  add_test("add_symlink to invalid location and try to use it (with get_entry_type)", function()
    fs:add_symlink("/foo", "/bar")
    assert.errors("No such file or directory '/foo'%.", function()
      fs:get_entry_type("/bar")
    end)
  end)

  add_test("add_symlink to invalid location and get_entry_type it without resolving the symlink", function()
    fs:add_symlink("/foo", "/bar")
    local got = fs:get_entry_type("/bar", true)
    assert.equals("symlink", got)
  end)

  add_test("get_contents of symlink to file", function()
    fs:add_file("/foo")
    fs:add_symlink("/foo", "/bar")
    local got = fs:get_contents("/bar")
    assert.equals("", got)
  end)

  add_test("attempt to get_contents of dir", function()
    fs:add_dir("/foo")
    assert_entry_type_error("file", "directory", "/foo", function()
      fs:get_contents("/foo")
    end)
  end)

  add_test("set_contents of symlink to file", function()
    fs:add_file("/foo")
    fs:add_symlink("/foo", "/bar")
    fs:set_contents("bar", "hello")
    local got = fs:get_contents("/foo")
    assert.equals("hello", got)
  end)

  add_test("set_contents to invalid data", function()
    fs:add_file("/foo")
    assert.errors("Expected string contents for a file, got 'nil'%.", function()
      fs:set_contents("/foo", nil)
    end)
  end)

  add_test("attempt to set_contents of dir", function()
    fs:add_dir("/foo")
    assert_entry_type_error("file", "directory", "/foo", function()
      fs:set_contents("/foo", "bar")
    end)
  end)

  add_test("remove file", function()
    fs:add_file("/foo")
    fs:remove("/foo")
    local got = fs:exists("/foo")
    assert.equals(false, got, "exists")
  end)

  add_test("remove dir", function()
    fs:add_dir("/foo")
    fs:remove("/foo")
    local got = fs:exists("/foo")
    assert.equals(false, got, "exists")
  end)

  add_test("remove non empty dir", function()
    fs:add_dir("/foo")
    fs:add_file("/foo/bar")
    assert.errors("Attempt to remove non empty directory '/foo'%.", function()
      fs:remove("/foo")
    end)
  end)

  add_test("remove symlink", function()
    fs:add_symlink("/", "/foo")
    fs:remove("/foo")
    local got = fs:exists("/foo")
    assert.equals(false, got, "exists")
  end)

  add_test("file exists", function()
    fs:add_file("/foo")
    local got = fs:exists("/foo")
    assert.equals(true, got, "exists")
  end)

  add_test("dir exists", function()
    fs:add_dir("/foo")
    local got = fs:exists("/foo")
    assert.equals(true, got, "exists")
  end)

  add_test("symlink exists", function()
    fs:add_symlink("/", "/foo")
    local got = fs:exists("/foo")
    assert.equals(true, got, "exists")
  end)

  add_test("get_modification of root", function()
    local got = fs:get_modification("/")
    assert.equals(0, got, "modification")
  end)

  add_test("add_file and get_modification of it", function()
    fs:add_file("/foo") -- 1
    local got = fs:get_modification("/foo")
    assert.equals(1, got, "modification")
  end)

  add_test("set_contents modifies file", function()
    fs:add_file("/foo") -- 1
    fs:set_contents("/foo", "hi") -- 2
    local got = fs:get_modification("/foo")
    assert.equals(2, got, "modification")
  end)

  add_test("get_contents doesn't modify file", function()
    fs:add_file("/foo") -- 1
    fs:get_contents("/foo")
    local got = fs:get_modification("/foo")
    assert.equals(1, got, "modification")
  end)

  add_test("add_dir and get_modification of it", function()
    fs:add_dir("/foo") -- 1
    local got = fs:get_modification("/foo")
    assert.equals(1, got, "modification")
  end)

  add_test("adding an entry to a dir modifies the dir", function()
    fs:add_dir("/foo") -- 1
    fs:add_file("/foo/bar") -- 2
    local got = fs:get_modification("/foo")
    assert.equals(2, got, "modification")
  end)

  add_test("removing an entry from a dir modifies the dir", function()
    fs:add_dir("/foo") -- 1
    fs:add_file("/foo/bar") -- 2
    fs:remove("/foo/bar") -- 3
    local got = fs:get_modification("/foo")
    assert.equals(3, got, "modification")
  end)

  add_test("attempt to remove root", function()
    assert.errors("Attempt to remove root%.", function()
      fs:remove("/")
    end)
  end)

  add_test("add_symlink and get_modification of it", function()
    fs:add_file("/foo") -- 1
    fs:add_symlink("/foo", "/bar") -- 2
    local got = fs:get_modification("/bar") -- gets /foo
    assert.equals(1, got, "modification")
  end)

  add_test("add_symlink and get_modification of it without following the symlink", function()
    fs:add_file("/foo") -- 1
    fs:add_symlink("/foo", "/bar") -- 2
    local got = fs:get_modification("/bar", true) -- gets /bar
    assert.equals(2, got, "modification")
  end)

  add_test("enumerate empty dir", function()
    for entry in fs:enumerate("/") do
      assert(false, "should not enter this block, got entry '"..entry.."'")
    end
    fs:add_file("/foo") -- should not error
  end)

  add_test("enumerate dir with 1 entry", function()
    fs:add_file("/foo")
    local count = 0
    for entry in fs:enumerate("/") do
      count = count + 1
      assert.equals("foo", entry, "entry name")
    end
    fs:add_file("/bar") -- should not error
    assert.equals(1, count, "iteration count")
  end)

  add_test("enumerate dir with 2 entry", function()
    fs:add_file("/bar")
    fs:add_file("/foo")
    local count = 0
    for entry in fs:enumerate("/") do
      count = count + 1
      if count == 1 then
        assert.equals("bar", entry, "second entry name")
      else
        assert.equals("foo", entry, "first entry name")
      end
    end
    fs:add_file("/baz") -- should not error
    assert.equals(2, count, "iteration count")
  end)

  add_test("enumerate enumerates in alphabetical order", function()
    fs:add_file("/b") -- insert first
    fs:add_file("/a") -- insert as first_child
    fs:add_file("/d") -- insert as last_child
    fs:add_file("/c") -- insert in the middle
    local expected = {"a", "b", "c", "d"}
    local count = 0
    for entry in fs:enumerate("/") do
      count = count + 1
      assert.equals(expected[count], entry, "entry name #"..count)
    end
    fs:add_file("/foo") -- should not error
    assert.equals(4, count, "iteration count")
  end)

  do
    local function test_modification_during_enumeration(func)
      fs:add_dir("/foo")
      local enumerator = fs:enumerate("/foo")
      assert.errors(
        "Attempt to modify directory '/foo' while it is being enumerated by 1 enumerators%.",
        function()
          func()
        end
      )
      enumerator()
      func() -- should not error
    end

    add_test("attempt to remove dir being enumerated", function()
      test_modification_during_enumeration(function()
        fs:remove("/foo")
      end)
    end)

    add_test("attempt to add_file to dir dir being enumerated", function()
      test_modification_during_enumeration(function()
        fs:add_file("/foo/bar")
      end)
    end)

    add_test("attempt to add_dir to dir dir being enumerated", function()
      test_modification_during_enumeration(function()
        fs:add_dir("/foo/bar")
      end)
    end)

    add_test("attempt to add_symlink to dir dir being enumerated", function()
      test_modification_during_enumeration(function()
        fs:add_symlink("/foo", "/foo/bar")
      end)
    end)
  end
end
