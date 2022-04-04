
local framework = require("test_framework")
local assert = require("assert")
local do_not_compare = assert.do_not_compare_flag

local parser = require("parser")
local jump_linker = require("jump_linker")
local emmy_lua_parser = require("emmy_lua_parser")
local error_code_util = require("error_code_util")
local util = require("util")

local tutil = require("testing_util")
local test_source = tutil.test_source

local function parse(text)
  local ast = parser(text, test_source)
  jump_linker(ast)
  return emmy_lua_parser(ast)
end

local function new_pos(line, column)
  return {
    line = line,
    column = column,
  }
end

local function new_none(description, node, start_position, stop_position)
  return {
    sequence_type = "none",
    description = assert(description),
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

---cSpell:ignore dteci

local new_class
local new_alias

do
  local function new_type_defining_sequence(sequence_type, params)
    assert(params.type_name)
    local tn_start_position = params.type_name_position
    local tn_stop_position
    if tn_start_position then
      tn_stop_position = util.shallow_copy(tn_start_position)
      tn_stop_position.column = tn_stop_position.column + #params.type_name - 1
    end
    return {
      sequence_type = sequence_type,
      type_name_start_position = tn_start_position or do_not_compare,
      type_name = params.type_name,
      type_name_stop_position = tn_stop_position or do_not_compare,
      node = params.node,
      source = test_source,
      start_position = params.start_position or do_not_compare,
      stop_position = params.stop_position or do_not_compare,
      duplicate_type_error_code_inst = params.dteci,
    }
  end

  function new_class(params)
    local class = new_type_defining_sequence("class", params)
    class.description = params.description or {}
    class.base_classes = params.base_classes or {}
    class.fields = params.fields or {}
    return class
  end

  function new_alias(params)
    local alias = new_type_defining_sequence("alias", params)
    alias.description = params.description or {}
    alias.aliased_type = assert(params.aliased_type)
    return alias
  end
end

local function new_any()
  return {
    type_type = "reference",
    type_name = "any",
    start_position = do_not_compare,
    stop_position = do_not_compare,
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

  scope:add_test("none sequence positions", function()
    local got = parse("---hello\n---foo")
    assert.contents_equals({new_none({"hello", "foo"}, nil, new_pos(1, 1), new_pos(2, 6))}, got)
  end)

  scope:add_test("class sequence positions", function()
    local got = parse(" ---foo\n---@class bar")
    assert.contents_equals({
      new_class{
        description = {"foo"},
        type_name = "bar",
        type_name_position = new_pos(2, 11),
        start_position = new_pos(1, 2),
        stop_position = new_pos(2, 13),
      },
    }, got)
  end)

  scope:add_test("class sequence positions", function()
    local got = parse(" ---foo\n---@class bar")
    assert.contents_equals({
      new_class{
        description = {"foo"},
        type_name = "bar",
        type_name_position = new_pos(2, 11),
        start_position = new_pos(1, 2),
        stop_position = new_pos(2, 13),
      },
    }, got)
  end)

  scope:add_test("alias sequence positions", function()
    local got = parse(" ---foo\n---@alias bar any")
    assert.contents_equals({
      new_alias{
        description = {"foo"},
        type_name = "bar",
        aliased_type = new_any(),
        type_name_position = new_pos(2, 11),
        start_position = new_pos(1, 2),
        stop_position = new_pos(2, 17),
      },
    }, got)
  end)

  scope:add_test("function sequence positions (localfunc)", function()
    local got = parse(" ---foo\n---hello\nlocal function bar() end")
    assert.contents_equals({
      new_func_seq{
        description = {"foo", "hello"},
        node = do_not_compare,
        start_position = new_pos(1, 2),
        stop_position = new_pos(2, 8),
      },
    }, got)
  end)

  scope:add_test("function sequence positions (funcstat)", function()
    local got = parse(" ---foo\n---hello\nfunction bar() end")
    assert.contents_equals({
      new_func_seq{
        description = {"foo", "hello"},
        node = do_not_compare,
        start_position = new_pos(1, 2),
        stop_position = new_pos(2, 8),
      },
    }, got)
  end)

  -- TODO: test error messages and their positions
  -- TODO: test none sequence
  -- TODO: test class sequence
  -- TODO: test alias sequence
  -- TODO: test function sequence
  -- TODO: test literal types
  -- TODO: test dictionary types
  -- TODO: test reference types
  -- TODO: test function types
  -- TODO: test array types
  -- TODO: test union types
end
