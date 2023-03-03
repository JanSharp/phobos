
local framework = require("test_framework")
local assert = require("assert")
local do_not_compare = assert.do_not_compare_flag

local parser = require("parser")
local jump_linker = require("jump_linker")
local emmy_lua_parser = require("emmy_lua_parser")
local emmy_lua_linker = require("emmy_lua_linker")
local error_code_util = require("error_code_util")
local codes = error_code_util.codes
local util = require("util")
local el_util = require("emmy_lua_util")

local tutil = require("testing_util")
local test_source = tutil.test_source

local function new_error(error_code, message_args, start_position, stop_position)
  return error_code_util.new_error_code{
    error_code = error_code,
    message_args = message_args,
    source = test_source,
    start_position = util.debug_assert(start_position),
    stop_position = util.debug_assert(stop_position),
    location_str = " at "..start_position.line..":"..start_position.column
      .." - "..stop_position.line..":"..stop_position.column
  }
end

local function parse_internal(text)
  local ast = parser(text, test_source)
  jump_linker(ast)
  return emmy_lua_parser(ast)
end

local function parse(text)
  local result, errors = parse_internal(text)
  util.debug_assert(not errors[1], "Invalid EmmyLua annotations")
  return result
end

local function link(sequences)
  local result, errors = emmy_lua_linker(sequences)
  assert.equals(nil, errors[1], "EmmyLua linker errors")
  return result
end

local function link_invalid(sequences)
  return emmy_lua_linker(sequences)
end

local builtin_class_count = 8
local builtin_alias_count = 0

local function get_class(got, index)
  return got.classes[builtin_class_count + index]
end

local function get_alias(got, index)
  return got.aliases[builtin_alias_count + index]
end

local function get_seq(got, name)
  return got.all_types_lut[name]
end

local function get_any(got)
  return get_seq(got, "any")
end

