
local framework = require("test_framework")
local assert = require("assert")

local invert = require("invert")
local tokenizer = require("tokenize")

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
  local main_scope = framework.scope:new_scope("tokenizer")

  do
    local scope = main_scope:new_scope("basic tokens")

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

    for _, tab in ipairs{basic_tokens, keywords} do
      for _, token_type in ipairs(tab) do
        scope:register_test("token '"..token_type.."'", function()
          test(token_type, {new_token(token_type, 1, 1, 1)})
        end)
      end
    end

    local function invalid_token(char)
      scope:register_test("invalid token '"..char.."'", function()
        local invalid = new_token("invalid", 1, 1, 1)
        invalid.value = char
        invalid.error_messages = {"Invalid token '"..char.."'"}
        test(char..";", {
          invalid,
          new_token(";", 2, 1, 2),
        })
      end)
    end

    invalid_token("~") -- special because of ~= detection
    invalid_token("\\") -- all the rest are the same, but testing each one is tedious
  end

  do
    local scope = main_scope:new_scope("blank")

    scope:register_test("with space and tabs", function()
      test("  \t    ", {new_token("blank", 1, 1, 1, "  \t    ")})
    end)

    scope:register_test("1 newline", function()
      test("  \n", {new_token("blank", 1, 1, 1, "  \n")})
    end)

    scope:register_test("2 newlines", function()
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
      scope:register_test("ending with "..data.label, function()
        test(data.str, {
          new_token("blank", 1, 1, 1, "\n"),
          new_token(";", #data.str, 2, 1),
        })
      end)
    end
  end

  do
    local scope = main_scope:new_scope("non block comment")

    scope:register_test("nothing special", function()
      local token = new_token("comment", 1, 1, 1, " foo")
      token.src_is_block_str = nil
      test("-- foo", {token})
    end)

    for _, data in ipairs{
      {str = "\n", label = "\\n"},
      {str = "\r", label = "\\r"},
    }
    do
      scope:register_test("ending with "..data.label, function()
        local token = new_token("comment", 1, 1, 1, " foo")
        token.src_is_block_str = nil
        test("-- foo"..data.str, {
          token,
          new_token("blank", 7, 1, 7, "\n"),
        })
      end)
    end
  end

  do
    local scope = main_scope:new_scope("non block string")

    for _, data in ipairs{
      {str = [["foo"]], quote = [["]], value = [[foo]], label = [[" quotes]]},
      {str = [['foo']], quote = [[']], value = [[foo]], label = [[' quotes]]},
      {str = [["foo'"]], quote = [["]], value = [[foo']], label = [[" quotes containing ']]},
      {str = [['foo"']], quote = [[']], value = [[foo"]], label = [[' quotes containing "]]},
    }
    do
      scope:register_test(data.label, function()
        local token = new_token("string", 1, 1, 1)
        token.src_is_block_str = nil
        token.value = data.value
        token.src_value = data.value
        token.src_quote = data.quote
        test(data.str, {token})
      end)
    end

    scope:register_test("unterminated at eof", function()
      local token = new_token("invalid", 1, 1, 1)
      token.value = [["foo]]
      token.error_messages = {"Unterminated string"}
      test([["foo]], {token})
    end)

    for _, data in ipairs{
      {str = "\n", label = "\\n"},
      {str = "\r", label = "\\r"},
    }
    do
      scope:register_test("ending with "..data.label, function()
        local token = new_token("invalid", 1, 1, 1)
        token.value = [["foo]]
        token.error_messages = {"Unterminated string (at end of line 1)"}
        test([["foo]]..data.str, {
          token,
          new_token("blank", 5, 1, 5, "\n"),
        })
      end)
    end

    local function add_escape_sequence_test(str, value)
      scope:register_test("containing escape sequence "..str, function()
        local token = new_token("string", 1, 1, 1)
        token.src_is_block_str = nil
        token.value = "foo "..value.." bar"
        token.src_value = "foo "..str.." bar"
        token.src_quote = [["]]
        local full_str = [["foo ]]..str..[[ bar";]]
        test(full_str, {
          token,
          new_token(";", #full_str, 1, #full_str),
        })
      end)
    end

    add_escape_sequence_test([[\x03]], "\x03")
    add_escape_sequence_test([[\xab]], "\xab")
    add_escape_sequence_test([[\xCF]], "\xCF")
    add_escape_sequence_test([[\xdD]], "\xdD")

    scope:register_test("containing invalid escape sequence \\x", function()
      local token = new_token("invalid", 1, 1, 1)
      token.src_is_block_str = nil
      token.value = [["\x"]]
      token.error_messages = {
        "Invalid escape sequence '\\x\";', '\\x' must be followed by 2 hexadecimal digits."
      }
      test([["\x";]], {
        token,
        new_token(";", 5, 1, 5),
      })
    end)

    scope:register_test("containing invalid \\x with string and file ending right after", function()
      local token = new_token("invalid", 1, 1, 1)
      token.src_is_block_str = nil
      token.value = [["\x"]]
      token.error_messages = {
        "Invalid escape sequence '\\x\"', '\\x' must be followed by 2 hexadecimal digits."
      }
      test([["\x"]], {token})
    end)

    for _, data in ipairs{
      {str = "\n", label = "\\n"},
      {str = "\r", label = "\\r"},
      {str = "\n\r", label = "\\n\\r"},
      {str = "\r\n", label = "\\r\\n"},
    }
    do
      scope:register_test("containing escaped "..data.label, function()
        local token = new_token("string", 1, 1, 1)
        token.src_is_block_str = nil
        token.value = "foo\nbar"
        token.src_value = [[foo\]]..data.str..[[bar]]
        token.src_quote = [["]]
        local str = [["foo\]]..data.str..[[bar";]]
        test(str, {
          token,
          new_token(";", #str, 2, 5),
        })
      end)
    end

    scope:register_test("containing escape sequence \\z with spaces", function()
      local token = new_token("string", 1, 1, 1)
      token.src_is_block_str = nil
      token.value = "foo bar"
      token.src_value = [[foo \z    bar]]
      token.src_quote = [["]]
      test([["foo \z    bar";]], {
        token,
        new_token(";", 16, 1, 16),
      })
    end)

    for _, data in ipairs{
      {str = "\n", label = "\\n"},
      {str = "\r", label = "\\r"},
      {str = "\n\r", label = "\\n\\r"},
      {str = "\r\n", label = "\\r\\n"},
    }
    do
      scope:register_test("containing escape sequence \\z with "..data.label, function()
        local token = new_token("string", 1, 1, 1)
        token.src_is_block_str = nil
        token.value = "foo bar"
        token.src_value = [[foo \z]]..data.str..[[  bar]]
        token.src_quote = [["]]
        local str = [["foo \z]]..data.str..[[  bar";]]
        test(str, {
          token,
          new_token(";", #str, 2, 7),
        })
      end)
    end

    add_escape_sequence_test([[\a]], "\a")
    add_escape_sequence_test([[\b]], "\b")
    add_escape_sequence_test([[\f]], "\f")
    add_escape_sequence_test([[\n]], "\n")
    add_escape_sequence_test([[\r]], "\r")
    add_escape_sequence_test([[\t]], "\t")
    add_escape_sequence_test([[\v]], "\v")
    add_escape_sequence_test([[\\]], "\\")
    add_escape_sequence_test([[\"]], "\"")
    add_escape_sequence_test([[\']], "\'")

    add_escape_sequence_test([[\1]], "\1")
    add_escape_sequence_test([[\12]], "\12")
    add_escape_sequence_test([[\123]], "\123")
    add_escape_sequence_test([[\255]], "\255")

    scope:register_test("containing invalid escape sequence \\256 (too large)", function()
      local token = new_token("invalid", 1, 1, 1)
      token.value = [["foo \256 bar"]]
      token.error_messages = {"Too large value in decimal escape sequence '\\256'"}
      test([["foo \256 bar";]], {
        token,
        new_token(";", 15, 1, 15),
      })
    end)

    scope:register_test("containing invalid escape sequences", function()
      local all_valid_escaped_chars = invert{
        "x",
        "\r",
        "\n",
        "z",
        "a",
        "b",
        "f",
        "n",
        "r",
        "t",
        "v",
        "\\",
        "\"",
        "\'",
        "0",
        "1",
        "2",
        "3",
        "4",
        "5",
        "6",
        "7",
        "8",
        "9",
      }
      local broken_bytes = {}
      local errors = {}
      for i = 1, 255 do
        local c = string.char(i)
        if not all_valid_escaped_chars[c] then
          local success, err = pcall(function()
            local token = new_token("invalid", 1, 1, 1)
            token.value = [["foo \]]..c..[[ bar"]]
            token.error_messages = {"Unrecognized escape '\\"..c.."'"}
            test([["foo \]]..c..[[ bar";]], {
              token,
              new_token(";", 13, 1, 13),
            })
          end)
          if not success then
            broken_bytes[#broken_bytes+1] = string.format("0x%2x", i)
            errors[#errors+1] = err
          end
        end
      end
      if errors[1] then
        error(#errors.." invalid escape sequence bytes threw and error: "
          ..table.concat(broken_bytes, ", ")
          .."\n"..table.concat(errors, "\n")
        )
      end
    end)

    local function add_each_syntax_error_in_a_string(func)
      func("invalid \\x", [[\xha]],
        "Invalid escape sequence '\\xha', '\\x' must be followed by 2 hexadecimal digits."
      )
      func("invalid \\500", [[\500]],
        "Too large value in decimal escape sequence '\\500'"
      )
      func("invalid escape", [[\_]],
        "Unrecognized escape '\\_'"
      )
    end
    local function initial_syntax_error(label1, str1, msg1)
      local function consecutive_syntax_error(label2, str2, msg2)
        local function ending_syntax_error_or_end_of_string(label3, str3, msg3, is_eol)
          scope:register_test("syntax error chain: "..label1.." + "..label2.." + "..label3, function()
            local token = new_token("invalid", 1, 1, 1)
            local str = [["]]..str1..str2
            token.value = str..(is_eol and "" or str3)
            token.error_messages = {msg1, msg2, msg3}
            str = str..str3
            test(str, {
              token,
              is_eol and new_token("blank", #str, 1, #str, "\n") or nil
            })
          end)
        end
        ending_syntax_error_or_end_of_string("regular end of string", [["]], nil)
        ending_syntax_error_or_end_of_string("unterminated at eof", "", "Unterminated string")
        ending_syntax_error_or_end_of_string("unterminated at eol", "\n",
          "Unterminated string (at end of line 1)", true
        )
      end
      add_each_syntax_error_in_a_string(consecutive_syntax_error)
    end
    add_each_syntax_error_in_a_string(initial_syntax_error)
  end

  do
    local scope = main_scope:new_scope("block string")

    scope:register_test("invalid open bracket", function()
      local token = new_token("invalid", 1, 1, 1)
      token.value = "["
      token.error_messages = {"Invalid string open bracket"}
      test("[==", {
        token,
        new_token("==", 2, 1, 2),
      })
    end)

    scope:register_test("without padding", function()
      local token = new_token("string", 1, 1, 1)
      token.value = "foo"
      token.src_is_block_str = true
      token.src_has_leading_newline = false
      token.src_pad = ""
      test("[[foo]];", {
        token,
        new_token(";", 8, 1, 8),
      })
    end)

    scope:register_test("with 3 padding", function()
      local token = new_token("string", 1, 1, 1)
      token.value = "foo"
      token.src_is_block_str = true
      token.src_has_leading_newline = false
      token.src_pad = "==="
      test("[===[foo]===];", {
        token,
        new_token(";", 14, 1, 14),
      })
    end)

    scope:register_test("with 3 padding containing 2 padding", function()
      local token = new_token("string", 1, 1, 1)
      token.value = "[==[foo]==]"
      token.src_is_block_str = true
      token.src_has_leading_newline = false
      token.src_pad = "==="
      test("[===[[==[foo]==]]===];", {
        token,
        new_token(";", 22, 1, 22),
      })
    end)

    for _, data in ipairs{
      {str = "\n", label = "\\n"},
      {str = "\r", label = "\\r"},
      {str = "\n\r", label = "\\n\\r"},
      {str = "\r\n", label = "\\r\\n"},
    }
    do
      scope:register_test("leading "..data.label, function()
        local token = new_token("string", 1, 1, 1)
        token.value = "foo"
        token.src_is_block_str = true
        token.src_has_leading_newline = true
        token.src_pad = ""
        local str = "[["..data.str.."foo]];"
        test(str, {
          token,
          new_token(";", #str, 2, 6),
        })
      end)

      scope:register_test("containing "..data.label, function()
        local token = new_token("string", 1, 1, 1)
        token.value = "foo\nbar"
        token.src_is_block_str = true
        token.src_has_leading_newline = false
        token.src_pad = ""
        local str = "[[foo"..data.str.."bar]];"
        test(str, {
          token,
          new_token(";", #str, 2, 6),
        })
      end)
    end

    local function add_unterminated_test(label, str)
      scope:register_test(label, function()
        local token = new_token("invalid", 1, 1, 1)
        token.value = str
        token.error_messages = {"Unterminated block string"}
        test(str, {token})
      end)
    end

    add_unterminated_test("unterminated at eof", "[[;")
    add_unterminated_test("unterminated at eof right after start", "[[")
  end

  do
    local scope = main_scope:new_scope("block comment")

    scope:register_test("it's just a prefixed block string, so if this works it works", function()
      local token = new_token("comment", 1, 1, 1)
      token.value = ""
      token.src_is_block_str = true
      token.src_has_leading_newline = false
      token.src_pad = ""
      test("--[[]];", {
        token,
        new_token(";", 7, 1, 7),
      })
    end)
  end

  do
    local scope = main_scope:new_scope("number")

    scope:register_test("simple", function()
    end)
  end

  do
    local scope = main_scope:new_scope("other")

    scope:register_test("skip UTF8 BOM", function()
      test("\xef\xbb\xbf;\n;", {
        new_token(";", 4, 1, 1),
        new_token("blank", 5, 1, 2, "\n"),
        new_token(";", 6, 2, 1),
      })
    end)
  end
end
