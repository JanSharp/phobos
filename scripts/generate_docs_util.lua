
local parser = require("parser")
local jump_linker = require("jump_linker")
local emmy_lua_parser = require("emmy_lua_parser")
local emmy_lua_linker = require("emmy_lua_linker")
local util = require("util")
local error_code_util = require("error_code_util")

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

local function generate_docs(emmy_lua_data)
  local phobos_profiles = util.debug_assert(
    emmy_lua_data.all_types_lut["PhobosProfiles"],
    "Missing class 'PhobosProfiles' to generate docs."
  )
  local out = {}
  local c = 0
  local function add(part)
    c = c + 1
    out[c] = part
  end

  local function span(class, str)
    return "<span class=\""..class.."\">"..str.."</span>"
  end

  local function param_span(str)
    return span("parameter", str)
  end

  local function func_span(str)
    return span("function", str)
  end

  for _, field in ipairs(phobos_profiles.fields) do
    local type = field.field_type
    if type.type_type == "function" then
      add("### ")
      add(func_span(field.name))
      add("(")
      local param_names = {}
      for i, param in ipairs(type.params) do
        param_names[i] = param_span(param.name)
      end
      add(table.concat(param_names, ", "))
      add(")")
      add(" => ")
      add("{results}") -- TODO
      add("\n\n")
      add(table.concat(field.description, "\n"))
      add("\n\n")
      -- TODO: improve condition to check for the actual type of the single parameter to be a class reference
      if type.params[1] and type.params[1].name == "params" and not type.params[2] then
      else
        for _, param in ipairs(type.params) do
          add("- ")
          add(param.name)
          add(": ")
          add(table.concat(param.description, "\n"))
          add("\n")
        end
      end
      add("\n")
    end
  end

  return table.concat(out):gsub("_", "&#"..string.byte("_")..";")
end

return {
  parse = parse,
  resolve_references = resolve_references,
  generate_docs = generate_docs,
}