do
  local scope = framework.scope:new_scope("emmy_lua_linker")

  do
    local function assert_builtin(got, name)
      local expected = el_util.new_class{
        type_name = name,
        description = do_not_compare,
        source = "=(builtin)",
        is_builtin = true,
      }
      assert.contents_equals(expected, get_seq(got, name))
    end

    scope:add_test("builtin classes", function()
      local got = link{}
      assert_builtin(got, "string")
      assert_builtin(got, "number")
      assert_builtin(got, "integer")
      assert_builtin(got, "boolean")
      assert_builtin(got, "table")
      assert_builtin(got, "function")
      assert_builtin(got, "nil")
      assert_builtin(got, "any")
      assert.equals(builtin_class_count, #got.classes,
        "Not all builtin classes have been added to the classes array"
      )
      assert.equals(0, #got.aliases, "There should be no aliases")
    end)
  end

  scope:add_test("classes get added to the classes list and type lut", function()
    local sequences = parse("---@class foo\n\n---@class bar\n\n---@class baz")
    local got = link(sequences)
    assert.equals(sequences[1], get_class(got, 1))
    assert.equals(sequences[2], get_class(got, 2))
    assert.equals(sequences[3], get_class(got, 3))
    assert.equals(sequences[1], get_seq(got, "foo"))
    assert.equals(sequences[2], get_seq(got, "bar"))
    assert.equals(sequences[3], get_seq(got, "baz"))
  end)

  scope:add_test("aliases get added to the aliases list and type lut", function()
    local sequences = parse("---@alias foo '1'\n\n---@alias bar '2'\n\n---@alias baz '3'")
    local got = link(sequences)
    assert.equals(sequences[1], get_alias(got, 1))
    assert.equals(sequences[2], get_alias(got, 2))
    assert.equals(sequences[3], get_alias(got, 3))
    assert.equals(sequences[1], get_seq(got, "foo"))
    assert.equals(sequences[2], get_seq(got, "bar"))
    assert.equals(sequences[3], get_seq(got, "baz"))
  end)

  scope:add_test("2 classes with the same name", function()
    local sequences = parse("---@class foo\n\n---@class foo")
    local got, errors = link_invalid(sequences)
    assert.equals(sequences[1], get_class(got, 1))
    assert.equals(sequences[2], get_class(got, 2))
    assert.equals(sequences[1], get_seq(got, "foo"))
    assert.contents_equals({
      new_error(
        codes.el_duplicate_type_name,
        {"foo"},
        sequences[2].type_name_start_position,
        sequences[2].type_name_stop_position
      ),
    }, errors)
  end)

  scope:add_test("class and alias with the same name", function()
    local sequences = parse("---@class foo\n\n---@alias foo '1'")
    local got, errors = link_invalid(sequences)
    assert.equals(sequences[1], get_class(got, 1))
    assert.equals(sequences[2], get_alias(got, 1))
    assert.equals(sequences[1], get_seq(got, "foo"))
    assert.contents_equals({
      new_error(
        codes.el_duplicate_type_name,
        {"foo"},
        sequences[2].type_name_start_position,
        sequences[2].type_name_stop_position
      ),
    }, errors)
  end)

  scope:add_test("alias with reference type", function()
    local sequences = parse("---@alias foo any")
    local got = link(sequences)
    assert.equals(get_any(got), sequences[1].aliased_type.reference_sequence)
  end)

  scope:add_test("class with base class", function()
    local sequences = parse("---@class foo\n\n---@class bar : foo")
    link(sequences)
    assert.equals(sequences[1], sequences[2].base_classes[1].reference_sequence)
  end)

  scope:add_test("class with 2 base classes", function()
    local sequences = parse("---@class foo\n\n---@class bar\n\n---@class baz : foo, bar")
    link(sequences)
    assert.equals(sequences[1], sequences[3].base_classes[1].reference_sequence)
    assert.equals(sequences[2], sequences[3].base_classes[2].reference_sequence)
  end)

  scope:add_test("class with field with reference type", function()
    local sequences = parse("---@class foo\n---@field bar any")
    local got = link(sequences)
    assert.equals(get_any(got), sequences[1].fields[1].field_type.reference_sequence)
  end)

  scope:add_test("class with 2 fields with reference types", function()
    local sequences = parse("---@class foo\n---@field bar any\n---@field baz any")
    local got = link(sequences)
    assert.equals(get_any(got), sequences[1].fields[1].field_type.reference_sequence)
    assert.equals(get_any(got), sequences[1].fields[2].field_type.reference_sequence)
  end)

  scope:add_test("class with field with reference to its own class", function()
    local sequences = parse("---@class foo\n---@field bar foo")
    link(sequences)
    assert.equals(sequences[1], sequences[1].fields[1].field_type.reference_sequence)
  end)

  scope:add_test("literal type (does nothing)", function()
    local sequences = parse("---@alias foo '100'")
    local copy = util.copy(sequences[1])
    link(sequences)
    assert.contents_equals(copy, sequences[1])
  end)

  scope:add_test("dictionary type with key_type with reference type", function()
    local sequences = parse("---@alias foo table<any,'1'>")
    local got = link(sequences)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.key_type.reference_sequence)
  end)

  scope:add_test("dictionary type with value_type with reference type", function()
    local sequences = parse("---@alias foo table<'1',any>")
    local got = link(sequences)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.value_type.reference_sequence)
  end)

  scope:add_test("function type with param with reference type", function()
    local sequences = parse("---@alias foo fun(bar:any)")
    local got = link(sequences)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.params[1].param_type.reference_sequence)
  end)

  scope:add_test("function type with 2 params with reference types", function()
    local sequences = parse("---@alias foo fun(bar:any,baz:any)")
    local got = link(sequences)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.params[1].param_type.reference_sequence)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.params[2].param_type.reference_sequence)
  end)

  scope:add_test("function type with return with reference type", function()
    local sequences = parse("---@alias foo fun():any")
    local got = link(sequences)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.returns[1].return_type.reference_sequence)
  end)

  scope:add_test("function type with 2 returns with reference types", function()
    local sequences = parse("---@alias foo fun():any,any")
    local got = link(sequences)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.returns[1].return_type.reference_sequence)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.returns[2].return_type.reference_sequence)
  end)

  scope:add_test("array type with value_type with reference type", function()
    local sequences = parse("---@alias foo any[]")
    local got = link(sequences)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.value_type.reference_sequence)
  end)

  scope:add_test("union type with reference types", function()
    local sequences = parse("---@alias foo any|any")
    local got = link(sequences)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.union_types[1].reference_sequence)
    assert.contents_equals(get_any(got), sequences[1].aliased_type.union_types[2].reference_sequence)
  end)

  -- function sequences are literally the same as function types so a single test will suffice
  scope:add_test("function sequence with param with reference type", function()
    local sequences = parse("---@param foo any\nfunction func() end")
    local got = link(sequences)
    assert.contents_equals(get_any(got), sequences[1].params[1].param_type.reference_sequence)
  end)

  scope:add_test("unresolved reference", function()
    local sequences = parse("---@alias foo bar")
    local _, errors = link_invalid(sequences)
    assert.contents_equals({
      new_error(
        codes.el_unresolved_reference,
        {"bar"},
        sequences[1].aliased_type.start_position,
        sequences[1].aliased_type.stop_position
      ),
    }, errors)
  end)

  scope:add_test("base class isn't a reference", function()
    local sequences = parse("---@class foo")
    sequences[1].base_classes[1] = el_util.new_literal_type{value = "rip"}
    local _, errors = link_invalid(sequences)
    assert.contents_equals({
      new_error(
        codes.el_expected_reference_to_class,
        {"literal", ""},
        sequences[1].base_classes[1].start_position,
        sequences[1].base_classes[1].stop_position
      ),
    }, errors)
  end)

  scope:add_test("base class is a reference to an alias", function()
    local sequences = parse("---@alias foo '1'\n\n---@class bar : foo")
    local _, errors = link_invalid(sequences)
    assert.contents_equals({
      new_error(
        codes.el_expected_reference_to_class,
        {"reference", " with type name foo"},
        sequences[2].base_classes[1].start_position,
        sequences[2].base_classes[1].stop_position
      ),
    }, errors)
  end)

  scope:add_test("base class is a reference to a builtin class", function()
    local sequences = parse("---@class foo : any")
    local _, errors = link_invalid(sequences)
    assert.contents_equals({
      new_error(
        codes.el_builtin_base_class,
        {"any"},
        sequences[1].base_classes[1].start_position,
        sequences[1].base_classes[1].stop_position
      ),
    }, errors)
  end)

  scope:add_test("2 errors", function()
    local sequences = parse("---@class foo\n\n---@class foo\n\n---@class foo")
    local _, errors = link_invalid(sequences)
    assert(errors[1], "missing first error")
    assert(errors[2], "missing second error")
  end)

  scope:add_test("function sequence adding a class field", function()
    local sequences = parse("---@class foo\nlocal bar\n\n---hello world\nfunction bar.baz() end")
    link(sequences)
    assert(sequences[1].fields[1], "did not add class field")
    assert.equals(sequences[2], sequences[1].fields[1].field_type, "the added field's field_type")
  end)

  scope:add_test("2 function sequences adding class fields", function()
    local sequences = parse("---@class foo\nlocal bar\n\n\z
      ---hello world\nfunction bar.baz() end\n\n\z
      ---hello worlds\nfunction bar.bat() end"
    )
    link(sequences)
    assert(sequences[1].fields[1], "did not add the first class field")
    assert.equals(sequences[2], sequences[1].fields[1].field_type, "the first added field's field_type")
    assert(sequences[1].fields[2], "did not add the second class field")
    assert.equals(sequences[3], sequences[1].fields[2].field_type, "the second added field's field_type")
  end)

  scope:add_test("2 function sequences adding a class field to 2 locals that were defined by the same localstat", function()
    local sequences = parse("---@class foo\nlocal bar, two\n\n\z
      ---hello world\nfunction bar.baz() end\n\n\z
      ---hello worlds\nfunction two.bat() end"
    )
    link(sequences)
    assert(sequences[1].fields[1], "did not add the first class field")
    assert.equals(sequences[2], sequences[1].fields[1].field_type, "the first added field's field_type")
    assert(sequences[1].fields[2], "did not add the second class field")
    assert.equals(sequences[3], sequences[1].fields[2].field_type, "the second added field's field_type")
  end)

  scope:add_test("function sequence adding a class field through upvals", function()
    local sequences = parse("\z
      ---@class foo\n\z
      local bar\n\z
      local function func()\n\z
        local function func2()\n\z
          ---hello world\n\z
          function bar.baz() end\n\z
        end\n\z
      end\n\z
      "
    )
    link(sequences)
    assert(sequences[1].fields[1], "did not add class field")
    assert.equals(sequences[2], sequences[1].fields[1].field_type, "the added field's field_type")
  end)

  for _, data in ipairs{
    {label = "not adding field because node isn't a funcstat", expr = "func", use_localstat = true},
    {label = "not adding field because node.name isn't and index", expr = "foo"}, -- foo is a local
    {label = "not adding field because node.name.suffix isn't a string", expr = "foo[1]"},
    {label = "not adding field because node.name.suffix isn't an identifier", expr = "foo['2']"},
    {label = "does not error when the found local doesn't have a class", expr = "foo.baz", do_not_even_make_a_class = true}
  }
  do
    local function make_text()
      return (data.do_not_even_make_a_class and "" or "---@class foo\nlocal bar\n\n")
        .."---hello world\n"
        ..(data.use_localstat and "local " or "").."function "..data.expr.."() end"
    end

    scope:add_test("function sequence "..data.label, function()
      local sequences = parse(make_text())
      link(sequences)
      if not data.do_not_even_make_a_class then
        assert(not sequences[1].fields[1], "did add the field when it was not supposed to")
      end
    end)
  end

  scope:add_test("ast remains clean with 1 localstat with 1 lhs", function()
    local sequences = parse("---@class foo\nlocal bar")
    local copy = util.copy(sequences[1].node)
    link(sequences)
    assert.contents_equals(copy, sequences[1].node)
  end)

  scope:add_test("ast remains clean with 2 localstat nodes with a total of 3 lhs", function()
    local sequences = parse("---@class foo\nlocal one, two\n---@class bar\nlocal three")
    local copy = util.copy(sequences[1].node)
    link(sequences)
    assert.contents_equals(copy, sequences[1].node)
  end)
end
