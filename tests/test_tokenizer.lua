
local framework = require("test_framework")
local assert = require("assert")

local util = require("util")
local error_code_util = require("error_code_util")
local tokenizer = require("tokenize")

local test_source = "=(test source)"

local function test(str, expected_tokens)
  local iter, state, index = tokenizer(str, test_source)
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
  -- literally just for shebang_line testing
  return state
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
        if token_type == "#" then
          scope:add_test("token '#' (with blank before it, otherwise it would be a shebang)", function()
            test(" #", {new_token("blank", 1, 1, 1, " "), new_token("#", 2, 1, 2)})
          end)
        else
          scope:add_test("token '"..token_type.."'", function()
            test(token_type, {new_token(token_type, 1, 1, 1)})
          end)
        end
      end
    end

    for _, char in ipairs{
      "~", -- special because of ~= detection
      "\\", -- all the rest are the same, but testing each one is tedious
    }
    do
      scope:add_test("invalid token '"..char.."'", function()
        local invalid = new_token("invalid", 1, 1, 1)
        invalid.value = char
        invalid.error_code_insts = {error_code_util.new_error_code{
          error_code = error_code_util.codes.invalid_token,
          message_args = {char},
          source = test_source,
          position = {line = 1, column = 1},
        }}
        test(char..";", {
          invalid,
          new_token(";", 2, 1, 2),
        })
      end)
    end
  end -- end basic tokens

  do
    local scope = main_scope:new_scope("blank")

    scope:add_test("with space and tabs", function()
      test("  \t    ", {new_token("blank", 1, 1, 1, "  \t    ")})
    end)

    scope:add_test("1 newline", function()
      test("  \n", {new_token("blank", 1, 1, 1, "  \n")})
    end)

    scope:add_test("2 newlines", function()
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
      scope:add_test("ending with "..data.label, function()
        test(data.str, {
          new_token("blank", 1, 1, 1, "\n"),
          new_token(";", #data.str, 2, 1),
        })
      end)
    end
  end -- end blank

  do
    local scope = main_scope:new_scope("non block comment")

    scope:add_test("nothing special", function()
      local token = new_token("comment", 1, 1, 1, " foo")
      token.src_is_block_str = nil
      test("-- foo", {token})
    end)

    for _, data in ipairs{
      {str = "\n", label = "\\n"},
      {str = "\r", label = "\\r"},
    }
    do
      scope:add_test("ending with "..data.label, function()
        local token = new_token("comment", 1, 1, 1, " foo")
        token.src_is_block_str = nil
        test("-- foo"..data.str, {
          token,
          new_token("blank", 7, 1, 7, "\n"),
        })
      end)
    end

    scope:add_test("starting with '[===' which almost looks like a block comment", function()
      local token = new_token("comment", 1, 1, 1, "[===")
      token.src_is_block_str = nil
      test("--[===", {token})
    end)
  end -- end non block comment

  do
    local scope = main_scope:new_scope("non block string")

    for _, data in ipairs{
      {str = [["foo"]], quote = [["]], value = [[foo]], label = [[" quotes]]},
      {str = [['foo']], quote = [[']], value = [[foo]], label = [[' quotes]]},
      {str = [["foo'"]], quote = [["]], value = [[foo']], label = [[" quotes containing ']]},
      {str = [['foo"']], quote = [[']], value = [[foo"]], label = [[' quotes containing "]]},
    }
    do
      scope:add_test(data.label, function()
        local token = new_token("string", 1, 1, 1)
        token.src_is_block_str = nil
        token.value = data.value
        token.src_value = data.value
        token.src_quote = data.quote
        test(data.str, {token})
      end)
    end

    scope:add_test("unterminated at eof", function()
      local token = new_token("invalid", 1, 1, 1)
      token.value = [["foo]]
      token.error_code_insts = {error_code_util.new_error_code{
        error_code = error_code_util.codes.unterminated_string,
        source = test_source,
        position = {line = 1, column = 5},
      }}
      test([["foo]], {token})
    end)

    for _, data in ipairs{
      {str = "\n", label = "\\n"},
      {str = "\r", label = "\\r"},
    }
    do
      scope:add_test("ending with "..data.label, function()
        local token = new_token("invalid", 1, 1, 1)
        token.value = [["foo]]
        token.error_code_insts = {error_code_util.new_error_code{
          error_code = error_code_util.codes.unterminated_string_at_eol,
          message_args = {"1"},
          source = test_source,
          position = {line = 1, column = 5},
        }}
        test([["foo]]..data.str, {
          token,
          new_token("blank", 5, 1, 5, "\n"),
        })
      end)
    end

    local function add_escape_sequence_test(str, value)
      scope:add_test("containing escape sequence "..str, function()
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

    scope:add_test("containing invalid escape sequence \\x", function()
      local token = new_token("invalid", 1, 1, 1)
      token.src_is_block_str = nil
      token.value = [["\x"]]
      token.error_code_insts = {error_code_util.new_error_code{
        error_code = error_code_util.codes.invalid_hexadecimal_escape,
        message_args = {[[";]]},
        source = test_source,
        start_position = {line = 1, column = 2},
        stop_position = {line = 1, column = 3},
      }}
      test([["\x";]], {
        token,
        new_token(";", 5, 1, 5),
      })
    end)

    scope:add_test("containing invalid \\x with string and file ending right after", function()
      local token = new_token("invalid", 1, 1, 1)
      token.src_is_block_str = nil
      token.value = [["\x"]]
      token.error_code_insts = {error_code_util.new_error_code{
        error_code = error_code_util.codes.invalid_hexadecimal_escape,
        message_args = {[["]]},
        source = test_source,
        start_position = {line = 1, column = 2},
        stop_position = {line = 1, column = 3},
      }}
      test([["\x"]], {token})
    end)

    for _, data in ipairs{
      {str = "\n", label = "\\n"},
      {str = "\r", label = "\\r"},
      {str = "\n\r", label = "\\n\\r"},
      {str = "\r\n", label = "\\r\\n"},
    }
    do
      scope:add_test("containing escaped "..data.label, function()
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

    scope:add_test("containing escape sequence \\z with spaces", function()
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
      scope:add_test("containing escape sequence \\z with "..data.label, function()
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

    scope:add_test("containing invalid escape sequence \\256 (too large)", function()
      local token = new_token("invalid", 1, 1, 1)
      token.value = [["foo \256 bar"]]
      token.error_code_insts = {error_code_util.new_error_code{
        error_code = error_code_util.codes.too_large_decimal_escape,
        message_args = {[[256]]},
        source = test_source,
        start_position = {line = 1, column = 6},
        stop_position = {line = 1, column = 9},
      }}
      test([["foo \256 bar";]], {
        token,
        new_token(";", 15, 1, 15),
      })
    end)

    scope:add_test("containing invalid escape sequences", function()
      local all_valid_escaped_chars = util.invert{
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
            token.error_code_insts = {error_code_util.new_error_code{
              error_code = error_code_util.codes.unrecognized_escape,
              message_args = {c},
              source = test_source,
              start_position = {line = 1, column = 6},
              stop_position = {line = 1, column = 7},
            }}
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

    local each_syntax_error_in_a_string = {
      {label = "invalid \\x", str = [[\xha]], error_code = error_code_util.codes.invalid_hexadecimal_escape},
      {label = "invalid \\500", str = [[\500]], error_code = error_code_util.codes.too_large_decimal_escape},
      {label = "invalid escape", str = [[\_]], error_code = error_code_util.codes.unrecognized_escape},
    }
    for _, initial in ipairs(each_syntax_error_in_a_string) do
      for _, consecutive in ipairs(each_syntax_error_in_a_string) do
        for _, ending in ipairs{
          {label = "regular end of string", str = [["]], error_code = nil},
          {label = "unterminated at eof", str = "", error_code = error_code_util.codes.unterminated_string},
          {
            label = "unterminated at eol",
            str = "\n",
            error_code = error_code_util.codes.unterminated_string_at_eol,
            is_eol = true,
          },
        }
        do
          scope:add_test("syntax error chain: "..initial.label.." + "..consecutive.label.." + "..ending.label, function()
            local token = new_token("invalid", 1, 1, 1)
            local str = [["]]..initial.str..consecutive.str
            token.value = str..(ending.is_eol and "" or ending.str)
            local function create_error_code_inst(error_code)
              return error_code_util.new_error_code{
                error_code = error_code,
                -- these are already tested by other tests
                message_args = assert.do_not_compare_flag,
                source = test_source,
                -- same here
                position = {
                  line = assert.do_not_compare_flag--[[@as integer?]],
                  column = assert.do_not_compare_flag--[[@as integer?]],
                },
              }
            end
            token.error_code_insts = {
              create_error_code_inst(initial.error_code),
              create_error_code_inst(consecutive.error_code),
              ending.error_code and create_error_code_inst(ending.error_code),
            }
            str = str..ending.str
            test(str, {
              token,
              ending.is_eol and new_token("blank", #str, 1, #str, "\n") or nil
            })
          end)
        end
      end
    end
  end -- end non block string

  do
    local scope = main_scope:new_scope("block string")

    scope:add_test("invalid open bracket", function()
      local token = new_token("invalid", 1, 1, 1)
      token.value = "["
      token.error_code_insts = {error_code_util.new_error_code{
        error_code = error_code_util.codes.invalid_block_string_open_bracket,
        source = test_source,
        position = {line = 1, column = 1},
      }}
      test("[==", {
        token,
        new_token("==", 2, 1, 2),
      })
    end)

    scope:add_test("without padding", function()
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

    scope:add_test("with 3 padding", function()
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

    scope:add_test("with 3 padding containing 2 padding", function()
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
      scope:add_test("leading "..data.label, function()
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

      scope:add_test("containing "..data.label, function()
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
      scope:add_test(label, function()
        local token = new_token("invalid", 1, 1, 1)
        token.value = str
        token.error_code_insts = {error_code_util.new_error_code{
          error_code = error_code_util.codes.unterminated_block_string,
          source = test_source,
          position = str:find("\n") and {line = 2, column = 2} or {line = 1, column = #str + 1},
        }}
        test(str, {token})
      end)
    end

    add_unterminated_test("unterminated at eof", "[[;")
    add_unterminated_test("unterminated at eof right after start", "[[")
    add_unterminated_test("unterminated at eof with padding", "[===[;")
    add_unterminated_test("unterminated at eof with leading newline", "[[\n;")
  end -- end block string

  do
    local scope = main_scope:new_scope("block comment")

    scope:add_test("it's just a prefixed block string, so if this works it works", function()
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

    scope:add_test("invalid block comment", function()
      local token = new_token("invalid", 1, 1, 1)
      local str = "--[["
      token.value = str
      token.error_code_insts = {error_code_util.new_error_code{
        error_code = error_code_util.codes.unterminated_block_string,
        source = test_source,
        position = {line = 1, column = #str + 1}
      }}
      test(str, {token})
    end)
  end -- end block comment

  do
    local scope = main_scope:new_scope("number")

    local function add_test(str, value)
      scope:add_test("number '"..str.."'", function()
        local token = new_token("number", 1, 1, 1)
        token.value = value
        token.src_value = str
        test(str..";", {
          token,
          new_token(";", #str + 1, 1, #str + 1),
        })
      end)
    end

    add_test("1234567890", 1234567890)
    add_test(".1", .1)
    add_test("1.1", 1.1)
    add_test("1e1", 1e1)
    add_test("1E1", 1E1)
    add_test("1e+1", 1e+1)
    add_test("1e-1", 1e-1)
    add_test("0x1234567890", 0x1234567890)
    add_test("0xabcdef", 0xabcdef)
    add_test("0xABCDEF", 0xABCDEF)
    add_test("0x1aA", 0x1aA)
    add_test("0X1", 0X1)
    add_test("0x.1", 0x.1)
    add_test("0x1.1", 0x1.1)
    add_test("0x1p1", 0x1p1)
    add_test("0x1P1", 0x1P1)
    add_test("0x1p+1", 0x1p+1)
    add_test("0x1p-1", 0x1p-1)

    local function malformed(str)
      scope:add_test("malformed number '"..str.."'", function()
        local token = new_token("invalid", 1, 1, 1)
        token.value = str
        token.error_code_insts = {error_code_util.new_error_code{
          error_code = error_code_util.codes.malformed_number,
          message_args = {str},
          source = test_source,
          start_position = {line = 1, column = 1},
          stop_position = {line = 1, column = 2},
        }}
        test(str..";", {
          token,
          new_token(";", 3, 1, 3),
        })
      end)
    end
    malformed("0x")
    malformed("0X")
  end -- end number

  do
    local scope = main_scope:new_scope("ident")

    scope:add_test("ident 'foo'", function()
      test("foo;", {
        new_token("ident", 1, 1, 1, "foo"),
        new_token(";", 4, 1, 4),
      })
    end)

    scope:add_test("alphabet and underscore", function()
      test("abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ;", {
        new_token("ident", 1, 1, 1, "abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
        new_token(";", 54, 1, 54),
      })
    end)

    scope:add_test("ident '_foo'", function()
      test("_foo;", {
        new_token("ident", 1, 1, 1, "_foo"),
        new_token(";", 5, 1, 5),
      })
    end)

    scope:add_test("ident '_0123456789'", function()
      test("_0123456789;", {
        new_token("ident", 1, 1, 1, "_0123456789"),
        new_token(";", 12, 1, 12),
      })
    end)
  end -- end ident

  do
    local scope = main_scope:new_scope("other")

    scope:add_test("skip UTF8 BOM", function()
      test("\xef\xbb\xbf;\n;", {
        new_token(";", 4, 1, 1),
        new_token("blank", 5, 1, 2, "\n"),
        new_token(";", 6, 2, 1),
      })
    end)

    scope:add_test("read shebang", function()
      local state = test("#!/usr/bin/env lua\n;", {
        new_token("blank", 19, 1, 1, "\n"),
        new_token(";", 20, 2, 1),
      })
      assert.equals("#!/usr/bin/env lua", state.shebang_line, "state.shebang_line")
    end)

    scope:add_test("read shebang followed by eof", function()
      local state = test("#!/usr/bin/env lua", {})
      assert.equals("#!/usr/bin/env lua", state.shebang_line, "state.shebang_line")
    end)

    scope:add_test("skip UTF8 BOM and read shebang", function()
      local state = test("\xef\xbb\xbf#!/usr/bin/env lua\n;", {
        new_token("blank", 22, 1, 1, "\n"),
        new_token(";", 23, 2, 1),
      })
      assert.equals("#!/usr/bin/env lua", state.shebang_line, "state.shebang_line")
    end)

    scope:add_test("number plus ident '0foo'", function()
      local token = new_token("number", 1, 1, 1)
      token.value = 0
      token.src_value = "0"
      test("0foo", {
        token,
        new_token("ident", 2, 1, 2, "foo"),
      })
    end)

    local function with_sign(sign)
      local function should_be_ident(str)
        ---cSpell:ignore strtod
        scope:add_test(
          "number according to C strtod(), but ident in Lua: '"..(sign or "")..str.."'",
          function()
            local tokens = {}
            if sign then
              tokens[#tokens+1] = new_token(sign, 1, 1, 1)
            end
            tokens[#tokens+1] = new_token("ident", sign and 2 or 1, 1, sign and 2 or 1, str)
            test((sign or "")..str, tokens)
          end
        )
      end
      should_be_ident("inf")
      should_be_ident("INF")
      should_be_ident("infinity")
      should_be_ident("INFINITY")
      should_be_ident("NaN")
      should_be_ident("nan")
    end
    with_sign()
    with_sign("+")
    with_sign("-")
  end -- end other
end
