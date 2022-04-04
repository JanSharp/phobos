
local framework = require("test_framework")
local assert = require("assert")
local do_not_compare = assert.do_not_compare_flag

local parser = require("parser")
local jump_linker = require("jump_linker")
local emmy_lua_parser = require("emmy_lua_parser")
local error_code_util = require("error_code_util")

local tutil = require("testing_util")
local test_source = tutil.test_source

local function parse(text)
  local ast = parser(text, test_source)
  jump_linker(ast)
  return emmy_lua_parser(ast)
end

local function new_none(description, node, start_position, stop_position)
  return {
    sequence_type = "none",
    description = description,
    node = node,
    source = test_source,
    start_position = start_position or do_not_compare,
    stop_position = stop_position or do_not_compare,
  }
end

local function new_func_seq(params)
  return {
    sequence_type = "function",
    type_type = "function",
    description = params.description or {},
    params = params.params or {},
    returns = params.returns or {},
    node = params.node,
    source = test_source,
    start_position = params.start_position or do_not_compare,
    stop_position = params.stop_position or do_not_compare,
  }
end

local function assert_associated_node(expected_node_type, got)
  assert(got[1].node, "missing associated node")
  assert.equals(expected_node_type, got[1].node.node_type, "node.node_type")
end

do
  local scope = framework.scope:new_scope("emmy_lua_parser")

  do
    local seq_scope = scope:new_scope("sequence_detection")

    seq_scope:add_test("block comments are not sequences", function()
      local got = parse("--[[foo]] --[[-bar]]")
      assert.equals(nil, got[1], "first sequence")
    end)

    seq_scope:add_test("double dash comments are not sequences", function()
      local got = parse("-- foo")
      assert.equals(nil, got[1], "first sequence")
    end)

    seq_scope:add_test("none sequence", function()
      local got = parse("---foo")
      assert.contents_equals({new_none{"foo"}}, got)
    end)

    seq_scope:add_test("3 line sequence", function()
      local got = parse("---foo\n---bar\n---baz")
      assert.contents_equals({new_none{"foo", "bar", "baz"}}, got)
    end)

    seq_scope:add_test("2 none sequences, blank line in between", function()
      local got = parse("---foo\n\n---bar")
      assert.contents_equals({new_none{"foo"}, new_none{"bar"}}, got)
    end)

    seq_scope:add_test("block comments break sequences", function()
      local got = parse("---foo\n--[[break]] ---bar\n---baz")
      assert.contents_equals({new_none{"foo"}, new_none{"bar", "baz"}}, got)
    end)

    seq_scope:add_test("double dash comments break sequences", function()
      local got = parse("---foo\n-- break\n---bar")
      assert.contents_equals({new_none{"foo"}, new_none{"bar"}}, got)
    end)

    seq_scope:add_test("unrelated nodes break sequences (without extra blanks)", function()
      local got = parse("---foo\n;---bar")
      assert.contents_equals({new_none{"foo"}, new_none{"bar"}}, got)
    end)

    seq_scope:add_test("unrelated nodes break sequences (with blank after node)", function()
      local got = parse("---foo\n; ---bar")
      assert.contents_equals({new_none{"foo"}, new_none{"bar"}}, got)
    end)

    seq_scope:add_test("unrelated nodes break sequences (with blank before node)", function()
      local got = parse("---foo\n ;---bar")
      assert.contents_equals({new_none{"foo"}, new_none{"bar"}}, got)
    end)

    seq_scope:add_test("unrelated nodes break sequences (with blank before and after node)", function()
      local got = parse("---foo\n ; ---bar")
      assert.contents_equals({new_none{"foo"}, new_none{"bar"}}, got)
    end)

    seq_scope:add_test("none sequence associated with localstat", function()
      local got = parse("---foo\nlocal bar")
      assert.contents_equals({new_none({"foo"}, do_not_compare)}, got)
      assert_associated_node("localstat", got)
    end)

    seq_scope:add_test("none sequence with blank line between it and localstat (not associated)", function()
      local got = parse("---foo\n\nlocal bar")
      assert.equals(nil, got[1].node, "node")
    end)

    seq_scope:add_test("unrelated node between sequence and localstat (not associated)", function()
      local got = parse("---foo\n;local bar")
      assert.equals(nil, got[1].node, "node")
    end)

    seq_scope:add_test("function sequence associated with funcstat", function()
      local got = parse("---foo\nfunction bar() end")
      assert.contents_equals({new_func_seq{description = {"foo"}, node = do_not_compare}}, got)
      assert_associated_node("funcstat", got)
    end)

    seq_scope:add_test("unrelated node between sequence and funcstat (not associated)", function()
      local got = parse("---foo\n;function bar() end")
      assert.equals(nil, got[1].node, "node")
    end)

    seq_scope:add_test("function sequence associated with localfunc", function()
      local got = parse("---foo\nlocal function bar() end")
      assert.contents_equals({new_func_seq{description = {"foo"}, node = do_not_compare}}, got)
      assert_associated_node("localfunc", got)
    end)

    seq_scope:add_test("unrelated node between sequence and localfunc (not associated)", function()
      local got = parse("---foo\n;local function bar() end")
      assert.equals(nil, got[1].node, "node")
    end)
  end -- end sequence_detection
end
