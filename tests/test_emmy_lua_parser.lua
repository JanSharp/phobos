
local framework = require("test_framework")
local assert = require("assert")
local do_not_compare = assert.do_not_compare_flag

local parser = require("parser")
local jump_linker = require("jump_linker")
local emmy_lua_parser = require("emmy_lua_parser")
local error_code_util = require("error_code_util")
local codes = error_code_util.codes
local util = require("util")

local tutil = require("testing_util")
local test_source = tutil.test_source

local function new_error(error_code, message_args, position, stop_position)
  return error_code_util.new_error_code{
    error_code = error_code,
    message_args = message_args,
    source = test_source,
    start_position = position or do_not_compare,
    stop_position = stop_position or position or do_not_compare,
    location_str = position and (" at "..position.line..":"..position.column) or do_not_compare,
  }
end

local function expected_blank(position)
  return new_error(codes.el_expected_blank, nil, position)
end

local function expected_ident(position)
  return new_error(codes.el_expected_ident, nil, position)
end

local function expected_pattern(pattern, position)
  return new_error(codes.el_expected_pattern, {pattern}, position)
end

local function expected_special_tag(expected_tag, got_tag, start_position, stop_position)
  return new_error(codes.el_expected_special_tag, {expected_tag, got_tag}, start_position, stop_position)
end

local function expected_type(position)
  return new_error(codes.el_expected_type, nil, position)
end

local function expected_eol(position)
  return new_error(codes.el_expected_eol, nil, position)
end

local parse
local parse_invalid
do
  local function parse_internal(text)
    local ast = parser(text, test_source)
    jump_linker(ast)
    return emmy_lua_parser(ast)
  end

  function parse(text)
    local result, errors = parse_internal(text)
    assert.equals(nil, errors[1], "EmmyLua syntax errors")
    return result
  end

  function parse_invalid(text)
    local result, errors = parse_internal(text)
    assert.equals(nil, result[1], "main result")
    return errors
  end
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

local function new_type(type)
  type.start_position = type.start_position or do_not_compare
  type.stop_position = type.stop_position or do_not_compare
  return type
end

local function new_any()
  return new_type{
    type_type = "reference",
    type_name = "any",
  }
end

