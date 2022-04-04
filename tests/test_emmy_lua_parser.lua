
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

local function new_pos(line, column)
  return {
    line = line,
    column = column,
  }
end

local parse
local parse_invalid
local parse_type
local parse_invalid_type
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

  local function parse_type_internal(text, do_not_check_for_trailing_space_consumption)
    local result, errors
    if do_not_check_for_trailing_space_consumption then
      result, errors = parse_internal("---@alias _________ "..text)
      result = result[1] and result[1].aliased_type or nil
    else
      result, errors = parse_internal("---@return          "..text.." foo\nfunction func() end")
      if errors[1] and errors[1].error_code == codes.el_expected_blank then
        -- If parse_type ever uses assert_parse_blank in the future then this check
        -- could be incorrect and a different form of detection must be used.
        assert(false, "The type consumed trailing spaces")
      end
      result = result[1] and result[1].returns[1].return_type or nil
    end
    return result, errors
  end

  ---adds 20 characters at the front
  function parse_type(text, do_not_check_for_trailing_space_consumption)
    local result, errors = parse_type_internal(text, do_not_check_for_trailing_space_consumption)
    assert.equals(nil, errors[1], "EmmyLua syntax errors")
    assert.contents_equals(new_pos(1, 21), result.start_position, "start_position")
    assert.contents_equals(new_pos(1, 20 + #text), result.stop_position, "stop_position")
    return result
  end

  ---adds 20 characters at the front
  function parse_invalid_type(text, do_not_check_for_trailing_space_consumption)
    local result, errors = parse_type_internal(text, do_not_check_for_trailing_space_consumption)
    assert.equals(nil, result, "type result")
    return errors
  end
end

---for type testing when parse_type returns nil specifically.
---This also tests that parse_type reset i correctly by checking the error column info
local function assert_expected_type(got)
  -- 21 because the type parse functions add 20 characters at the front
  assert.contents_equals({expected_type(new_pos(1, 21))}, got)
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

local function new_func_type(params)
  return {
    type_type = "function",
    description = params.description or {},
    params = params.params or {},
    returns = params.returns or {},
    start_position = params.start_position or do_not_compare,
    stop_position = params.stop_position or do_not_compare,
  }
end

local function new_func_seq(params)
  local seq = new_func_type(params)
  seq.sequence_type = "function"
  seq.node = do_not_compare
  seq.source = test_source
  return seq
end

---cSpell:ignore dteci

local new_class
local new_alias

local function new_type(type)
  type.start_position = type.start_position or do_not_compare
  type.stop_position = type.stop_position or do_not_compare
  return type
end

local function new_any(start_position, stop_position)
  return new_type{
    type_type = "reference",
    type_name = "any",
    start_position = start_position,
    stop_position = stop_position,
  }
end

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
    alias.aliased_type = params.aliased_type or new_any()
    return alias
  end
end

local function new_field(field)
  field.description = field.description or {}
  field.optional = field.optional or false
  field.field_type = field.field_type or new_any()
  return field
end

local function new_param(param)
  param.description = param.description or {}
  param.optional = param.optional or false
  param.param_type = param.param_type or new_any()
  return param
end

local function new_return(ret)
  ret.description = ret.description or {}
  ret.optional = ret.optional or false
  ret.return_type = ret.return_type or new_any()
  return ret
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
      assert.contents_equals({new_func_seq{description = {"foo"}}}, got)
      assert_associated_node("funcstat", got)
    end)

    seq_scope:add_test("unrelated node between sequence and funcstat (not associated)", function()
      local got = parse("---foo\n;function bar() end")
      assert.equals(nil, got[1].node, "node")
    end)

    seq_scope:add_test("function sequence associated with localfunc", function()
      local got = parse("---foo\nlocal function bar() end")
      assert.contents_equals({new_func_seq{description = {"foo"}}}, got)
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

  -- alias sequence

  scope:add_test("alias seq", function()
    local got = parse("---@alias foo any")
    assert.contents_equals({new_alias{type_name = "foo"}}, got)
  end)

  scope:add_test("alias seq with description", function()
    local got = parse("---hey\n---you\n---@alias foo any")
    assert.contents_equals({new_alias{description = {"hey", "you"}, type_name = "foo"}}, got)
  end)

  scope:add_test("alias seq with trailing space", function()
    local got = parse("---@alias foo any ")
    assert.contents_equals({new_alias{type_name = "foo"}}, got)
  end)

  scope:add_test("alias seq without space after special tag", function()
    local got = parse_invalid("---@alias")
    assert.contents_equals({expected_blank(new_pos(1, 10))}, got)
  end)

  scope:add_test("alias seq without type_name", function()
    local got = parse_invalid("---@alias ")
    assert.contents_equals({expected_ident(new_pos(1, 11))}, got)
  end)

  scope:add_test("alias seq without space after type_name", function()
    local got = parse_invalid("---@alias foo")
    assert.contents_equals({expected_blank(new_pos(1, 14))}, got)
  end)

  scope:add_test("alias seq without aliased_type", function()
    local got = parse_invalid("---@alias foo ")
    assert.contents_equals({expected_type(new_pos(1, 15))}, got)
  end)

  -- function sequence

  scope:add_test("function seq", function()
    local got = parse("---hi\nfunction func()) end")
    assert.contents_equals({new_func_seq{description = {"hi"}}}, got)
  end)

  scope:add_test("function seq with param", function()
    local got = parse("---@param foo any\nfunction func() end")
    assert.contents_equals({new_func_seq{params = {new_param{name = "foo"}}}}, got)
  end)

  scope:add_test("function seq with param with inline description with spaces everywhere", function()
    local got = parse("---@param foo any @ hello world\nfunction func() end")
    assert.contents_equals({new_func_seq{params = {
      new_param{description = {"hello world"}, name = "foo"},
    }}}, got)
  end)

  scope:add_test("function seq with param with inline description without spaces anywhere", function()
    local got = parse("---@param foo any@hello world\nfunction func() end")
    assert.contents_equals({new_func_seq{params = {
      new_param{description = {"hello world"}, name = "foo"},
    }}}, got)
  end)

  scope:add_test("function seq with param with empty inline description", function()
    local got = parse("---@param foo any@\nfunction func() end")
    assert.contents_equals({new_func_seq{params = {
      new_param{description = {""}, name = "foo"},
    }}}, got)
  end)

  scope:add_test("function seq with param with block description", function()
    local got = parse("---@param foo any @\n---hello\n---world\nfunction func() end")
    assert.contents_equals({new_func_seq{params = {
      new_param{description = {"hello", "world"}, name = "foo"},
    }}}, got)
  end)

  scope:add_test("function seq with param with block description with trailing space on inline line", function()
    local got = parse("---@param foo any @ \n---hello\n---world\nfunction func() end")
    assert.contents_equals({new_func_seq{params = {
      new_param{description = {"hello", "world"}, name = "foo"},
    }}}, got)
  end)

  scope:add_test("function seq with optional param with spaces everywhere", function()
    local got = parse("---@param foo ? any\nfunction func() end")
    assert.contents_equals({new_func_seq{params = {new_param{name = "foo", optional = true}}}}, got)
  end)

  scope:add_test("function seq with optional param without spaces anywhere", function()
    local got = parse("---@param foo?any\nfunction func() end")
    assert.contents_equals({new_func_seq{params = {new_param{name = "foo", optional = true}}}}, got)
  end)

  scope:add_test("function seq with 2 params", function()
    local got = parse("---@param foo any\n---@param bar any\nfunction func() end")
    assert.contents_equals({new_func_seq{params = {
      new_param{name = "foo"},
      new_param{name = "bar"},
    }}}, got)
  end)

  scope:add_test("function seq with param without space after special tag", function()
    local got = parse_invalid("---@param\nfunction func() end")
    assert.contents_equals({expected_blank(new_pos(1, 10))}, got)
  end)

  scope:add_test("function seq with param without name", function()
    local got = parse_invalid("---@param \nfunction func() end")
    assert.contents_equals({expected_ident(new_pos(1, 11))}, got)
  end)

  scope:add_test("function seq with param without space after name", function()
    local got = parse_invalid("---@param foo\nfunction func() end")
    assert.contents_equals({expected_blank(new_pos(1, 14))}, got)
  end)

  scope:add_test("function seq with param without param_type", function()
    local got = parse_invalid("---@param foo \nfunction func() end")
    assert.contents_equals({expected_type(new_pos(1, 15))}, got)
  end)

  scope:add_test("function seq with param with extra text after param_type that isn't '@'", function()
    local got = parse_invalid("---@param foo any !\nfunction func() end")
    assert.contents_equals({expected_pattern("@", new_pos(1, 19))}, got)
  end)

  scope:add_test("function seq with return", function()
    local got = parse("---@return any\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{}}}}, got)
  end)

  scope:add_test("function seq with return with name", function()
    local got = parse("---@return any foo\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{name = "foo"}}}}, got)
  end)

  scope:add_test("function seq with optional return with spaces everywhere", function()
    local got = parse("---@return any ?\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{optional = true}}}}, got)
  end)

  scope:add_test("function seq with optional return without spaces anywhere", function()
    local got = parse("---@return any?\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{optional = true}}}}, got)
  end)

  scope:add_test("function seq with optional return with name with spaces everywhere", function()
    local got = parse("---@return any ? foo\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{name = "foo", optional = true}}}}, got)
  end)

  scope:add_test("function seq with optional return with name without spaces anywhere", function()
    local got = parse("---@return any?foo\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{name = "foo", optional = true}}}}, got)
  end)

  scope:add_test("function seq with return with inline description with spaces everywhere", function()
    local got = parse("---@return any @ hello world\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{description = {"hello world"}}}}}, got)
  end)

  scope:add_test("function seq with return with inline description without spaces anywhere", function()
    local got = parse("---@return any@hello world\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{description = {"hello world"}}}}}, got)
  end)

  scope:add_test("function seq with return with empty inline description", function()
    local got = parse("---@return any @\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{description = {""}}}}}, got)
  end)

  scope:add_test("function seq with return with block description", function()
    local got = parse("---@return any @\n---hello\n---world\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{description = {"hello", "world"}}}}}, got)
  end)

  scope:add_test("function seq with return with block description with trailing space on inline line", function()
    local got = parse("---@return any @ \n---hello\n---world\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{description = {"hello", "world"}}}}}, got)
  end)

  scope:add_test("function seq with 2 returns", function()
    local got = parse("---@return any\n---@return any\nfunction func() end")
    assert.contents_equals({new_func_seq{returns = {new_return{}, new_return{}}}}, got)
  end)

  scope:add_test("function seq with return without space after special tag", function()
    local got = parse_invalid("---@return\nfunction func() end")
    assert.contents_equals({expected_blank(new_pos(1, 11))}, got)
  end)

  scope:add_test("function seq without return_type", function()
    local got = parse_invalid("---@return \nfunction func() end")
    assert.contents_equals({expected_type(new_pos(1, 12))}, got)
  end)

  scope:add_test("function seq with extra text after return_type that isn't '@' nor an identifier", function()
    local got = parse_invalid("---@return any !\nfunction func() end")
    assert.contents_equals({expected_pattern("@", new_pos(1, 16))}, got)
  end)

  scope:add_test("function seq with extra text after name that isn't '@'", function()
    local got = parse_invalid("---@return any foo !\nfunction func() end")
    assert.contents_equals({expected_pattern("@", new_pos(1, 20))}, got)
  end)

  -- literal types

  do
    local function test_literal(text)
      local got = parse_type(text)
      assert.contents_equals(new_type{
        type_type = "literal",
        value = "hello world",
      }, got)
    end

    scope:add_test("literal type using '", function()
      test_literal("'hello world'")
    end)

    scope:add_test("literal type using \"", function()
      test_literal('"hello world"')
    end)

    scope:add_test("literal type using `", function()
      test_literal("`hello world`")
    end)
  end

  scope:add_test("literal type using mixed parens", function()
    local got = parse_invalid_type("'foo\"")
    assert.contents_equals({expected_type(new_pos(1, 21))}, got)
  end)

  -- dictionary types

  scope:add_test("dictionary type with spaces everywhere", function()
    local got = parse_type("table< any , any >")
    assert.contents_equals(new_type{
      type_type = "dictionary",
      key_type = new_any(),
      value_type = new_any(),
    }, got)
  end)

  scope:add_test("dictionary type without spaces anywhere", function()
    local got = parse_type("table<any,any>")
    assert.contents_equals(new_type{
      type_type = "dictionary",
      key_type = new_any(),
      value_type = new_any(),
    }, got)
  end)

  scope:add_test("dictionary type without key_type", function()
    local got = parse_invalid_type("table<", true)
    assert_expected_type(got)
  end)

  scope:add_test("dictionary type without comma", function()
    local got = parse_invalid_type("table<any")
    assert_expected_type(got)
  end)

  scope:add_test("dictionary type without value_type", function()
    local got = parse_invalid_type("table<any,", true)
    assert_expected_type(got)
  end)

  scope:add_test("dictionary type without '>'", function()
    local got = parse_invalid_type("table<any,any")
    assert_expected_type(got)
  end)

  -- reference types

  do
    local function test_reference(type_name)
      local got = parse_type(type_name)
      assert.contents_equals(new_type{
        type_type = "reference",
        type_name = type_name,
      }, got)
    end

    scope:add_test("reference type 'any'", function()
      test_reference("any")
    end)

    scope:add_test("reference type 'table'", function()
      test_reference("table")
    end)
  end

  -- function types

  scope:add_test("function type with space between parens", function()
    local got = parse_type("fun( )")
    assert.contents_equals(new_func_type{}, got)
  end)

  scope:add_test("function type without space between parens", function()
    local got = parse_type("fun()")
    assert.contents_equals(new_func_type{}, got)
  end)

  scope:add_test("function type with param with spaces everywhere", function()
    local got = parse_type("fun( foo : any )")
    assert.contents_equals(new_func_type{params = {new_param{name = "foo"}}}, got)
  end)

  scope:add_test("function type with param without spaces anywhere", function()
    local got = parse_type("fun(foo:any)")
    assert.contents_equals(new_func_type{params = {new_param{name = "foo"}}}, got)
  end)

  scope:add_test("function type with optional param with spaces everywhere", function()
    local got = parse_type("fun( foo ? : any )")
    assert.contents_equals(new_func_type{params = {new_param{name = "foo", optional = true}}}, got)
  end)

  scope:add_test("function type with optional param without spaces anywhere", function()
    local got = parse_type("fun(foo?:any)")
    assert.contents_equals(new_func_type{params = {new_param{name = "foo", optional = true}}}, got)
  end)

  scope:add_test("function type with 2 param with spaces everywhere", function()
    local got = parse_type("fun( foo : any , bar : any )")
    assert.contents_equals(new_func_type{params = {new_param{name = "foo"}, new_param{name = "bar"}}}, got)
  end)

  scope:add_test("function type with 2 param without spaces anywhere", function()
    local got = parse_type("fun(foo:any,bar:any)")
    assert.contents_equals(new_func_type{params = {new_param{name = "foo"}, new_param{name = "bar"}}}, got)
  end)

  scope:add_test("function type with return with spaces everywhere", function()
    local got = parse_type("fun() : any")
    assert.contents_equals(new_func_type{returns = {new_return{}}}, got)
  end)

  scope:add_test("function type with return without spaces anywhere", function()
    local got = parse_type("fun():any")
    assert.contents_equals(new_func_type{returns = {new_return{}}}, got)
  end)

  scope:add_test("function type with optional return with spaces everywhere", function()
    local got = parse_type("fun() : any ?")
    assert.contents_equals(new_func_type{returns = {new_return{optional = true}}}, got)
  end)

  scope:add_test("function type with optional return without spaces anywhere", function()
    local got = parse_type("fun():any?")
    assert.contents_equals(new_func_type{returns = {new_return{optional = true}}}, got)
  end)

  scope:add_test("function type with 2 returns with spaces everywhere", function()
    local got = parse_type("fun() : any , any")
    assert.contents_equals(new_func_type{returns = {new_return{}, new_return{}}}, got)
  end)

  scope:add_test("function type with 2 returns without spaces anywhere", function()
    local got = parse_type("fun():any,any")
    assert.contents_equals(new_func_type{returns = {new_return{}, new_return{}}}, got)
  end)

  scope:add_test("function type without opening '('", function()
    local got = parse_invalid_type("fun")
    assert.contents_equals({expected_pattern("%(", new_pos(1, 24))}, got)
  end)

  scope:add_test("function type without closing ')'", function()
    local got = parse_invalid_type("fun(", true)
    assert.contents_equals({expected_ident(new_pos(1, 25))}, got)
  end)

  scope:add_test("function type with invalid param name", function()
    local got = parse_invalid_type("fun(!)")
    assert.contents_equals({expected_ident(new_pos(1, 25))}, got)
  end)

  scope:add_test("function type with invalid character after param name", function()
    local got = parse_invalid_type("fun(foo!)")
    assert.contents_equals({expected_pattern(":", new_pos(1, 28))}, got)
  end)

  scope:add_test("function type with without param type", function()
    local got = parse_invalid_type("fun(foo:)") -- smile
    assert.contents_equals({expected_type(new_pos(1, 29))}, got)
  end)

  scope:add_test("function type with param but without closing ')'", function()
    local got = parse_invalid_type("fun(foo: any", true)
    assert.contents_equals({expected_pattern("%)", new_pos(1, 33))}, got)
  end)

  scope:add_test("function type with ':' but without return", function()
    local got = parse_invalid_type("fun():", true)
    assert.contents_equals({expected_type(new_pos(1, 27))}, got)
  end)

  -- array types

  scope:add_test("array type", function()
    local got = parse_type("any[]")
    assert.contents_equals(new_type{
      type_type = "array",
      value_type = new_any(new_pos(1, 21), new_pos(1, 23)),
    }, got)
  end)

  scope:add_test("array type of arrays", function()
    local got = parse_type("any[][][]")
    assert.contents_equals(new_type{
      type_type = "array",
      value_type = new_type{
        type_type = "array",
        value_type = new_type{
          type_type = "array",
          value_type = new_any(new_pos(1, 21), new_pos(1, 23)),
          start_position = new_pos(1, 21),
          stop_position = new_pos(1, 25),
        },
        start_position = new_pos(1, 21),
        stop_position = new_pos(1, 27),
      },
    }, got)
  end)

  -- union types

  scope:add_test("union type", function()
    local got = parse_type("any|any")
    assert.contents_equals(new_type{
      type_type = "union",
      union_types = {
        new_any(new_pos(1, 21), new_pos(1, 23)),
        new_any(new_pos(1, 25), new_pos(1, 27)),
      },
    }, got)
  end)

  scope:add_test("union type of 4 types", function()
    local got = parse_type("any|any|any|any")
    assert.contents_equals(new_type{
      type_type = "union",
      union_types = {
        new_any(new_pos(1, 21), new_pos(1, 23)),
        new_any(new_pos(1, 25), new_pos(1, 27)),
        new_any(new_pos(1, 29), new_pos(1, 31)),
        new_any(new_pos(1, 33), new_pos(1, 35)),
      },
    }, got)
  end)

  -- TODO: combination of all the things chained in parse_type
  -- TODO: test error messages and their positions
  -- TODO: test ident parsing
  -- TODO: associated node for classes and aliases
end
