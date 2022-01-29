
local framework = require("test_framework")
local assert = require("assert")

local tokenizer = require("tokenize")

local basic_tokens = {
  "+",
  "*",
  "/",
  "%",
  "^",
  "#",
  ";",
  ",",
  "(",
  ")",
  "{",
  "}",
  "]",
  "[",
  "<",
  "<=",
  "=",
  "==",
  ">",
  ">=",
  "-",
  "~=",
  "::",
  ":",
  "...",
  "..",
  ".",
}

local keywords = {
  "and",
  "break",
  "do",
  "else",
  "elseif",
  "end",
  "false",
  "for",
  "function",
  "if",
  "in",
  "local",
  "nil",
  "not",
  "or",
  "repeat",
  "return",
  "then",
  "true",
  "until",
  "while",
  "goto",
}

local function test(str, expected_tokens)
  local iter, state, index = tokenizer(str)
  local got
  index, got = iter(state, index)
  local i = 0
  while index do
    i = i + 1
    local expected = expected_tokens[i]
    assert.contents_equals(expected, got, "token #"..i)
    index, got = iter(state, index)
  end
  if expected_tokens[i + 1] then
    error("expected "..#expected_tokens.." tokens, got "..i)
  end
end

---cSpell:ignore inext

local function flat_inext(state, index)
  local array = state.array_of_arrays[state.array_index]
  if not array then
    return
  end
  index = (index or 0) + 1
  local element = array[index]
  if not element then
    state.array_index = state.array_index + 1
    return flat_inext(state)
  end
  return index, element
end

local function flat_ipairs(array_of_arrays)
  return flat_inext, {
    array_of_arrays = array_of_arrays,
    array_index = 1,
  }
end

local function new_token(token_type, index, line, column, value)
  return {
    token_type = token_type,
    index = index,
    line = line,
    column = column,
    value = value,
  }
end

do
  local scope = framework.scope:new_scope("tokenizer")

  for _, token_type in flat_ipairs{basic_tokens, keywords} do
    scope:register_test("token '"..token_type.."'", function()
      test(token_type, {new_token(token_type, 1, 1, 1)})
    end)
  end

  scope:register_test("blank space and tabs", function()
    test("  \t    ", {new_token("blank", 1, 1, 1, "  \t    ")})
  end)

  scope:register_test("blank with 1 newline", function()
    test("  \n", {new_token("blank", 1, 1, 1, "  \n")})
  end)

  scope:register_test("blank with 2 newlines", function()
    test("  \n  \n", {
      new_token("blank", 1, 1, 1, "  \n"),
      new_token("blank", 4, 2, 1, "  \n"),
    })
  end)

  for _, data in ipairs{
    {str = "\n;", label = "\\n"},
    {str = "\r;", label = "\\r"},
    {str = "\n\r;", label = "\\n\\r"},
    {str = "\r\n;", label = "\\r\\n"},
  }
  do
    scope:register_test("blank with "..data.label, function()
      test(data.str, {
        new_token("blank", 1, 1, 1, "\n"),
        new_token(";", #data.str, 2, 1),
      })
    end)
  end
end
