
local parser = require("parser")
local jump_linker = require("jump_linker")
local emmy_lua_parser = require("emmy_lua_parser")
local emmy_lua_linker = require("emmy_lua_linker")
local util = require("util")
local error_code_util = require("error_code_util")
local xml = require("scripts.xml_util")
local md = require("scripts.markdown")

local function parse(text, source_name)
  local function check_errors(errors)
    if errors[1] then
      util.abort(error_code_util.get_message_for_list(errors, "syntax errors in "..source_name))
    end
  end
  local ast, parser_errors = parser(text, source_name)
  check_errors(parser_errors)
  local jump_linker_errors = jump_linker(ast)
  check_errors(jump_linker_errors)
  return emmy_lua_parser(ast)
end

local function resolve_references(array_of_parsed_sequences)
  local combined = {}
  for _, array in ipairs(array_of_parsed_sequences) do
    for _, elem in ipairs(array) do
      combined[#combined+1] = elem
    end
  end
  return emmy_lua_linker.link(combined)
end

local function format_markdown(str)
  str = str:gsub("\\\n", "<br/>")
  return xml.raw('<div class="markdown">'..md.markdown(str).."</div>")
end

local function span_elem(class, str)
  return xml.elem("span", {xml.attr("class", class)}, {str})
end

local function param_span(str)
  return span_elem("parameter", str)
end

local function local_span(str)
  return span_elem("local", str)
end

local function func_span(str)
  return span_elem("function", str)
end

local function format_type(type)
  local span = {}
  ---@diagnostic disable-next-line:redefined-local
  local function add_type(type)
    (({
      ["literal"] = function()
        span[#span+1] = xml.elem("code", {xml.attr("class", "literal")}, {type.value})
      end,
      ["dictionary"] = function()
        span[#span+1] = "Dictionary<"
        add_type(type.key_type)
        span[#span+1] = ", "
        add_type(type.value_type)
        span[#span+1] = ">"
      end,
      ["function"] = function()
        span[#span+1] = "function("
        for i, param in ipairs(type.params) do
          span[#span+1] = param_span(param.name)
          if param.optional then
            span[#span+1] = "?"
          end
          span[#span+1] = ": "
          add_type(param.param_type)
          if i ~= #type.params then
            span[#span+1] = ", "
          end
        end
        span[#span+1] = ")"
        if type.returns[1] then
          span[#span+1] = " => "
          for i, ret in ipairs(type.returns) do
            add_type(ret.return_type)
            if i ~= #type.returns then
              span[#span+1] = ", "
            end
          end
        end
      end,
      ["reference"] = function()
        span[#span+1] = type.type_name -- TODO: link
      end,
      ["array"] = function()
        add_type(type.value_type)
        span[#span+1] = "[]"
      end,
      ["union"] = function()
        for i, union_type in ipairs(type.union_types) do
          add_type(union_type)
          if i ~= #type.union_types then
            span[#span+1] = "|"
          end
        end
      end,
    })[type.type_type] or function()
      util.debug_abort("Unknown emmy lua type type_type '"..tostring(type.type_type).."'.")
    end)()
  end
  add_type(type)
  return xml.elem("span", {xml.attr("class", "type")}, span)
end

local function make_page(title, body_contents)
  ---cSpell:ignore stylesheet
  return xml.serialize_xhtml{
    xml.elem("html", {xml.attr("xmlns", "http://www.w3.org/1999/xhtml")}, {
      xml.elem("head", nil, {
        xml.elem("title", nil, {title}),
        xml.elem("link", {
          xml.attr("rel", "stylesheet"),
          xml.attr("href", "styles.css"),
        }),
        xml.elem("link", {
          xml.attr("rel", "icon"),
          xml.attr("type", "image/x-icon"),
          xml.attr("href", "images/favicon.png"),
        }),
      }),
      xml.elem("body", nil, body_contents),
    }),
  }
end

local function get_phobos_profiles_class(emmy_lua_data)
  return util.debug_assert(
    emmy_lua_data.all_types_lut["PhobosProfiles"],
    "Missing class 'PhobosProfiles' to generate docs."
  )
end

local function generate_phobos_profiles_page(emmy_lua_data)
  local phobos_profiles = get_phobos_profiles_class(emmy_lua_data)
  local body = {}

  local function field_or_param_row(name, type, optional, description)
    local left = {param_span(name)}
    if optional then
      left[#left+1] = "?"
    end
    left[#left+1] = " :: "
    left[#left+1] = format_type(type)
    local right = {}
    if description[1] then
      right[#right+1] = format_markdown(table.concat(description, "\n"))
    end
    return xml.elem("tr", nil, {xml.elem("td", nil, left), xml.elem("td", nil, right)})
  end

  for j, field in ipairs(phobos_profiles.fields) do

    -- function signature header
    local field_type = field.field_type
    do
      local header = {}
      body[#body+1] = xml.elem("h3", {xml.attr("id", field.name)}, header)
      header[#header+1] = xml.elem("a", {xml.attr("href", "#"..field.name)}, {func_span(field.name)})
      header[#header+1] = "("
      for i, param in ipairs(field_type.params) do
        header[#header+1] = param_span(param.name)
        if i ~= #field_type.params then
          header[#header+1] = ", "
        end
      end
      header[#header+1] = ")"
      if field_type.returns[1] then
        header[#header+1] = " => "
        for i, ret in ipairs(field_type.returns) do
          if ret.name then
            header[#header+1] = local_span(ret.name)
            header[#header+1] = ": "
          end
          header[#header+1] = format_type(ret.return_type)
          if i ~= #field_type.returns then
            header[#header+1] = ", "
          end
        end
      end
    end

    -- function description
    local div = {}
    body[#body+1] = xml.elem("div", {xml.attr("class", "indent")}, div)
    if field_type.description[1] then
      div[#div+1] = format_markdown(table.concat(field_type.description, "\n"))
    end

    -- parameters table

    if field_type.params[1] and field_type.params[1].name == "params" and not field_type.params[2] then
      -- single parameter which is a table with specific fields
      div[#div+1] = xml.elem("h4", nil, {"Parameters"})
      div[#div+1] = "Table with the following fields:"
      local t = {}
      div[#div+1] = xml.elem("table", nil, t)
      local function add(sequence)
        if sequence.sequence_type == "alias" then
          add(sequence.aliased_type.reference_type)
        elseif sequence.sequence_type == "class" then
          for _, base_class in ipairs(sequence.base_classes) do
            add(base_class.reference_type)
          end
          for _, class_field in ipairs(sequence.fields) do
            t[#t+1] = field_or_param_row(
              class_field.name,
              class_field.field_type,
              false,
              class_field.description
            )
          end
        end
      end
      add(field_type.params[1].param_type.reference_type)

    elseif field_type.params[1] then
      -- multiple parameters, just list those
      div[#div+1] = xml.elem("h4", nil, {"Parameters"})
      local t = {}
      div[#div+1] = xml.elem("table", nil, t)
      for _, param in ipairs(field_type.params) do
        t[#t+1] = field_or_param_row(
          param.name,
          param.param_type,
          false,
          param.description
        )
      end
    end

    -- separator line between functions
    if j ~= #phobos_profiles.fields then
      body[#body+1] = xml.elem("hr")
    end
  end

  return make_page("Profiles API Docs | Phobos", body)
end

return {
  parse = parse,
  resolve_references = resolve_references,
  generate_phobos_profiles_page = generate_phobos_profiles_page,
}
