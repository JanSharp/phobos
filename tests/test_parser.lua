
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

local function new_invalid(error_code, position, message_args, consumed_nodes)
  local invalid = nodes.new_invalid{
    error_code_inst = error_code_util.new_error_code{
      error_code = error_code,
      message_args = message_args,
      source = test_source,
      position = position,
      location_str = assert.do_not_compare_flag, -- TODO: test the syntax_error location string logic
    },
    consumed_nodes = consumed_nodes or {},
  }
  expected_invalid_nodes[#expected_invalid_nodes+1] = invalid
  return invalid
end

local function get_ref_helper(name, position, scope)
  return ast.get_ref(scope or fake_main, fake_stat_elem, name, position)
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

  local current_testing_scope
  local tokens
  local next_token
  local peek_next_token
  local function add_stat_test(name, str, func)
    current_testing_scope:add_test(name, function()
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

  do
    local stat_scope = main_scope:new_scope("statements")
    current_testing_scope = stat_scope

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
            name = get_ref_helper("foo", next_token()),
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
          local foo = get_ref_helper("foo", next_token())
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
          local foo = get_ref_helper("foo", next_token())
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
          local foo = get_ref_helper("foo", next_token())
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
          append_stat(fake_main, new_invalid(
            error_code_util.codes.unexpected_expression,
            peek_next_token(), -- at 'baz'
            nil,
            {get_ref_helper("baz", next_token())} -- consuming 'baz'
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

    do -- gotostat
      add_stat_test(
        "gotostat",
        "goto foo;",
        function()
          local stat = nodes.new_gotostat{
            goto_token = next_token_node(),
            target_name = "foo",
            target_token = next_token_node(),
          }
          stat.target_token.value = nil
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_stat_test(
        "gotostat without ident",
        "goto ;",
        function()
          append_stat(fake_main, new_invalid(
            error_code_util.codes.expected_ident,
            tokens[2], -- at ';'
            nil,
            {next_token_node()} -- consuming 'goto'
          ))
          append_empty(fake_main, next_token_node())
        end
      )
    end -- end gotostat

    do -- expression statements
      do -- call
        -- call statements are quite literally just call expressions in a different context
        -- so if this works, they all work (or, well, work as well as the call expressions do)
        add_stat_test(
          "call statement",
          "foo();",
          function()
            local stat = nodes.new_call{
              ex = get_ref_helper("foo", next_token()),
              open_paren_token = next_token_node(),
              close_paren_token = next_token_node(),
              -- technically both `{}` and `nil` are valid
              args_comma_tokens = nil,
            }
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )
      end -- end call

      do -- assignment
        add_stat_test(
          "assignment with 1 lhs, 1 rhs",
          "foo = true;",
          function()
            local stat = nodes.new_assignment{
              lhs = {get_ref_helper("foo", next_token())},
              -- technically both `{}` and `nil` are valid
              lhs_comma_tokens = {},
              eq_token = next_token_node(),
              rhs = {new_true_node(next_token())},
              -- technically both `{}` and `nil` are valid
              rhs_comma_tokens = {},
            }
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )

        local function get_foo_bar_lhs()
          local lhs = {get_ref_helper("foo", next_token()), nil}
          local lhs_comma_tokens = {next_token_node()}
          lhs[2] = get_ref_helper("bar", next_token())
          return lhs, lhs_comma_tokens
        end

        add_stat_test(
          "assignment with 2 lhs, 1 rhs",
          "foo, bar = true;",
          function()
            local lhs, lhs_comma_tokens = get_foo_bar_lhs()
            local stat = nodes.new_assignment{
              lhs = lhs,
              lhs_comma_tokens = lhs_comma_tokens,
              eq_token = next_token_node(),
              rhs = {new_true_node(next_token())},
              -- technically both `{}` and `nil` are valid
              rhs_comma_tokens = {},
            }
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )

        add_stat_test(
          "assignment with 1 lhs, 2 rhs",
          "foo = true, true;",
          function()
            local stat = nodes.new_assignment{
              lhs = {get_ref_helper("foo", next_token())},
              -- technically both `{}` and `nil` are valid
              lhs_comma_tokens = {},
              eq_token = next_token_node(),
              rhs = {new_true_node(next_token()), nil},
              rhs_comma_tokens = {next_token_node()},
            }
            stat.rhs[2] = new_true_node(next_token())
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )

        add_stat_test(
          "assignment with 2 lhs without '='",
          "foo, bar ;",
          function()
            -- needs 2 lhs otherwise it won't be considered an assignment to begin with
            local lhs, lhs_comma_tokens = get_foo_bar_lhs()
            local stat = nodes.new_assignment{
              lhs = lhs,
              lhs_comma_tokens = lhs_comma_tokens,
              eq_token = new_invalid(
                error_code_util.codes.expected_token,
                peek_next_token(), -- at ';'
                {"="}
              ),
              -- technically both `{}` and `nil` are valid
              rhs_comma_tokens = nil,
            }
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )

        local function add_invalid_lhs_assignment_tests(str, get_invalid_lhs_node)
          add_stat_test(
            "assignment with '"..str.."' lhs",
            str.." = true;",
            function()
              local stat = nodes.new_assignment{
                lhs = {get_invalid_lhs_node()},
                -- technically both `{}` and `nil` are valid
                lhs_comma_tokens = {},
                eq_token = next_token_node(),
                rhs = {new_true_node(next_token())},
                -- technically both `{}` and `nil` are valid
                rhs_comma_tokens = {},
              }
              append_stat(fake_main, stat)
              append_empty(fake_main, next_token_node())
            end
          )

          -- the second lhs (and following) is/are parsed in a different part of the code
          add_stat_test(
            "assignment with 'foo, "..str.."' lhs",
            "foo, "..str.." = true;",
            function()
              local lhs = {get_ref_helper("foo", next_token()), nil}
              local lhs_comma_tokens = {next_token_node()}
              lhs[2] = get_invalid_lhs_node()
              local stat = nodes.new_assignment{
                lhs = lhs,
                lhs_comma_tokens = lhs_comma_tokens,
                eq_token = next_token_node(),
                rhs = {new_true_node(next_token())},
                -- technically both `{}` and `nil` are valid
                rhs_comma_tokens = {},
              }
              append_stat(fake_main, stat)
              append_empty(fake_main, next_token_node())
            end
          )
        end

        add_invalid_lhs_assignment_tests("(true)", function()
          return new_invalid(
            error_code_util.codes.unexpected_expression,
            peek_next_token(), -- at '('
            nil,
            {(function()
              local open_paren_token = next_token_node()
              local expr = new_true_node(next_token())
              expr.src_paren_wrappers = {
                  {
                  open_paren_token = open_paren_token,
                  close_paren_token = next_token_node(),
                },
              }
              expr.force_single_result = true
              return expr
            end)()} -- consuming '(true)'
          )
        end)

        add_invalid_lhs_assignment_tests("bar()", function()
          return new_invalid(
            error_code_util.codes.unexpected_expression,
            peek_next_token(), -- at the first '('
            nil,
            {nodes.new_call{
              ex = get_ref_helper("bar", next_token()),
              open_paren_token = next_token_node(),
              close_paren_token = next_token_node(),
            }} -- consuming 'bar()'
          )
        end)
      end -- end assignment
    end -- end expression statements

    -- funcstat, localfunc, call are only partially tested. The rest for them is in expressions
    -- ensuring that all expressions are evaluated in the right scope is also not tested here
    -- TODO: it's tested later on (or, well, will be)
  end -- end statements

  do -- expressions
    local expr_scope = main_scope:new_scope("expressions")
    current_testing_scope = expr_scope

    local fake_scope
    local function append_fake_scope(get_expr_node, parent_scope)
      parent_scope = parent_scope or fake_main
      fake_scope = nodes.new_repeatstat{
        parent_scope = parent_scope,
        repeat_token = next_token_node(),
        until_token = next_token_node(),
        condition = prevent_assert,
      }
      fake_scope.condition = get_expr_node()
      append_stat(parent_scope, fake_scope)
    end

    do -- local_ref
      add_stat_test(
        "local_ref",
        "local foo repeat until foo",
        function()
          local local_token = next_token_node()
          local foo_def, foo_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          fake_main.locals[1] = foo_def
          local localstat = nodes.new_localstat{
            local_token = local_token,
            lhs = {foo_ref},
            -- technically both `{}` and `nil` are valid
            lhs_comma_tokens = {},
            -- technically both `{}` and `nil` are valid
            rhs_comma_tokens = nil,
          }
          foo_def.start_at = localstat
          foo_def.start_offset = 1
          append_stat(fake_main, localstat)
          append_fake_scope(function()
            local expr = nodes.new_local_ref{
              name = "foo",
              position = next_token(),
              reference_def = foo_def,
            }
            foo_def.refs[#foo_def.refs+1] = expr
            return expr
          end)
        end
      )
    end -- end local_ref

    do -- upval_ref
      add_stat_test(
        "upval_ref",
        "local function foo() repeat until foo end",
        function()
          local local_token = next_token_node()
          local function_token = next_token_node()
          local foo_def, foo_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          fake_main.locals[1] = foo_def
          local localfunc = nodes.new_localfunc{
            local_token = local_token,
            name = foo_ref,
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
          foo_def.start_at = localfunc
          foo_def.start_offset = 0
          append_stat(fake_main, localfunc)
          local func_scope = localfunc.func_def
          fake_main.func_protos[#fake_main.func_protos+1] = func_scope
          append_fake_scope(function()
            local upval_def = {
              def_type = "upval",
              name = "foo",
              scope = func_scope,
              parent_def = foo_def,
              child_defs = {},
              refs = {},
            }
            foo_def.child_defs[#foo_def.child_defs+1] = upval_def
            func_scope.upvals[#func_scope.upvals+1] = upval_def
            local upval_ref = nodes.new_upval_ref{
              name = "foo",
              position = next_token(),
              reference_def = upval_def,
            }
            upval_def.refs[#upval_def.refs+1] = upval_ref
            return upval_ref
          end, func_scope)
          func_scope.end_token = next_token_node()
        end
      )
    end -- end upval_ref

    do -- index
      local function add_index_test(label, str, get_expr)
        add_stat_test(
          label,
          "repeat until "..str,
          function()
            append_fake_scope(function()
              local foo = get_ref_helper("foo", next_token(), fake_scope)
              local expr = get_expr(foo)
              return expr
            end)
          end
        )
      end

      add_index_test(
        "index with ident",
        "foo.bar",
        function(foo)
          local expr = nodes.new_index{
            ex = foo,
            dot_token = next_token_node(),
            suffix = nodes.new_string{
              position = next_token(),
              value = "bar",
              src_is_ident = true,
            },
          }
          return expr
        end
      )

      add_index_test(
        "index with '[]'",
        "foo[true]",
        function(foo)
          local expr = nodes.new_index{
            ex = foo,
            suffix_open_token = next_token_node(),
            suffix = new_true_node(next_token()),
            suffix_close_token = next_token_node(),
          }
          return expr
        end
      )

      add_index_test(
        "index without ident",
        "foo.",
        function(foo)
          local expr = nodes.new_index{
            ex = foo,
            dot_token = next_token_node(),
            suffix = new_invalid(
              error_code_util.codes.expected_ident,
              peek_next_token() -- at 'eof'
            ),
          }
          return expr
        end
      )

      add_index_test(
        "index with '[]' except without ']'",
        "foo[true",
        function(foo)
          local suffix_open_token = next_token_node()
          local expr = nodes.new_index{
            ex = foo,
            suffix_open_token = suffix_open_token,
            suffix = new_true_node(next_token()),
            suffix_close_token = new_invalid(
              error_code_util.codes.expected_closing_match,
              peek_next_token(), -- at 'eof'
              {"]", "[", suffix_open_token.line..":"..suffix_open_token.column}
            ),
          }
          return expr
        end
      )
    end -- end index

    local all_binops = {
      "^",
      "*",
      "/",
      "%",
      "+",
      "-",
      "==",
      "<",
      "<=",
      "~=",
      ">",
      ">=",
      "and",
      "or",
      "..",
    }

    do -- unop
      local unop_scope = expr_scope:new_scope("unop")
      current_testing_scope = unop_scope

      local function add_unop_tests(unop_str)
        add_stat_test(
          "unop '"..unop_str.."'",
          "repeat until "..unop_str.." true",
          function()
            append_fake_scope(function()
              local expr = nodes.new_unop{
                op = unop_str,
                op_token = next_token_node(),
                ex = new_true_node(next_token()),
              }
              return expr
            end)
          end
        )

        add_stat_test(
          "unop double '"..unop_str.."'",
          "repeat until "..unop_str.." "..unop_str.." true",
          function()
            append_fake_scope(function()
              local expr = nodes.new_unop{
                op = unop_str,
                op_token = next_token_node(),
                ex = nodes.new_unop{
                  op = unop_str,
                  op_token = next_token_node(),
                  ex = new_true_node(next_token()),
                },
              }
              return expr
            end)
          end
        )

        for _, binop in ipairs(all_binops) do
          local make_binop
          if binop == ".." then
            function make_binop(left)
              return nodes.new_concat{
                op_tokens = {next_token_node()},
                exp_list = {left, new_true_node(next_token())},
              }
            end
          else
            function make_binop(left)
              return nodes.new_binop{
                left = left,
                op = binop,
                op_token = next_token_node(),
                right = new_true_node(next_token()),
              }
            end
          end

          if binop == "^" then
            add_stat_test(
              "unop '"..unop_str.."' does not take precedence over binop '"..binop.."'",
              "repeat until "..unop_str.." true "..binop.." true",
              function()
                append_fake_scope(function()
                  local expr = nodes.new_unop{
                    op = unop_str,
                    op_token = next_token_node(),
                    ex = make_binop(new_true_node(next_token())),
                  }
                  return expr
                end)
              end
            )
          else
            add_stat_test(
              "unop '"..unop_str.."' takes precedence over binop '"..binop.."'",
              "repeat until "..unop_str.." true "..binop.." true",
              function()
                append_fake_scope(function()
                  local expr = make_binop(nodes.new_unop{
                    op = unop_str,
                    op_token = next_token_node(),
                    ex = new_true_node(next_token()),
                  })
                  return expr
                end)
              end
            )
          end
        end
      end

      add_unop_tests("not")
      add_unop_tests("-")
      add_unop_tests("#")

      current_testing_scope = expr_scope
    end -- end unop
  end -- end expressions
end