local function new_field(field)
  field.description = field.description or {}
  field.optional = field.optional or false
  field.field_type = field.field_type or new_any()
  return field
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

  do
    local function test_function_sequence_positions(text)
      local got = parse(text)
      assert.contents_equals({
        new_func_seq{
          description = {"foo", "hello"},
          node = do_not_compare,
          start_position = new_pos(1, 2),
          stop_position = new_pos(2, 8),
        },
      }, got)
    end

    scope:add_test("function sequence positions (localfunc)", function()
      test_function_sequence_positions(" ---foo\n---hello\nlocal function bar() end")
    end)

    scope:add_test("function sequence positions (funcstat)", function()
      test_function_sequence_positions(" ---foo\n---hello\nfunction bar() end")
    end)
  end

  scope:add_test("none sequence with @diagnostic (testing read_block)", function()
    local got = parse("---@diagnostic foo bar baz\n---hello\n---@diagnostic f\n\z
      ---world!\n---@diagnostic one\n---@diagnostic two"
    )
    assert.contents_equals({new_none{"hello", "world!"}}, got)
  end)

  -- class sequence

  scope:add_test("class seq", function()
    local got = parse("---@class foo")
    assert.contents_equals({new_class{type_name = "foo"}}, got)
  end)

  scope:add_test("class seq with extra space (testing parse_blank)", function()
    local got = parse("---@class \t  foo")
    assert.contents_equals({new_class{type_name = "foo"}}, got)
  end)

  scope:add_test("class seq with description", function()
    local got = parse("---hi\n---you\n---@class foo")
    assert.contents_equals({new_class{description = {"hi", "you"}, type_name = "foo"}}, got)
  end)

  scope:add_test("class seq with trailing space", function()
    local got = parse("---@class foo ")
    assert.contents_equals({new_class{type_name = "foo"}}, got)
  end)

  scope:add_test("class seq with base class", function()
    local got = parse("---@class foo : bar")
    assert.contents_equals({
      new_class{
        type_name = "foo",
        base_classes = {new_type{
          type_type = "reference",
          type_name = "bar",
          start_position = new_pos(1, 17),
          stop_position = new_pos(1, 19),
        }},
      },
    }, got)
  end)

  scope:add_test("class seq with base classes with spaces everywhere", function()
    local got = parse("---@class foo : bar , baz , bat ")
    assert.contents_equals({
      new_class{
        type_name = "foo",
        base_classes = {
          new_type{
            type_type = "reference",
            type_name = "bar",
            start_position = new_pos(1, 17),
            stop_position = new_pos(1, 19),
          },
          new_type{
            type_type = "reference",
            type_name = "baz",
            start_position = new_pos(1, 23),
            stop_position = new_pos(1, 25),
          },
          new_type{
            type_type = "reference",
            type_name = "bat",
            start_position = new_pos(1, 29),
            stop_position = new_pos(1, 31),
          },
        },
      },
    }, got)
  end)

  scope:add_test("class seq with base classes without spaces anywhere", function()
    local got = parse("---@class foo:bar,baz")
    assert.contents_equals({
      new_class{
        type_name = "foo",
        base_classes = {
          new_type{
            type_type = "reference",
            type_name = "bar",
            start_position = new_pos(1, 15),
            stop_position = new_pos(1, 17),
          },
          new_type{
            type_type = "reference",
            type_name = "baz",
            start_position = new_pos(1, 19),
            stop_position = new_pos(1, 21),
          },
        },
      },
    }, got)
  end)

  local function class_with_fields(fields)
    return new_class{
      type_name = "foo",
      fields = fields,
    }
  end

  scope:add_test("class seq with field", function()
    local got = parse("---@class foo\n---@field bar any")
    assert.contents_equals({class_with_fields{new_field{name = "bar"}}}, got)
  end)

  scope:add_test("class seq with field with trailing space", function()
    local got = parse("---@class foo\n---@field bar any ")
    assert.contents_equals({class_with_fields{new_field{name = "bar"}}}, got)
  end)

  scope:add_test("class seq with field with block description", function()
    local got = parse("---@class foo\n---hello\n---world\n---@field bar any")
    assert.contents_equals({class_with_fields{
      new_field{description = {"hello", "world"}, name = "bar"},
    }}, got)
  end)

  scope:add_test("class seq with optional field with spaces everywhere", function()
    local got = parse("---@class foo\n---@field bar ? any")
    assert.contents_equals({class_with_fields{new_field{name = "bar", optional = true}}}, got)
  end)

  scope:add_test("class seq with optional field without spaces anywhere", function()
    local got = parse("---@class foo\n---@field bar?any")
    assert.contents_equals({class_with_fields{new_field{name = "bar", optional = true}}}, got)
  end)

  scope:add_test("class seq with field with inline description with spaces everywhere", function()
    local got = parse("---@class foo\n---@field bar any @ hello world")
    assert.contents_equals({class_with_fields{
      new_field{description = {"hello world"}, name = "bar"},
    }}, got)
  end)

  scope:add_test("class seq with field with inline description without spaces anywhere", function()
    local got = parse("---@class foo\n---@field bar any@hello world")
    assert.contents_equals({class_with_fields{
      new_field{description = {"hello world"}, name = "bar"},
    }}, got)
  end)

  scope:add_test("class seq with field with empty inline description", function()
    local got = parse("---@class foo\n---@field bar any @ ")
    assert.contents_equals({class_with_fields{
      new_field{description = {""}, name = "bar"},
    }}, got)
  end)

  scope:add_test("class seq with 2 fields", function()
    local got = parse("---@class foo\n---@field bar any\n---@field baz any")
    assert.contents_equals({class_with_fields{
      new_field{name = "bar"},
      new_field{name = "baz"},
    }}, got)
  end)

  scope:add_test("class seq with first field with inline description and second field with block description", function()
    local got = parse("---@class foo\n---@field bar any @ inline\n---block\n---@field baz any")
    assert.contents_equals({class_with_fields{
      new_field{description = {"inline"}, name = "bar"},
      new_field{description = {"block"}, name = "baz"},
    }}, got)
  end)

  scope:add_test("class seq without space after tag", function()
    local got = parse_invalid("---@class")
    assert.contents_equals({expected_blank(new_pos(1, 10))}, got)
  end)

  scope:add_test("class seq without type_name", function()
    local got = parse_invalid("---@class ")
    assert.contents_equals({expected_ident(new_pos(1, 11))}, got)
  end)

  scope:add_test("class seq with extra text that isn't ':'", function()
    local got = parse_invalid("---@class foo f")
    assert.contents_equals({expected_pattern(":", new_pos(1, 15))}, got)
  end)

  scope:add_test("class seq with base class that isn't an identifier", function()
    local got = parse_invalid("---@class foo : !")
    assert.contents_equals({expected_ident(new_pos(1, 17))}, got)
  end)

  scope:add_test("class seq with extra text after first base class that isn't ','", function()
    local got = parse_invalid("---@class foo : bar !")
    assert.contents_equals({expected_pattern(",", new_pos(1, 21))}, got)
  end)

  scope:add_test("class seq with invalid field special tag", function()
    local got = parse_invalid("---@class foo\n---@fld")
    assert.contents_equals({expected_special_tag("field", "fld", new_pos(2, 4), new_pos(2, 7))}, got)
  end)

  scope:add_test("class seq with field without space after special tag", function()
    local got = parse_invalid("---@class foo\n---@field")
    assert.contents_equals({expected_blank(new_pos(2, 10))}, got)
  end)

  scope:add_test("class seq with field without field name", function()
    local got = parse_invalid("---@class foo\n---@field ")
    assert.contents_equals({expected_ident(new_pos(2, 11))}, got)
  end)

  scope:add_test("class seq with field without space after field name", function()
    local got = parse_invalid("---@class foo\n---@field bar")
    assert.contents_equals({expected_blank(new_pos(2, 14))}, got)
  end)

  scope:add_test("class seq with field without field_type", function()
    local got = parse_invalid("---@class foo\n---@field bar ")
    assert.contents_equals({expected_type(new_pos(2, 15))}, got)
  end)

  scope:add_test("class seq with field with block description with '@' after field_type", function()
    local got = parse_invalid("---@class foo\n---hello world!\n---@field bar any @")
    assert.contents_equals({expected_eol(new_pos(3, 19))}, got)
  end)

  scope:add_test("class seq with field without block description with extra text that isn't '@'", function()
    local got = parse_invalid("---@class foo\n---@field bar any !")
    assert.contents_equals({expected_pattern("@", new_pos(2, 19))}, got)
  end)

  -- TODO: test alias sequence
  -- TODO: test function sequence
  -- TODO: test literal types
  -- TODO: test dictionary types
  -- TODO: test reference types
  -- TODO: test function types
  -- TODO: test array types
  -- TODO: test union types
  -- TODO: test error messages and their positions
end
