
local framework = require("test_framework")
local assert = require("assert")

local tokenize = require("tokenize")
local nodes = require("nodes")
local parser = require("parser")
local ast = require("ast_util")
local error_code_util = require("error_code_util")

local test_source = "=(test)"
local prevent_assert = nodes.new_invalid{
  error_code_inst = error_code_util.new_error_code{
    error_code = error_code_util.codes.incomplete_node,
    source = test_source,
    position = {line = 0, column = 0},
  }
}
local fake_main
local fake_stat_elem = assert.do_not_compare_flag

local function make_fake_main()
  local fake_env_scope = nodes.new_env_scope{}
  -- Lua emits _ENV as if it's a local in the parent scope
  -- of the file. I'll probably change this one day to be
  -- the first upval of the parent scope, since load()
  -- clobbers the first upval anyway to be the new _ENV value
  local def = ast.create_local_def("_ENV", fake_env_scope)
  def.whole_block = true
  fake_env_scope.locals[1] = def

  fake_main = ast.append_stat(fake_env_scope, function(stat_elem)
    local main = nodes.new_functiondef{
      stat_elem = stat_elem,
      is_main = true,
      source = test_source,
      parent_scope = fake_env_scope,
      is_vararg = true,
    }
    main.eof_token = nodes.new_token({token_type = "eof", leading = {}})
    return main
  end)
end

