
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

return {
  parse = parse,
  resolve_references = resolve_references,
}
