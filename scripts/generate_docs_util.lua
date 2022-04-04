
local parser = require("parser")
local jump_linker = require("jump_linker")
local emmy_lua_parser = require("emmy_lua_parser")
local emmy_lua_linker = require("emmy_lua_linker")
local util = require("util")
local error_code_util = require("error_code_util")
local xml = require("scripts.xml_util")
local md = require("scripts.markdown")
local io_util = require("io_util")

local function check_errors(errors, source_name, is_emmy_lua)
  if errors[1] then
    util.abort(error_code_util.get_message_for_list(
      errors,
      (is_emmy_lua and "EmmyLua syntax errors" or "syntax errors")
        ..(source_name and (" in "..source_name) or "")
    ))
  end
end

local function parse(text, source_name)
  local ast, parser_errors = parser(text, source_name)
  check_errors(parser_errors, source_name)
  local jump_linker_errors = jump_linker(ast)
  check_errors(jump_linker_errors, source_name)
  local result, emmy_lua_errors = emmy_lua_parser(ast)
  check_errors(emmy_lua_errors, source_name, true)
  return result
end

local function resolve_references(array_of_parsed_sequences)
  local combined = {}
  for _, array in ipairs(array_of_parsed_sequences) do
    for _, elem in ipairs(array) do
      combined[#combined+1] = elem
    end
  end
  local result, errors = emmy_lua_linker.link(combined)
  check_errors(errors, nil, true)
  return result
end

local function format_markdown(str)
  str = str:gsub("\\\n", "<br/>")
  return xml.raw('<div class="markdown">'..md.markdown(str).."</div>")
end

local function span_elem(class, str)
  return xml.elem("span", {xml.attr("class", class)}, {str})
end

local param_css_class = "parameter"
local function param_span(str)
  return span_elem(param_css_class, str)
end

local local_css_class = "local"
local function local_span(str)
  return span_elem(local_css_class, str)
end

local function_css_class = "function"
local function func_span(str)
  return span_elem(function_css_class, str)
end

local function format_type(type, optional)
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
        span[#span+1] = xml.elem("a", {xml.attr("href", "concepts.html#"..type.type_name)}, {type.type_name})
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
  if optional then
    span[#span+1] = "?"
  end
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

local function field_or_param_or_return_row(name, type, optional, description, css_class)
  local left = {name and (css_class and span_elem(css_class, name) or name)}
  left[#left+1] = name and " :: " or ":: "
  left[#left+1] = format_type(type, optional)
  local right = {}
  if description[1] then
    right[#right+1] = format_markdown(table.concat(description, "\n"))
  end
  return xml.elem("tr", nil, {
    xml.elem("td", {xml.attr("class", "name")}, left),
    xml.elem("td", {xml.attr("class", "description")}, right),
  })
end

local function foreach_field_and_inherited_fields(sequence, callback)
  local already_added_field_name_lut = {}
  ---@diagnostic disable-next-line:redefined-local
  local function add(sequence)
    if sequence.sequence_type == "alias" then
      add(sequence.aliased_type.reference_sequence)
    elseif sequence.sequence_type == "class" then
      for _, field in ipairs(sequence.fields) do
        if not already_added_field_name_lut[field.name] then
          already_added_field_name_lut[field.name] = true
          callback(field)
        end
      end
      for _, base_class in ipairs(sequence.base_classes) do
        add(base_class.reference_sequence)
      end
    end
  end
  add(sequence)
end

local function is_field_with_function_with_params_param(field)
  local field_type = field.field_type
  return field_type.type_type == "function"
    and field_type.params[1]
    and field_type.params[1].name == "params"
    and not field_type.params[2]
end

local function format_signature(field)
  local result = {}
  local field_type = field.field_type
  result[#result+1] = xml.elem("a", {xml.attr("href", "#"..field.name)}, {func_span(field.name)})
  result[#result+1] = "("
  for i, param in ipairs(field_type.params) do
    result[#result+1] = param_span(param.name)
    if i ~= #field_type.params then
      result[#result+1] = ", "
    end
  end
  result[#result+1] = ")"
  if field_type.returns[1] then
    result[#result+1] = " => "
    for i, ret in ipairs(field_type.returns) do
      if ret.name then
        result[#result+1] = local_span(ret.name)
        result[#result+1] = ": "
      end
      result[#result+1] = format_type(ret.return_type, ret.optional)
      if i ~= #field_type.returns then
        result[#result+1] = ", "
      end
    end
  end
  return result
end

local function generate_phobos_profiles_page(emmy_lua_data)
  local phobos_profiles = get_phobos_profiles_class(emmy_lua_data)
  local body = {}

  -- table of contents

  local ul = {}
  body[#body+1] = xml.elem("ul", nil, ul)

  for _, field in ipairs(phobos_profiles.fields) do
    ul[#ul+1] = xml.elem("li", nil, format_signature(field))
  end

  -- separator line
  body[#body+1] = xml.elem("hr")

  for j, field in ipairs(phobos_profiles.fields) do

    -- function signature header
    local field_type = field.field_type
    do
      -- local header = {}
      body[#body+1] = xml.elem("h3", {xml.attr("id", field.name)}, format_signature(field))
    end

    -- function description
    local div = {}
    if field_type.description[1] then
      div[#div+1] = format_markdown(table.concat(field_type.description, "\n"))
    end

    -- parameters table

    if is_field_with_function_with_params_param(field) then
      -- single parameter which is a table with specific fields
      div[#div+1] = xml.elem("h4", nil, {"Parameters"})
      div[#div+1] = "Table with the following fields:"
      local t = {}
      div[#div+1] = xml.elem("table", nil, t)
      foreach_field_and_inherited_fields(field_type.params[1].param_type.reference_sequence, function(class_field)
        t[#t+1] = field_or_param_or_return_row(
          class_field.name,
          class_field.field_type,
          class_field.optional,
          class_field.description,
          param_css_class
        )
      end)

    elseif field_type.params[1] then
      -- multiple parameters, just list those
      div[#div+1] = xml.elem("h4", nil, {"Parameters"})
      local t = {}
      div[#div+1] = xml.elem("table", nil, t)
      for _, param in ipairs(field_type.params) do
        t[#t+1] = field_or_param_or_return_row(
          param.name,
          param.param_type,
          param.optional,
          param.description,
          param_css_class
        )
      end
    end

    -- returns table
    if field_type.returns[1] then
      div[#div+1] = xml.elem("h4", nil, {"Return Values"})
      local t = {}
      div[#div+1] = xml.elem("table", nil, t)
      for _, ret in ipairs(field_type.returns) do
        t[#t+1] = field_or_param_or_return_row(
          ret.name,
          ret.return_type,
          ret.optional,
          ret.description,
          local_css_class
        )
      end
    end

    -- don't add the div if nothing is in it
    -- because if the html is parsed as html, not xhtml, the self closing div would "never be closed"
    if div[1] then
      body[#body+1] = xml.elem("div", {xml.attr("class", "indent")}, div)
    end

    -- separator line between functions
    if j ~= #phobos_profiles.fields then
      body[#body+1] = xml.elem("hr")
    end
  end

  return make_page("Profiles API Docs | Phobos", body)
end

local function generate_concepts_page(emmy_lua_data)
  local phobos_profiles = get_phobos_profiles_class(emmy_lua_data)

  -- find all types that are exposed directly by the PhobosProfiles class
  -- base classes of those types do not count as being exposed

  local exposed_sequences = {}
  local exposed_sequences_lut = {}
  local excluded_sequences_lut = {}

  local add_type
  local function add_sequence(sequence)
    if sequence.sequence_type == "class" then
      for _, field in ipairs(sequence.fields) do
        if is_field_with_function_with_params_param(field) then
          excluded_sequences_lut[field.field_type.params[1].param_type.reference_sequence] = true
        end
        add_type(field.field_type)
      end
    elseif sequence.sequence_type == "alias" then
      add_type(sequence.aliased_type)
    end
  end

  function add_type(type)
    (({
      ["literal"] = function()
        -- don't care
      end,
      ["dictionary"] = function()
        add_type(type.key_type)
        add_type(type.value_type)
      end,
      ["function"] = function()
        for _, param in ipairs(type.params) do
          add_type(param.param_type)
        end
        if type.returns[1] then
          for _, ret in ipairs(type.returns) do
            add_type(ret.return_type)
          end
        end
      end,
      ["reference"] = function()
        if not exposed_sequences_lut[type.reference_sequence] then
          exposed_sequences_lut[type.reference_sequence] = true
          if not excluded_sequences_lut[type.reference_sequence] then
            exposed_sequences[#exposed_sequences+1] = type.reference_sequence
          end
          add_sequence(type.reference_sequence)
        end
      end,
      ["array"] = function()
        add_type(type.value_type)
      end,
      ["union"] = function()
        for _, union_type in ipairs(type.union_types) do
          add_type(union_type)
        end
      end,
    })[type.type_type] or function()
      util.debug_abort("Unknown emmy lua type type_type '"..tostring(type.type_type).."'.")
    end)()
  end

  add_sequence(phobos_profiles)

  -- sort exposed types alphabetically because I like that

  table.sort(exposed_sequences, function(left, right)
    return left.type_name:lower() < right.type_name:lower()
  end)

  -- table of contents

  local body = {}

  local ul = {}
  body[#body+1] = xml.elem("ul", nil, ul)

  for _, sequence in ipairs(exposed_sequences) do
    ul[#ul+1] = xml.elem("li", nil, {
      xml.elem("a", {xml.attr("href", "#"..sequence.type_name)}, {sequence.type_name})
    })
  end

  -- separator line
  body[#body+1] = xml.elem("hr")

  -- detailed list

  for i, sequence in ipairs(exposed_sequences) do
    -- header
    local header = {}
    body[#body+1] = xml.elem("h3", {xml.attr("id", sequence.type_name)}, header)
    header[#header+1] = xml.elem("a", {xml.attr("href", "#"..sequence.type_name)}, {sequence.type_name})

    -- type description
    local div = {}
    body[#body+1] = xml.elem("div", {xml.attr("class", "indent")}, div)
    if sequence.description[1] then
      div[#div+1] = format_markdown(table.concat(sequence.description, "\n"))
    end

    if sequence.sequence_type == "alias" then
      div[#div+1] = xml.elem("p", nil, {"Alias for ", format_type(sequence.aliased_type)})
    elseif sequence.sequence_type == "class" then
      local t = {}
      div[#div+1] = xml.elem("table", nil, t)
      foreach_field_and_inherited_fields(sequence, function(class_field)
        t[#t+1] = field_or_param_or_return_row(
          class_field.name,
          class_field.field_type,
          class_field.optional,
          class_field.description
        )
      end)
    end

    -- separator line between types
    if i ~= #exposed_sequences then
      body[#body+1] = xml.elem("hr")
    end
  end

  return make_page("Concepts | Phobos", body)
end

local function generate_docs(output_root)
  local parsed_files = {}
  local function parse_file(filename)
    filename = output_root.."/doc/emmy_lua/profiles/"..filename
    parsed_files[#parsed_files+1] = parse(io_util.read_file(filename), "@"..filename)
  end
  parse_file("arg_parser_classes.lua")
  parse_file("phobos_profiles.lua")
  parse_file("profile_classes.lua")
  local emmy_lua_data = resolve_references(parsed_files)
  local phobos_profiles_docs = generate_phobos_profiles_page(emmy_lua_data)
  io_util.write_file(output_root.."/doc/phobos_profiles.html", phobos_profiles_docs)
  local concepts_docs = generate_concepts_page(emmy_lua_data)
  io_util.write_file(output_root.."/doc/concepts.html", concepts_docs)
end

return {
  parse = parse,
  resolve_references = resolve_references,
  generate_phobos_profiles_page = generate_phobos_profiles_page,
  generate_concepts_page = generate_concepts_page,
  generate_docs = generate_docs,
}