local function get_tokens(str)
  local leading = {}
  local tokens = {}
  for _, token in tokenize(str) do
    if token.token_type == "blank" or token.token_type == "comment" then
      leading[#leading+1] = token
    else
      token.leading = leading
      leading = {}
      tokens[#tokens+1] = token
    end
  end
  tokens[#tokens+1] = {
    token_type = "eof",
    leading = leading,
  }
  return tokens
end

do
  local wrapped_nodes = {}
  for name, func in pairs(nodes) do
    if name == "set_position"
      or name == "new_env_scope"
      or name == "new_token"
      or name == "new_invalid"
    then
      wrapped_nodes[name] = func
    else
      wrapped_nodes[name] = function(param)
        param.stat_elem = param.stat_elem or fake_stat_elem
        return func(param)
      end
    end
  end
  nodes = wrapped_nodes
end

local function append_stat(scope, stat)
  ast.append_stat(scope, function(stat_elem)
    return stat
  end)
end

---@param semi_colon_token_node AstTokenNode
local function append_empty(scope, semi_colon_token_node)
  append_stat(scope, nodes.new_empty{
    semi_colon_token = semi_colon_token_node,
  })
end

local function new_true_node(true_token)
  return nodes.new_boolean{
    position = true_token,
    value = true,
  }
end

local serpent_opts = {
  keyignore = {
    first = true,
    last = true,
    next = true,
    prev = true,
    stat_elem = true,
    scope = true,
    list = true,
    parent_scope = true,
  },
}

local expected_invalid_nodes

local function new_invalid(error_code, position, message_args, tokens)
  local invalid = nodes.new_invalid{
    error_code_inst = error_code_util.new_error_code{
      error_code = error_code,
      message_args = message_args,
      source = test_source,
      position = position,
      location_str = assert.do_not_compare_flag, -- TODO: test the syntax_error location string logic
    },
    tokens = tokens or {},
  }
  expected_invalid_nodes[#expected_invalid_nodes+1] = invalid
  return invalid
end

local function before_each()
  make_fake_main()
  expected_invalid_nodes = {}
end

local function test_stat(str)
  assert.assert(fake_main, "must run make_fake_main before each test")
  local main, got_invalid_nodes = parser(str, test_source)
  assert.contents_equals(
    fake_main,
    main,
    nil,
    {
      root_name = "main",
      print_full_data_on_error = print_full_data_on_error,
      serpent_opts = serpent_opts,
    }
  )
  assert.contents_equals(
    expected_invalid_nodes or {},
    got_invalid_nodes,
    nil,
    {
      root_name = "invalid_nodes",
      print_full_data_on_error = print_full_data_on_error,
      serpent_opts = serpent_opts,
    }
  )
  fake_main = nil
end

do
  local main_scope = framework.scope:new_scope("parser")

  do
    local stat_scope = main_scope:new_scope("statements")

    local tokens
    local next_token
    local peek_next_token
    local function add_stat_test(name, str, func)
      stat_scope:register_test(name, function()
        before_each()
        tokens = get_tokens(str)
        local next_index = 1
        function next_token()
          next_index = next_index + 1
          return tokens[next_index - 1]
        end
        function peek_next_token()
          return tokens[next_index]
        end
        func()
        test_stat(str)
      end)
    end

    local function next_token_node()
      return nodes.new_token(next_token())
    end

    add_stat_test(
      "empty",
      ";",
      function()
        local stat = nodes.new_empty{
          semi_colon_token = next_token_node(),
        }
        append_stat(fake_main, stat)
      end
    )

    do -- ifstat
      local function new_testblock()
        local testblock = nodes.new_testblock{
          parent_scope = fake_main,
          if_token = next_token_node(),
          condition = new_true_node(next_token()),
          then_token = next_token_node(),
        }
        append_empty(testblock, next_token_node())
        return testblock
      end

      add_stat_test(
        "ifstat with 1 testblock",
        "if true then ; end",
        function()
          local stat = nodes.new_ifstat{
            ifs = {new_testblock()},
            end_token = next_token_node(),
          }
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "ifstat with 2 testblocks",
        "if true then ; elseif true then ; end",
        function()
          local stat = nodes.new_ifstat{
            ifs = {
              new_testblock(),
              new_testblock(),
            },
            end_token = next_token_node(),
          }
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "ifstat with elseblock",
        "if true then ; else ; end",
        function()
          local testblock = new_testblock()
          local elseblock = nodes.new_elseblock{
            parent_scope = fake_main,
            else_token = next_token_node(),
          }
          append_empty(elseblock, next_token_node())
          local stat = nodes.new_ifstat{
            ifs = {testblock},
            elseblock = elseblock,
            end_token = next_token_node(),
          }
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "ifstat without 'then'",
        "if true ;",
          function()
          local testblock = nodes.new_testblock{
            parent_scope = fake_main,
            if_token = next_token_node(),
            condition = new_true_node(next_token()),
            then_token = new_invalid(
              error_code_util.codes.expected_token,
              peek_next_token(),
              {"then"}
            ),
          }
          local stat = nodes.new_ifstat{
            ifs = {testblock},
          }
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      local function add_ifstat_without_else_but_with(last_keyword)
        add_stat_test(
          "ifstat without 'then' but with '"..last_keyword.."'",
          "if true "..last_keyword,
          function()
            local testblock = nodes.new_testblock{
              parent_scope = fake_main,
              if_token = next_token_node(),
              condition = new_true_node(next_token()),
              then_token = new_invalid(
                error_code_util.codes.expected_token,
                peek_next_token(),
                {"then"}
              ),
            }
            local stat = nodes.new_ifstat{
              ifs = {testblock},
            }
            append_stat(fake_main, stat)
            append_stat(fake_main, new_invalid(
              error_code_util.codes.expected_token,
              peek_next_token(),
              {"eof"}
            ))
            append_stat(fake_main, new_invalid(
              error_code_util.codes.unexpected_token,
              peek_next_token(),
              nil,
              {next_token_node()} -- consuming `last_keyword`
            ))
          end
        )
      end
      add_ifstat_without_else_but_with("else")
      add_ifstat_without_else_but_with("end")

      add_stat_test(
        "ifstat without 'end'",
        "if true then ;",
        function()
          local stat = nodes.new_ifstat{
            ifs = {new_testblock()},
            end_token = new_invalid(
              error_code_util.codes.expected_closing_match,
              peek_next_token(),
              {"end", "if", "1:1"}
            ),
          }
          append_stat(fake_main, stat)
        end
      )
    end -- end ifstat

    do -- whilestat
      add_stat_test(
        "whilestat",
        "while true do ; end",
        function()
          local stat = nodes.new_whilestat{
            parent_scope = fake_main,
            while_token = next_token_node(),
            condition = new_true_node(next_token()),
            do_token = next_token_node(),
          }
          append_empty(stat, next_token_node())
          stat.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "whilestat without do",
        "while true ;",
        function()
          local stat = nodes.new_whilestat{
            parent_scope = fake_main,
            while_token = next_token_node(),
            condition = new_true_node(next_token()),
            do_token = new_invalid(
              error_code_util.codes.expected_token,
              peek_next_token(),
              {"do"}
            ),
          }
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "while without 'end'",
        "while true do ;",
        function()
          local stat = nodes.new_whilestat{
            parent_scope = fake_main,
            while_token = next_token_node(),
            condition = new_true_node(next_token()),
            do_token = next_token_node(),
          }
          append_empty(stat, next_token_node())
          stat.end_token = new_invalid(
            error_code_util.codes.expected_closing_match,
            peek_next_token(),
            {"end", "while", "1:1"}
          )
          append_stat(fake_main, stat)
        end
      )
    end -- end whilestat

    do -- dostat
      add_stat_test(
        "dostat",
        "do ; end",
        function()
          local stat = nodes.new_dostat{
            parent_scope = fake_main,
            do_token = next_token_node(),
          }
          append_empty(stat, next_token_node())
          stat.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "dostat without 'end'",
        "do ;",
        function()
          local stat = nodes.new_dostat{
            parent_scope = fake_main,
            do_token = next_token_node(),
          }
          append_empty(stat, next_token_node())
          stat.end_token = new_invalid(
            error_code_util.codes.expected_closing_match,
            peek_next_token(),
            {"end", "do", "1:1"}
          )
          append_stat(fake_main, stat)
        end
      )
    end -- end dostat

    do -- fornum and or forlist
      add_stat_test(
        "fornum/forlist with invalid ident",
        "for . ;",
        function()
          append_stat(fake_main, new_invalid(
            error_code_util.codes.expected_ident,
            tokens[2], -- at '.'
            nil,
            {next_token_node()} -- consuming 'for' token
          ))
          append_stat(fake_main, new_invalid(
            error_code_util.codes.unexpected_token,
            peek_next_token(), -- at '.'
            nil,
            {next_token_node()} -- consuming '.'
          ))
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "fornum without '=' and forlist without ',' or 'in'",
        "for i ;",
        function()
          append_stat(fake_main, new_invalid(
            error_code_util.codes.expected_eq_comma_or_in,
            tokens[3], -- at ';'
            nil,
            {next_token_node(), next_token_node()} -- consuming 'for' and 'i'
          ))
          append_empty(fake_main, next_token_node())
        end
      )
    end -- end fornum and or forlist

    do -- fornum
      local function add_fornum_stat(has_step)
        local for_token = next_token_node()
        local var_def, var_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
        var_def.whole_block = true
        local stat = nodes.new_fornum{
          parent_scope = fake_main,
          for_token = for_token,
          var = var_ref,
          locals = {var_def},
          eq_token = next_token_node(),
          start = new_true_node(next_token()),
          first_comma_token = next_token_node(),
          stop = new_true_node(next_token()),
        }
        if has_step then
          stat.second_comma_token = next_token_node()
          stat.step = new_true_node(next_token())
        end
        stat.do_token = next_token_node()
        append_empty(stat, next_token_node())
        stat.end_token = next_token_node()
        append_stat(fake_main, stat)
      end

      add_stat_test(
        "fornum without step",
        "for i = true, true do ; end",
        function()
          add_fornum_stat(false)
        end
      )

      add_stat_test(
        "fornum with step",
        "for i = true, true, true do ; end",
        function()
          add_fornum_stat(true)
        end
      )

      add_stat_test(
        "fornum without first ','",
        "for i = true ;",
        function()
          local for_token = next_token_node()
          local var_def, var_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          var_def.whole_block = true
          local stat = nodes.new_fornum{
            parent_scope = fake_main,
            for_token = for_token,
            var = var_ref,
            locals = {var_def},
            eq_token = next_token_node(),
            start = new_true_node(next_token()),
            first_comma_token = new_invalid(
              error_code_util.codes.expected_token,
              peek_next_token(), -- at ';'
              {","}
            ),
            stop = prevent_assert,
          }
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "fornum without 'do'",
        "for i = true, true ;",
        function()
          local for_token = next_token_node()
          local var_def, var_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          var_def.whole_block = true
          local stat = nodes.new_fornum{
            parent_scope = fake_main,
            for_token = for_token,
            var = var_ref,
            locals = {var_def},
            eq_token = next_token_node(),
            start = new_true_node(next_token()),
            first_comma_token = next_token_node(),
            stop = new_true_node(next_token()),
            do_token = new_invalid(
              error_code_util.codes.expected_token,
              peek_next_token(), -- at ';'
              {"do"}
            ),
          }
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "fornum without 'end'",
        "for i = true, true do ;",
        function()
          local for_token = next_token_node()
          local var_def, var_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          var_def.whole_block = true
          local stat = nodes.new_fornum{
            parent_scope = fake_main,
            for_token = for_token,
            var = var_ref,
            locals = {var_def},
            eq_token = next_token_node(),
            start = new_true_node(next_token()),
            first_comma_token = next_token_node(),
            stop = new_true_node(next_token()),
            do_token = next_token_node(),
          }
          append_empty(stat, next_token_node())
          stat.end_token = new_invalid(
            error_code_util.codes.expected_closing_match,
            peek_next_token(), -- at 'eof'
            {"end", "for", "1:1"}
          )
          append_stat(fake_main, stat)
        end
      )
    end -- end fornum

    do -- forlist
      add_stat_test(
        "forlist with 1 name",
        "for foo in true do ; end",
        function()
          local name_def, name_ref = ast.create_local(tokens[2], fake_main, fake_stat_elem)
          name_def.whole_block = true
          local stat = nodes.new_forlist{
            parent_scope = fake_main,
            for_token = next_token_node(),
            name_list = {name_ref},
            comma_tokens = {},
            locals = {name_def},
            -- skip 1 token
            in_token = (function() next_token() return next_token_node() end)(),
            exp_list = {new_true_node(next_token())},
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = {},
            do_token = next_token_node(),
          }
          append_empty(stat, next_token_node())
          stat.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      local function add_forlist_with_x_names_test(name_count, names_str)
        add_stat_test(
          "forlist with "..name_count.." names",
          "for "..names_str.." in true do ; end",
          function()
            local stat = nodes.new_forlist{
              parent_scope = fake_main,
              for_token = next_token_node(),
              comma_tokens = {},
              exp_list = {prevent_assert},
              -- technically both `{}` and `nil` are valid
              exp_list_comma_tokens = {},
            }
            for i = 1, name_count do
              if i ~= 1 then
                stat.comma_tokens[i - 1] = next_token_node()
              end
              local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
              name_def.whole_block = true
              stat.name_list[i] = name_ref
              stat.locals[i] = name_def
            end
            stat.in_token = next_token_node()
            stat.exp_list[1] = new_true_node(next_token())
            stat.do_token = next_token_node()
            append_empty(stat, next_token_node())
            stat.end_token = next_token_node()
            append_stat(fake_main, stat)
          end
        )
      end
      add_forlist_with_x_names_test(2, "foo, bar")
      add_forlist_with_x_names_test(3, "foo, bar, baz")

      add_stat_test(
        "forlist with invalid name list",
        "for foo, ;",
        function()
          local stat = nodes.new_forlist{
            parent_scope = fake_main,
            for_token = next_token_node(),
            comma_tokens = {},
            exp_list = {prevent_assert},
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = nil,
          }
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          name_def.whole_block = true
          stat.name_list[1] = name_ref
          stat.locals[1] = name_def
          stat.comma_tokens[1] = next_token_node()
          stat.name_list[2] = new_invalid(
            error_code_util.codes.expected_ident,
            peek_next_token() -- at ';'
          )
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "forlist with invalid name list, but continuing with 'in'",
        "for foo, in true do ; end",
        function()
          local stat = nodes.new_forlist{
            parent_scope = fake_main,
            for_token = next_token_node(),
            comma_tokens = {},
            exp_list = {prevent_assert},
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = {},
          }
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          name_def.whole_block = true
          stat.name_list[1] = name_ref
          stat.locals[1] = name_def
          stat.comma_tokens[1] = next_token_node()
          stat.name_list[2] = new_invalid(
            error_code_util.codes.expected_ident,
            peek_next_token() -- at 'in'
          )
          stat.in_token = next_token_node()
          stat.exp_list[1] = new_true_node(next_token())
          stat.do_token = next_token_node()
          append_empty(stat, next_token_node())
          stat.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "forlist without 'do'",
        "for foo in true ;",
        function()
          local stat = nodes.new_forlist{
            parent_scope = fake_main,
            for_token = next_token_node(),
            comma_tokens = {},
            exp_list = {prevent_assert},
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = {},
          }
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          name_def.whole_block = true
          stat.name_list[1] = name_ref
          stat.locals[1] = name_def
          stat.in_token = next_token_node()
          stat.exp_list[1] = new_true_node(next_token())
          stat.do_token = new_invalid(
            error_code_util.codes.expected_token,
            peek_next_token(), -- at ';'
            {"do"}
          )
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "forlist without 'end'",
        "for foo in true do ;",
        function()
          local stat = nodes.new_forlist{
            parent_scope = fake_main,
            for_token = next_token_node(),
            comma_tokens = {},
            exp_list = {prevent_assert},
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = {},
          }
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          name_def.whole_block = true
          stat.name_list[1] = name_ref
          stat.locals[1] = name_def
          stat.in_token = next_token_node()
          stat.exp_list[1] = new_true_node(next_token())
          stat.do_token = next_token_node()
          append_empty(stat, next_token_node())
          stat.end_token = new_invalid(
            error_code_util.codes.expected_closing_match,
            peek_next_token(), -- at 'eof'
            {"end", "for", "1:1"}
          )
          append_stat(fake_main, stat)
        end
      )
    end -- end forlist

    do -- repeatstat
      add_stat_test(
        "repeatstat",
        "repeat ; until true",
        function()
          local stat = nodes.new_repeatstat{
            parent_scope = fake_main,
            repeat_token = next_token_node(),
            condition = prevent_assert,
          }
          append_empty(stat, next_token_node())
          stat.until_token = next_token_node()
          stat.condition = new_true_node(next_token())
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "repeatstat without 'until'",
        "repeat ;",
        function()
          local stat = nodes.new_repeatstat{
            parent_scope = fake_main,
            repeat_token = next_token_node(),
            condition = prevent_assert,
          }
          append_empty(stat, next_token_node())
          stat.until_token = new_invalid(
            error_code_util.codes.expected_closing_match,
            peek_next_token(), -- at 'eof'
            {"until", "repeat", "1:1"}
          )
          append_stat(fake_main, stat)
        end
      )
    end -- end repeatstat

    do -- funcstat
      add_stat_test(
        "funcstat",
        "function foo() ; end",
        function()
          local function_token = next_token_node()
          local stat = nodes.new_funcstat{
            name = ast.get_ref(fake_main, fake_stat_elem, "foo", next_token()),
            func_def = nodes.new_functiondef{
              parent_scope = fake_main,
              source = test_source,
              function_token = function_token,
              open_paren_token = next_token_node(),
              close_paren_token = next_token_node(),
              -- technically both `{}` and `nil` are valid
              param_comma_tokens = {},
            },
          }
          fake_main.func_protos[1] = stat.func_def
          append_empty(stat.func_def, next_token_node())
          stat.func_def.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      local function index_into(ex)
        return nodes.new_index{
          ex = ex,
          dot_token = next_token_node(),
          suffix = nodes.new_string{
            position = peek_next_token(),
            value = next_token().value,
            src_is_ident = true,
          },
        }
      end

      add_stat_test(
        "funcstat with 'foo.bar.baz' name",
        "function foo.bar.baz() ; end",
        function()
          local function_token = next_token_node()
          local foo = ast.get_ref(fake_main, fake_stat_elem, "foo", next_token())
          local bar = index_into(foo)
          local baz = index_into(bar)
          local stat = nodes.new_funcstat{
            name = baz,
            func_def = nodes.new_functiondef{
              parent_scope = fake_main,
              source = test_source,
              function_token = function_token,
              open_paren_token = next_token_node(),
              close_paren_token = next_token_node(),
              -- technically both `{}` and `nil` are valid
              param_comma_tokens = {},
            },
          }
          fake_main.func_protos[1] = stat.func_def
          append_empty(stat.func_def, next_token_node())
          stat.func_def.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "funcstat with 'foo:bar' name (method)",
        "function foo:bar() ; end",
        function()
          local function_token = next_token_node()
          local foo = ast.get_ref(fake_main, fake_stat_elem, "foo", next_token())
          local bar = index_into(foo)
          local stat = nodes.new_funcstat{
            name = bar,
            func_def = nodes.new_functiondef{
              parent_scope = fake_main,
              source = test_source,
              is_method = true,
              function_token = function_token,
              open_paren_token = next_token_node(),
              close_paren_token = next_token_node(),
              -- technically both `{}` and `nil` are valid
              param_comma_tokens = {},
            },
          }
          local self_def = ast.create_local_def("self", stat.func_def)
          self_def.whole_block = true
          self_def.src_is_method_self = true
          stat.func_def.locals[1] = self_def
          fake_main.func_protos[1] = stat.func_def
          append_empty(stat.func_def, next_token_node())
          stat.func_def.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "funcstat without ident",
        "function ;",
        function()
          local function_token = next_token_node()
          append_stat(fake_main, new_invalid(
            error_code_util.codes.expected_ident,
            peek_next_token(), -- at ';'
            nil,
            {function_token} -- consuming 'function'
          ))
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "funcstat with invalid 'foo:bar.baz' name",
        "function foo:bar.baz ;",
        function()
          local function_token = next_token_node()
          local foo = ast.get_ref(fake_main, fake_stat_elem, "foo", next_token())
          local bar = index_into(foo)
          local stat = nodes.new_funcstat{
            name = bar,
            func_def = nodes.new_functiondef{
              parent_scope = fake_main,
              source = test_source,
              is_method = true,
              function_token = function_token,
              open_paren_token = new_invalid(
                error_code_util.codes.expected_token,
                peek_next_token(), -- at '.'
                {"("}
              ),
              -- technically both `{}` and `nil` are valid
              param_comma_tokens = {},
            },
          }
          local self_def = ast.create_local_def("self", stat.func_def)
          self_def.whole_block = true
          self_def.src_is_method_self = true
          stat.func_def.locals[1] = self_def
          fake_main.func_protos[1] = stat.func_def
          append_stat(fake_main, stat)
          append_stat(fake_main, new_invalid(
            error_code_util.codes.unexpected_token,
            peek_next_token(), -- at '.'
            nil,
            {next_token_node()} -- consuming '.'
          ))
          ast.get_ref(fake_main, fake_stat_elem, "baz", peek_next_token())
          local baz_token = next_token()
          append_stat(fake_main, new_invalid(
            error_code_util.codes.unexpected_expression,
            peek_next_token(), -- at ';' (unfortunately... but might change?)
            nil,
            -- failing because the parser doesn't add the consumed tokens yet
            {baz_token} -- consuming 'baz'
          ))
          append_empty(fake_main, next_token_node())
        end
      )
    end -- end funcstat

    do -- localstat
      local function add_localstat_with_x_names_test(name_count, names_str)
        add_stat_test(
          "localstat with "..name_count.." name"..(name_count == 1 and "" or "s"),
          "local "..names_str..";",
          function()
            local local_token = next_token_node()
            local lhs = {}
            -- technically both `{}` and `nil` are valid (if name_count == 1)
            local lhs_comma_tokens = {}
            for i = 1, name_count do
              if i ~= 1 then
                lhs_comma_tokens[i - 1] = next_token_node()
              end
              local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
              fake_main.locals[i] = name_def
              lhs[i] = name_ref
            end
            local stat = nodes.new_localstat{
              local_token = local_token,
              lhs = lhs,
              lhs_comma_tokens = lhs_comma_tokens,
              -- no rhs, this should be nil
              rhs_comma_tokens = nil,
            }
            for _, ref in ipairs(stat.lhs) do
              ref.reference_def.start_at = stat
              ref.reference_def.start_offset = 1
            end
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )
      end
      add_localstat_with_x_names_test(1, "foo")
      add_localstat_with_x_names_test(2, "foo, bar")
      add_localstat_with_x_names_test(3, "foo, bar, baz")

      add_stat_test(
        "localstat with rhs",
        "local foo = true, true;",
        function()
          local local_token = next_token_node()
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          fake_main.locals[1] = name_def
          local stat = nodes.new_localstat{
            local_token = local_token,
            lhs = {name_ref},
            -- technically both `{}` and `nil` are valid
            lhs_comma_tokens = {},
            eq_token = next_token_node(),
            rhs = {new_true_node(next_token())},
            rhs_comma_tokens = {next_token_node()},
          }
          name_def.start_at = stat
          name_def.start_offset = 1
          stat.rhs[2] = new_true_node(next_token())
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "localstat without ident",
        "local ;",
        function()
          local stat = nodes.new_localstat{
            local_token = next_token_node(),
            lhs = {new_invalid(
              error_code_util.codes.expected_ident,
              peek_next_token() -- at ';'
            )},
            -- technically both `{}` and `nil` are valid
            lhs_comma_tokens = {},
            -- no rhs, this should be nil
            rhs_comma_tokens = nil,
          }
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "localstat with invalid ident but continuing with '='",
        "local foo, = true;",
        function()
          local local_token = next_token_node()
          local foo_def, foo_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          fake_main.locals[1] = foo_def
          local stat = nodes.new_localstat{
            local_token = local_token,
            lhs = {foo_ref, new_invalid(
              error_code_util.codes.expected_ident,
              tokens[4] -- at '='
            )},
            lhs_comma_tokens = {next_token_node()},
            eq_token = next_token_node(),
            rhs = {new_true_node(next_token())},
            -- technically both `{}` and `nil` are valid
            rhs_comma_tokens = {},
          }
          foo_def.start_at = stat
          foo_def.start_offset = 1
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )
    end -- end localstat

    do -- localfunc
      add_stat_test(
        "localfunc",
        "local function foo() ; end",
        function()
          local local_token = next_token_node()
          local function_token = next_token_node()
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          fake_main.locals[1] = name_def
          local stat = nodes.new_localfunc{
            local_token = local_token,
            name = name_ref,
            func_def = nodes.new_functiondef{
              parent_scope = fake_main,
              source = test_source,
              function_token = function_token,
              open_paren_token = next_token_node(),
              close_paren_token = next_token_node(),
              -- technically both `{}` and `nil` are valid
              param_comma_tokens = {},
            }
          }
          fake_main.func_protos[1] = stat.func_def
          name_def.start_at = stat
          name_def.start_offset = 0
          append_empty(stat.func_def, next_token_node())
          stat.func_def.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "localfunc without ident",
        "local function() ; end",
        function()
          local local_token = next_token_node()
          local function_token = next_token_node()
          local stat = nodes.new_localfunc{
            local_token = local_token,
            name = new_invalid(
              error_code_util.codes.expected_ident,
              peek_next_token() -- at ';'
            ),
            func_def = nodes.new_functiondef{
              parent_scope = fake_main,
              source = test_source,
              function_token = function_token,
              open_paren_token = next_token_node(),
              close_paren_token = next_token_node(),
              -- technically both `{}` and `nil` are valid
              param_comma_tokens = {},
            }
          }
          fake_main.func_protos[1] = stat.func_def
          append_empty(stat.func_def, next_token_node())
          stat.func_def.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )
    end -- end localfunc

    do -- label
      local function add_label_test(label, extra_str, extra_code)
        add_stat_test(
          label,
          "::foo:: "..(extra_str or "").." ;",
          function()
            local stat = nodes.new_label{
              open_token = next_token_node(),
              name = peek_next_token().value,
              name_token = next_token_node(),
              close_token = next_token_node(),
            }
            stat.name_token.value = nil
            fake_main.labels[stat.name] = stat
            append_stat(fake_main, stat)
            if extra_code then extra_code() end
            append_empty(fake_main, next_token_node())
          end
        )
      end

      add_label_test("label")

      add_stat_test(
        "label without ident",
        ":: ;",
        function()
          append_stat(fake_main, new_invalid(
            error_code_util.codes.expected_ident,
            tokens[2], -- at ';'
            nil,
            {next_token_node()} -- consuming '::'
          ))
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "label without closing '::'",
        "::foo ;",
        function()
          local stat = nodes.new_label{
            open_token = next_token_node(),
            name = peek_next_token().value,
            name_token = next_token_node(),
            close_token = new_invalid(
              error_code_util.codes.expected_token,
              peek_next_token(), -- at ';'
              {"::"}
            ),
          }
          stat.name_token.value = nil
          fake_main.labels[stat.name] = stat
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_label_test("label duplicate", "::foo::", function()
        append_stat(fake_main, new_invalid(
          error_code_util.codes.duplicate_label,
          tokens[5], -- at the second 'foo'
          {"foo", "1:3"},
          {next_token_node(), next_token_node(), next_token_node()} -- consuming '::foo::'
        ))
      end)

      add_label_test("label duplicate without closing '::'", "::foo", function()
        append_stat(fake_main, new_invalid(
          error_code_util.codes.duplicate_label,
          tokens[5], -- at the second 'foo'
          {"foo", "1:3"},
          {next_token_node(), next_token_node()} -- consuming '::foo'
        ))
        append_stat(fake_main, new_invalid(
          error_code_util.codes.expected_token,
          peek_next_token(), -- at ';'
          {"::"}
        ))
      end)
    end -- end label

    do -- retstat
      add_stat_test(
        "retstat without results",
        "return",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = nil,
          }
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "retstat with 1 result",
        "return true",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            exp_list = {new_true_node(next_token())},
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = {},
          }
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "retstat with 2 results",
        "return true, true",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            exp_list = {new_true_node(next_token()), nil},
            exp_list_comma_tokens = {next_token_node()},
          }
          stat.exp_list[2] = new_true_node(next_token())
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "retstat without results with ';'",
        "return;",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = nil,
            semi_colon_token = next_token_node(),
          }
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "retstat with 1 result and with ';'",
        "return true;",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            exp_list = {new_true_node(next_token())},
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = {},
            semi_colon_token = next_token_node(),
          }
          append_stat(fake_main, stat)
        end
      )

      add_stat_test(
        "retstat ends the current block",
        "return; ;",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            -- technically both `{}` and `nil` are valid
            exp_list_comma_tokens = nil,
            semi_colon_token = next_token_node(),
          }
          append_stat(fake_main, stat)
          append_stat(fake_main, new_invalid(
            error_code_util.codes.expected_token,
            peek_next_token(),
            {"eof"}
          ))
          append_empty(fake_main, next_token_node())
        end
      )
    end -- end retstat

    do -- breakstat
      add_stat_test(
        "breakstat",
        "break;",
        function()
          local stat = nodes.new_breakstat{
            break_token = next_token_node(),
          }
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )
    end -- end breakstat
  end -- end statements
end
