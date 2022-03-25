
local framework = require("test_framework")
local assert = require("assert")

local parser = require("parser")
local jump_linker = require("jump_linker")
local emmy_lua_parser = require("emmy_lua_parser")

local tutil = require("testing_util")
local test_source = tutil.test_source

local function parse(text)
  local ast = parser(text, test_source)
  jump_linker(ast)
  return emmy_lua_parser(ast)
end

do
  local scope = framework.scope:new_scope("emmy_lua_parser")
end
