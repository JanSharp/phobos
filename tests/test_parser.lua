
local framework = require("test_framework")
local assert = require("assert")

local tokenize = require("tokenize")
local nodes = require("nodes")
local parser = require("parser")
local ast = require("ast_util")
local error_code_util = require("error_code_util")

local tutil = require("testing_util")
local append_stat = tutil.append_stat
local test_source = tutil.test_source

local prevent_assert = nodes.new_invalid{
  error_code_inst = error_code_util.new_error_code{
    error_code = error_code_util.codes.incomplete_node,
    source = test_source,
    position = {line = 0, column = 0},
  }
}
local fake_main
local fake_stat_elem = assert.do_not_compare_flag

nodes = tutil.wrap_nodes_constructors(nodes, fake_stat_elem)

local empty_table_or_nil = assert.custom_comparator({[{}] = true}, true)

local function make_fake_main()
  fake_main = ast.new_main(test_source)
  fake_main.eof_token = nodes.new_token({token_type = "eof", leading = {}})
end

local function get_tokens(str)
  local leading = {}
  local tokens = {}
  for _, token in tokenize(str, test_source) do
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

---@param semi_colon_token_node AstTokenNode
local function append_empty(scope, semi_colon_token_node)
  append_stat(scope, nodes.new_empty{
    semi_colon_token = semi_colon_token_node,
  })
end

local expected_parser_errors

local function new_invalid(error_code, position, message_args, consumed_nodes, error_code_inst)
  if error_code_inst then
    error_code_inst.location_str = assert.do_not_compare_flag
  end
  local invalid = nodes.new_invalid{
    error_code_inst = error_code_inst or error_code_util.new_error_code{
      error_code = error_code,
      message_args = message_args,
      source = test_source,
      position = position,
      location_str = assert.do_not_compare_flag, -- TODO: test the syntax_error location string logic
    },
    consumed_nodes = consumed_nodes or {},
  }
  expected_parser_errors[#expected_parser_errors+1] = invalid.error_code_inst
  return invalid
end

local function get_ref_helper(name, position, scope)
  return ast.get_ref(scope or fake_main, fake_stat_elem, name, position)
end

local function before_each()
  make_fake_main()
  expected_parser_errors = {}
end

local function test_stat(str)
  assert.assert(fake_main, "must run make_fake_main before each test")
  local main, got_parser_errors = parser(str, test_source)
  assert.contents_equals(
    fake_main,
    main,
    nil,
    {
      root_name = "main",
      serpent_opts = tutil.serpent_opts_for_ast,
    }
  )
  assert.contents_equals(
    expected_parser_errors or {},
    got_parser_errors,
    nil,
    {
      root_name = "invalid_nodes",
      serpent_opts = tutil.serpent_opts_for_ast,
    }
  )
  fake_main = nil
end

do
  local main_scope = framework.scope:new_scope("parser")

  local current_testing_scope = main_scope
  local tokens
  local next_token
  local peek_next_token
  local function add_test(name, str, func)
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

  local function next_true_node()
    return nodes.new_boolean{
      position = next_token(),
      value = true,
    }
  end

  local function next_wrapped_true_node()
    local open_paren_token = next_token_node()
    local node = next_true_node()
    node.src_paren_wrappers = {
      {
        open_paren_token = open_paren_token,
        close_paren_token = next_token_node(),
      },
    }
    node.force_single_result = true
    return node
  end

  local function add_test_with_localfunc(name, str, func)
    add_test(
      name,
      "local function foo() "..str.." end",
      function()
        local local_token = next_token_node()
        local function_token = next_token_node()
        local foo_def, foo_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
        fake_main.locals[1] = foo_def
        local localfunc = nodes.new_localfunc{
          local_token = local_token,
          name = foo_ref,
          func_def = nodes.new_functiondef{
            source = test_source,
            parent_scope = fake_main,
            function_token = function_token,
            open_paren_token = next_token_node(),
            close_paren_token = next_token_node(),
            param_comma_tokens = empty_table_or_nil,
          },
        }
        foo_def.start_at = localfunc
        foo_def.start_offset = 0
        local func_scope = localfunc.func_def
        fake_main.func_protos[1] = func_scope
        append_stat(fake_main, localfunc)
        func(func_scope)
        func_scope.end_token = next_token_node()
      end
    )
  end

  local function append_dummy_local(scope)
    scope = scope or fake_main
    local local_token = next_token_node()
    local foo_def, foo_ref = ast.create_local(next_token(), scope, fake_stat_elem)
    scope.locals[1] = foo_def
    local localstat = nodes.new_localstat{
      local_token = local_token,
      lhs = {foo_ref},
      lhs_comma_tokens = empty_table_or_nil,
      rhs_comma_tokens = empty_table_or_nil,
    }
    foo_def.start_at = localstat
    foo_def.start_offset = 1
    append_stat(scope, localstat)
  end

  do
    local stat_scope = main_scope:new_scope("statements")
    current_testing_scope = stat_scope

    add_test(
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
          condition = next_true_node(),
          then_token = next_token_node(),
        }
        append_empty(testblock, next_token_node())
        return testblock
      end

      add_test(
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

      add_test(
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

      add_test(
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

      add_test(
        "ifstat without 'then'",
        "if true ;",
          function()
          local testblock = nodes.new_testblock{
            parent_scope = fake_main,
            if_token = next_token_node(),
            condition = next_true_node(),
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
        add_test(
          "ifstat without 'then' but with '"..last_keyword.."'",
          "if true "..last_keyword,
          function()
            local testblock = nodes.new_testblock{
              parent_scope = fake_main,
              if_token = next_token_node(),
              condition = next_true_node(),
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

      add_test(
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
      add_test(
        "whilestat",
        "while true do ; end",
        function()
          local stat = nodes.new_whilestat{
            parent_scope = fake_main,
            while_token = next_token_node(),
            condition = next_true_node(),
            do_token = next_token_node(),
          }
          append_empty(stat, next_token_node())
          stat.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      add_test(
        "whilestat without do",
        "while true ;",
        function()
          local stat = nodes.new_whilestat{
            parent_scope = fake_main,
            while_token = next_token_node(),
            condition = next_true_node(),
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

      add_test(
        "while without 'end'",
        "while true do ;",
        function()
          local stat = nodes.new_whilestat{
            parent_scope = fake_main,
            while_token = next_token_node(),
            condition = next_true_node(),
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
      add_test(
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

      add_test(
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
      add_test(
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

      add_test(
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
          start = next_true_node(),
          first_comma_token = next_token_node(),
          stop = next_true_node(),
        }
        if has_step then
          stat.second_comma_token = next_token_node()
          stat.step = next_true_node()
        end
        stat.do_token = next_token_node()
        append_empty(stat, next_token_node())
        stat.end_token = next_token_node()
        append_stat(fake_main, stat)
      end

      add_test(
        "fornum without step",
        "for i = true, true do ; end",
        function()
          add_fornum_stat(false)
        end
      )

      add_test(
        "fornum with step",
        "for i = true, true, true do ; end",
        function()
          add_fornum_stat(true)
        end
      )

      add_test(
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
            start = next_true_node(),
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

      add_test(
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
            start = next_true_node(),
            first_comma_token = next_token_node(),
            stop = next_true_node(),
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

      add_test(
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
            start = next_true_node(),
            first_comma_token = next_token_node(),
            stop = next_true_node(),
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
      add_test(
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
            exp_list = {next_true_node()},
            exp_list_comma_tokens = empty_table_or_nil,
            do_token = next_token_node(),
          }
          append_empty(stat, next_token_node())
          stat.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      local function add_forlist_with_x_names_test(name_count, names_str)
        add_test(
          "forlist with "..name_count.." names",
          "for "..names_str.." in true do ; end",
          function()
            local stat = nodes.new_forlist{
              parent_scope = fake_main,
              for_token = next_token_node(),
              comma_tokens = {},
              exp_list = {prevent_assert},
              exp_list_comma_tokens = empty_table_or_nil,
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
            stat.exp_list[1] = next_true_node()
            stat.do_token = next_token_node()
            append_empty(stat, next_token_node())
            stat.end_token = next_token_node()
            append_stat(fake_main, stat)
          end
        )
      end
      add_forlist_with_x_names_test(2, "foo, bar")
      add_forlist_with_x_names_test(3, "foo, bar, baz")

      add_test(
        "forlist with invalid name list",
        "for foo, ;",
        function()
          local stat = nodes.new_forlist{
            parent_scope = fake_main,
            for_token = next_token_node(),
            comma_tokens = {},
            exp_list = {prevent_assert},
            exp_list_comma_tokens = empty_table_or_nil,
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

      add_test(
        "forlist with invalid name list, but continuing with 'in'",
        "for foo, in true do ; end",
        function()
          local stat = nodes.new_forlist{
            parent_scope = fake_main,
            for_token = next_token_node(),
            comma_tokens = {},
            exp_list = {prevent_assert},
            exp_list_comma_tokens = empty_table_or_nil,
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
          stat.exp_list[1] = next_true_node()
          stat.do_token = next_token_node()
          append_empty(stat, next_token_node())
          stat.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      add_test(
        "forlist without 'do'",
        "for foo in true ;",
        function()
          local stat = nodes.new_forlist{
            parent_scope = fake_main,
            for_token = next_token_node(),
            comma_tokens = {},
            exp_list = {prevent_assert},
            exp_list_comma_tokens = empty_table_or_nil,
          }
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          name_def.whole_block = true
          stat.name_list[1] = name_ref
          stat.locals[1] = name_def
          stat.in_token = next_token_node()
          stat.exp_list[1] = next_true_node()
          stat.do_token = new_invalid(
            error_code_util.codes.expected_token,
            peek_next_token(), -- at ';'
            {"do"}
          )
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_test(
        "forlist without 'end'",
        "for foo in true do ;",
        function()
          local stat = nodes.new_forlist{
            parent_scope = fake_main,
            for_token = next_token_node(),
            comma_tokens = {},
            exp_list = {prevent_assert},
            exp_list_comma_tokens = empty_table_or_nil,
          }
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          name_def.whole_block = true
          stat.name_list[1] = name_ref
          stat.locals[1] = name_def
          stat.in_token = next_token_node()
          stat.exp_list[1] = next_true_node()
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
      add_test(
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
          stat.condition = next_true_node()
          append_stat(fake_main, stat)
        end
      )

      add_test(
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

      add_test(
        "repeatstat condition scoping",
        "local foo repeat ; ; local foo until foo",
        function()
          append_dummy_local()
          local stat = nodes.new_repeatstat{
            parent_scope = fake_main,
            repeat_token = next_token_node(),
            condition = prevent_assert,
          }
          -- TODO: this test is failing, see description below to get some idea as to why
          -- the fix for it is disgusting (I can think of either adding a void statement
          -- just to get a stat_elem with an appropriate index in the correct scope,
          -- or making stat_elem optional when resolving the reference... however that
          -- means making stat_elem optional for every expression and then having to
          -- handle that everywhere else that is using `stat_elem`s
          -- fun fact, this will be fixed with the removal of `stat_elem`s, (at least from the parser)
          -- because we then have easy full control of what is visible at what point for
          -- resolving references

          -- need the empty stat such that the stat_elem index of the inner local
          -- is the same as the stat_elem index of the repeatstat
          -- this tests to make sure the correct index is used when resolving the reference,
          -- since if it uses the wrong one it doesn't find the inner local, because it thinks
          -- that one starts too late
          append_empty(stat, next_token_node())
          -- add a second one just for good measure. with just one we are relying on
          -- start_offset working, which this test is not about
          append_empty(stat, next_token_node())
          append_dummy_local(stat)
          stat.until_token = next_token_node()
          stat.condition = nodes.new_local_ref{
            name = "foo",
            position = next_token(),
            reference_def = stat.locals[1],
          }
          local refs = stat.locals[1].refs
          refs[#refs+1] = stat.condition
          append_stat(fake_main, stat)
        end
      )
    end -- end repeatstat

    do -- funcstat
      add_test(
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
              param_comma_tokens = empty_table_or_nil,
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

      add_test(
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
              param_comma_tokens = empty_table_or_nil,
            },
          }
          fake_main.func_protos[1] = stat.func_def
          append_empty(stat.func_def, next_token_node())
          stat.func_def.end_token = next_token_node()
          append_stat(fake_main, stat)
        end
      )

      add_test(
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
              param_comma_tokens = empty_table_or_nil,
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

      add_test(
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

      add_test(
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
              param_comma_tokens = empty_table_or_nil,
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
        add_test(
          "localstat with "..name_count.." name"..(name_count == 1 and "" or "s"),
          "local "..names_str..";",
          function()
            local local_token = next_token_node()
            local lhs = {}
            -- both `{}` and `nil` are valid (if name_count == 1)
            local lhs_comma_tokens = empty_table_or_nil
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

      add_test(
        "localstat with rhs",
        "local foo = true, true;",
        function()
          local local_token = next_token_node()
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          fake_main.locals[1] = name_def
          local stat = nodes.new_localstat{
            local_token = local_token,
            lhs = {name_ref},
            lhs_comma_tokens = empty_table_or_nil,
            eq_token = next_token_node(),
            rhs = {next_true_node()},
            rhs_comma_tokens = {next_token_node()},
          }
          name_def.start_at = stat
          name_def.start_offset = 1
          stat.rhs[2] = next_true_node()
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_test(
        "localstat without ident",
        "local ;",
        function()
          local stat = nodes.new_localstat{
            local_token = next_token_node(),
            lhs = {new_invalid(
              error_code_util.codes.expected_ident,
              peek_next_token() -- at ';'
            )},
            lhs_comma_tokens = empty_table_or_nil,
            -- no rhs, this should be nil
            rhs_comma_tokens = nil,
          }
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_test(
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
            rhs = {next_true_node()},
            rhs_comma_tokens = empty_table_or_nil,
          }
          foo_def.start_at = stat
          foo_def.start_offset = 1
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_test(
        "localstat expression scoping",
        "local foo local foo = foo",
        function()
          append_dummy_local()
          local local_token = next_token_node()
          local name_def, name_ref = ast.create_local(next_token(), fake_main, fake_stat_elem)
          fake_main.locals[2] = name_def
          local stat = nodes.new_localstat{
            local_token = local_token,
            lhs = {name_ref},
            lhs_comma_tokens = empty_table_or_nil,
            eq_token = next_token_node(),
            rhs = {nodes.new_local_ref{
              name = "foo",
              position = next_token(),
              reference_def = fake_main.locals[1],
            }},
            rhs_comma_tokens = empty_table_or_nil,
          }
          local refs = fake_main.locals[1].refs
          refs[#refs+1] = stat.rhs[1]
          name_def.start_at = stat
          name_def.start_offset = 1
          append_stat(fake_main, stat)
        end
      )
    end -- end localstat

    do -- localfunc
      add_test_with_localfunc(
        "localfunc",
        ";",
        function(scope)
          append_empty(scope, next_token_node())
        end
      )

      add_test(
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
              param_comma_tokens = empty_table_or_nil,
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
        add_test(
          label,
          "::foo:: "..(extra_str or "").." ;",
          function()
            local stat = nodes.new_label{
              open_token = next_token_node(),
              name = peek_next_token().value,
              name_token = next_token_node(),
              close_token = next_token_node(),
            }
            fake_main.labels[stat.name] = stat
            append_stat(fake_main, stat)
            if extra_code then extra_code() end
            append_empty(fake_main, next_token_node())
          end
        )
      end

      add_label_test("label")

      add_test(
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

      add_test(
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
      add_test(
        "retstat without results",
        "return",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            exp_list_comma_tokens = empty_table_or_nil,
          }
          append_stat(fake_main, stat)
        end
      )

      add_test(
        "retstat with 1 result",
        "return true",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            exp_list = {next_true_node()},
            exp_list_comma_tokens = empty_table_or_nil,
          }
          append_stat(fake_main, stat)
        end
      )

      add_test(
        "retstat with 2 results",
        "return true, true",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            exp_list = {next_true_node(), nil},
            exp_list_comma_tokens = {next_token_node()},
          }
          stat.exp_list[2] = next_true_node()
          append_stat(fake_main, stat)
        end
      )

      add_test(
        "retstat without results with ';'",
        "return;",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            exp_list_comma_tokens = empty_table_or_nil,
            semi_colon_token = next_token_node(),
          }
          append_stat(fake_main, stat)
        end
      )

      add_test(
        "retstat with 1 result and with ';'",
        "return true;",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            exp_list = {next_true_node()},
            exp_list_comma_tokens = empty_table_or_nil,
            semi_colon_token = next_token_node(),
          }
          append_stat(fake_main, stat)
        end
      )

      add_test(
        "retstat ends the current block",
        "return; ;",
        function()
          local stat = nodes.new_retstat{
            return_token = next_token_node(),
            exp_list_comma_tokens = empty_table_or_nil,
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
      add_test(
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
      add_test(
        "gotostat",
        "goto foo;",
        function()
          local stat = nodes.new_gotostat{
            goto_token = next_token_node(),
            target_name = "foo",
            target_token = next_token_node(),
          }
          append_stat(fake_main, stat)
          append_empty(fake_main, next_token_node())
        end
      )

      add_test(
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
        add_test(
          "call statement",
          "foo();",
          function()
            local stat = nodes.new_call{
              ex = get_ref_helper("foo", next_token()),
              open_paren_token = next_token_node(),
              close_paren_token = next_token_node(),
              args_comma_tokens = empty_table_or_nil,
            }
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )
      end -- end call

      do -- assignment
        add_test(
          "assignment with 1 lhs, 1 rhs",
          "foo = true;",
          function()
            local stat = nodes.new_assignment{
              lhs = {get_ref_helper("foo", next_token())},
              lhs_comma_tokens = empty_table_or_nil,
              eq_token = next_token_node(),
              rhs = {next_true_node()},
              rhs_comma_tokens = empty_table_or_nil,
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

        add_test(
          "assignment with 2 lhs, 1 rhs",
          "foo, bar = true;",
          function()
            local lhs, lhs_comma_tokens = get_foo_bar_lhs()
            local stat = nodes.new_assignment{
              lhs = lhs,
              lhs_comma_tokens = lhs_comma_tokens,
              eq_token = next_token_node(),
              rhs = {next_true_node()},
              rhs_comma_tokens = empty_table_or_nil,
            }
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )

        add_test(
          "assignment with 1 lhs, 2 rhs",
          "foo = true, true;",
          function()
            local stat = nodes.new_assignment{
              lhs = {get_ref_helper("foo", next_token())},
              lhs_comma_tokens = empty_table_or_nil,
              eq_token = next_token_node(),
              rhs = {next_true_node(), nil},
              rhs_comma_tokens = {next_token_node()},
            }
            stat.rhs[2] = next_true_node()
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )

        add_test(
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
              rhs_comma_tokens = empty_table_or_nil,
            }
            append_stat(fake_main, stat)
            append_empty(fake_main, next_token_node())
          end
        )

        local function add_invalid_lhs_assignment_tests(label, str_label, str, get_invalid_lhs_node)
          add_test(
            "assignment with '"..(str_label or str).."' lhs"..label,
            str.." = true;",
            function()
              local stat = nodes.new_assignment{
                lhs = {get_invalid_lhs_node()},
                lhs_comma_tokens = empty_table_or_nil,
                eq_token = next_token_node(),
                rhs = {next_true_node()},
                rhs_comma_tokens = empty_table_or_nil,
              }
              append_stat(fake_main, stat)
              append_empty(fake_main, next_token_node())
            end
          )

          -- the second lhs (and following) is/are parsed in a different part of the code
          add_test(
            "assignment with 'foo, "..(str_label or str).."' lhs"..label,
            "foo, "..str.." = true;",
            function()
              local lhs = {get_ref_helper("foo", next_token()), nil}
              local lhs_comma_tokens = {next_token_node()}
              lhs[2] = get_invalid_lhs_node()
              local stat = nodes.new_assignment{
                lhs = lhs,
                lhs_comma_tokens = lhs_comma_tokens,
                eq_token = next_token_node(),
                rhs = {next_true_node()},
                rhs_comma_tokens = empty_table_or_nil,
              }
              append_stat(fake_main, stat)
              append_empty(fake_main, next_token_node())
            end
          )
        end

        add_invalid_lhs_assignment_tests("", nil, "(true)", function()
          return new_invalid(
            error_code_util.codes.unexpected_expression,
            peek_next_token(), -- at '('
            nil,
            {(function()
              local open_paren_token = next_token_node()
              local expr = next_true_node()
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

        add_invalid_lhs_assignment_tests("", nil, "bar()", function()
          return new_invalid(
            error_code_util.codes.unexpected_expression,
            peek_next_token(), -- at 'bar'
            nil,
            {nodes.new_call{
              ex = get_ref_helper("bar", next_token()),
              open_paren_token = next_token_node(),
              args_comma_tokens = empty_table_or_nil,
              close_paren_token = next_token_node(),
            }} -- consuming 'bar()'
          )
        end)

        add_invalid_lhs_assignment_tests(
          " (invalid node order with invalid lhs which also contains a syntax error)",
          "foo(\\1)",
          "foo(\1)",
          function()
            local unexpected_token
            local invalid = new_invalid(
              error_code_util.codes.unexpected_expression,
              peek_next_token(), -- at 'foo'
              nil,
              {nodes.new_call{
                ex = get_ref_helper("foo", next_token()),
                open_paren_token = next_token_node(),
                args_comma_tokens = empty_table_or_nil,
                close_paren_token = (function()
                  unexpected_token = next_token_node()
                  return next_token_node()
                end)(),
              }} -- consuming 'foo('
            )
            -- have to do this afterwards such that the unexpected expression
            -- is the first in the invalid nodes list
            -- since it cones first in the file
            invalid.consumed_nodes[1].args[1] = new_invalid(
              nil,
              unexpected_token, -- at '\1'
              nil,
              {unexpected_token},
              unexpected_token.error_code_insts[1]
            )
            return invalid
          end
        )
      end -- end assignment

      add_test(
        "expression statements pass along invalid nodes",
        "then",
        function()
          append_stat(fake_main, new_invalid(
            error_code_util.codes.unexpected_token,
            peek_next_token(), -- at 'then'
            nil,
            {next_token_node()} -- consuming 'then'
          ))
        end
      )

      add_test(
        "unexpected expression",
        "foo", -- has be a suffixed expression
        function()
          local stat = new_invalid(
            error_code_util.codes.unexpected_expression,
            peek_next_token(), -- at 'foo'
            nil,
            {get_ref_helper("foo", next_token(), fake_main)} -- consuming 'foo'
          )
          append_stat(fake_main, stat)
        end
      )

      add_test(
        "unexpected expression invalid node order with an expression which also has a syntax error",
        "foo.true", -- has be a suffixed expression
        function()
          local stat = new_invalid(
            error_code_util.codes.unexpected_expression,
            peek_next_token(), -- at 'foo'
            nil,
            {nodes.new_index{
              ex = get_ref_helper("foo", next_token(), fake_main),
              dot_token = next_token_node(),
              suffix = prevent_assert,
            }} -- consuming 'foo.'
          )
          -- add this invalid node to the invalid nodes array after the unexpected_expression
          stat.consumed_nodes[1].suffix = new_invalid(
            error_code_util.codes.expected_ident,
            peek_next_token() -- at 'true'
          )
          append_stat(fake_main, stat)
          append_stat(fake_main, new_invalid(
            error_code_util.codes.unexpected_token,
            peek_next_token(), -- at 'true'
            nil,
            {next_token_node()} -- consuming 'true'
          ))
        end
      )
    end -- end expression statements

    -- funcstat, localfunc, call are only partially tested. The rest for them is in expressions
    -- ensuring that all expressions are evaluated in the right scope is also not tested here
    -- it's tested later on

    current_testing_scope = main_scope
  end -- end statements

  do -- expressions
    local expr_scope = main_scope:new_scope("expressions")
    current_testing_scope = expr_scope

    local function append_repeatstat(get_expr_node, parent_scope)
      parent_scope = parent_scope or fake_main
      local scope = nodes.new_repeatstat{
        parent_scope = parent_scope,
        repeat_token = next_token_node(),
        until_token = next_token_node(),
        condition = prevent_assert,
      }
      scope.condition = get_expr_node(scope)
      append_stat(parent_scope, scope)
    end

    local function add_test_with_repeatstat(name, str, func)
      add_test(
        name,
        "repeat until "..str,
        function()
          append_repeatstat(function(scope)
            return func(scope)
          end)
        end
      )
    end

    do -- local_ref
      add_test(
        "local_ref",
        "local foo repeat until foo",
        function()
          append_dummy_local()
          local foo_def = fake_main.locals[1]
          append_repeatstat(function()
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
      add_test_with_localfunc(
        "upval_ref",
        "repeat until foo",
        function(func_scope)
          local foo_def = fake_main.locals[1] -- defined by add_test_with_func
          append_repeatstat(function()
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
        end
      )
    end -- end upval_ref

    do -- index
      local function add_index_test(label, str, get_expr)
        add_test_with_repeatstat(
          label,
          str,
          function(scope)
            local foo = get_ref_helper("foo", next_token(), scope)
            local expr = get_expr(foo)
            return expr
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
            suffix = next_true_node(),
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
            suffix = next_true_node(),
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

    local function make_binop(binop, left, get_right)
      if binop == ".." then
        return nodes.new_concat{
          op_tokens = {next_token_node()},
          exp_list = {left, get_right()},
        }
      else
        return nodes.new_binop{
          left = left,
          op = binop,
          op_token = next_token_node(),
          right = get_right(),
        }
      end
    end

    do -- unop
      local unop_scope = expr_scope:new_scope("unop")
      current_testing_scope = unop_scope

      local function add_unop_tests(unop_str)
        add_test_with_repeatstat(
          "unop '"..unop_str.."'",
          unop_str.." true",
          function()
            local expr = nodes.new_unop{
              op = unop_str,
              op_token = next_token_node(),
              ex = next_true_node(),
            }
            return expr
          end
        )

        add_test_with_repeatstat(
          "unop double '"..unop_str.."'",
          unop_str.." "..unop_str.." true",
          function()
            local expr = nodes.new_unop{
              op = unop_str,
              op_token = next_token_node(),
              ex = nodes.new_unop{
                op = unop_str,
                op_token = next_token_node(),
                ex = next_true_node(),
              },
            }
            return expr
          end
        )

        for _, binop in ipairs(all_binops) do
          if binop == "^" then
            add_test_with_repeatstat(
              "unop '"..unop_str.."' does not take precedence over binop '"..binop.."'",
              unop_str.." true "..binop.." true",
              function()
                local expr = nodes.new_unop{
                  op = unop_str,
                  op_token = next_token_node(),
                  ex = make_binop(
                    binop,
                    next_true_node(),
                    function() return next_true_node() end
                  ),
                }
                return expr
              end
            )
          else
            add_test_with_repeatstat(
              "unop '"..unop_str.."' takes precedence over binop '"..binop.."'",
              unop_str.." true "..binop.." true",
              function()
                local expr = make_binop(
                  binop,
                  nodes.new_unop{
                    op = unop_str,
                    op_token = next_token_node(),
                    ex = next_true_node(),
                  },
                  function() return next_true_node() end
                )
                return expr
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

    do -- binop
      local binop_scope = expr_scope:new_scope("binop")
      current_testing_scope = binop_scope

      for _, binop in ipairs(all_binops) do
        add_test_with_repeatstat(
          "binop '"..binop.."'",
          "true "..binop.." true",
          function()
            local expr = make_binop(
              binop,
              next_true_node(),
              function() return next_true_node() end
            )
            return expr
          end
        )
      end

      -- copy paste from the parser itself
      local binop_prio = {
        ["^"]   = {left=10,right=9}, -- right associative
        ["*"]   = {left=7 ,right=7}, ["/"]  = {left=7,right=7},
        ["%"]   = {left=7 ,right=7},
        ["+"]   = {left=6 ,right=6}, ["-"]  = {left=6,right=6},
        [".."]  = {left=5 ,right=4}, -- right associative
        ["=="]  = {left=3 ,right=3},
        ["<"]   = {left=3 ,right=3}, ["<="] = {left=3,right=3},
        ["~="]  = {left=3 ,right=3},
        [">"]   = {left=3 ,right=3}, [">="] = {left=3,right=3},
        ["and"] = {left=2 ,right=2},
        ["or"]  = {left=1 ,right=1},
      }

      local function add_binop_test(first, second)
        if first == ".." and second == ".." then
          return -- concat gets combined into a single node
        end
        local middle_is_prioritized_by_the_right = (binop_prio[second].left > binop_prio[first].right)
        local label = middle_is_prioritized_by_the_right
          and "(foo "..first.." (bar "..second.." baz))"
          or "((foo "..first.." bar) "..second.." baz)"
        add_test_with_repeatstat(
          "binops '"..label.."' (test without '()')",
          "true "..first.." true "..second.." true",
          function()
            local expr
            local function make_inner_binop(binop)
              return make_binop(
                binop,
                next_true_node(),
                function() return next_true_node() end
              )
            end
            if middle_is_prioritized_by_the_right then
              -- the second op is the inner node
              expr = make_binop(
                first,
                next_true_node(),
                function() return make_inner_binop(second) end
              )
            else
              -- the first op is the inner node
              expr = make_binop(
                second,
                make_inner_binop(first),
                function() return next_true_node() end
              )
            end
            return expr
          end
        )
      end

      for _, first in ipairs(all_binops) do
        for _, second in ipairs(all_binops) do
          add_binop_test(first, second)
        end
      end

      current_testing_scope = expr_scope
    end -- end binop

    do -- concat
      -- note that standalone concats and concat precedence was already tested in the binop scope
      -- however a concat chain and parenthesis are tested here

      add_test_with_repeatstat(
        "concat chain of 2 concats",
        "true..true..true",
        function()
          local expr = nodes.new_concat{
            exp_list = {next_true_node(), nil, nil},
            op_tokens = {next_token_node(), nil},
            concat_src_paren_wrappers = assert.custom_comparator({
              [{}] = true,
              [{{}}] = true,
            }, true),
          }
          expr.exp_list[2] = next_true_node()
          expr.op_tokens[2] = next_token_node()
          expr.exp_list[3] = next_true_node()
          return expr
        end
      )

      add_test_with_repeatstat(
        "concat with pointless '()'",
        "(((true)..(((true)..(true)))))",
        function()
          local open_1 = next_token_node()
          local open_2 = next_token_node()
          local true_1 = next_wrapped_true_node()
          local op_1 = next_token_node()
          local open_3 = next_token_node()
          local open_4 = next_token_node()
          local true_2 = next_wrapped_true_node()
          local op_2 = next_token_node()
          local true_3 = next_wrapped_true_node()
          local close_4 = next_token_node()
          local close_3 = next_token_node()
          local close_2 = next_token_node()
          local close_1 = next_token_node()
          local expr = nodes.new_concat{
            exp_list = {true_1, true_2, true_3},
            op_tokens = {op_1, op_2},
            force_single_result = true,
            concat_src_paren_wrappers = {
              {
                {
                  open_paren_token = open_2,
                  close_paren_token = close_2,
                },
                {
                  open_paren_token = open_1,
                  close_paren_token = close_1,
                },
              },
              {
                {
                  open_paren_token = open_4,
                  close_paren_token = close_4,
                },
                {
                  open_paren_token = open_3,
                  close_paren_token = close_3,
                },
              },
            }
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "concat with the left concat in '()'",
        "(true..true)..true",
        function()
          local open = next_token_node()
          local true_1 = next_true_node()
          local op_1 = next_token_node()
          local true_2 = next_true_node()
          local close = next_token_node()
          local op_2 = next_token_node()
          local true_3 = next_true_node()
          local expr = nodes.new_concat{
            exp_list = {
              nodes.new_concat{
                exp_list = {true_1, true_2},
                op_tokens = {op_1},
                force_single_result = true,
                concat_src_paren_wrappers = {
                  {
                    {
                      open_paren_token = open,
                      close_paren_token = close,
                    },
                  },
                },
              },
              true_3
            },
            op_tokens = {op_2},
            concat_src_paren_wrappers = assert.custom_comparator({
              [{}] = true,
              [{{}}] = true,
            }, true),
          }
          return expr
        end
      )
    end -- end concat

    do -- number
      add_test_with_repeatstat(
        "number",
        "1",
        function()
          local expr = nodes.new_number{
            position = next_token(),
            value = 1,
            src_value = "1",
          }
          return expr
        end
      )
    end -- end number

    do -- string
      add_test_with_repeatstat(
        "string (regular)",
        "'hello world'",
        function()
          local expr = nodes.new_string{
            position = next_token(),
            value = "hello world",
            src_quote = [[']],
            src_value = "hello world",
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "string (block)",
        "[=[hello world]=]",
        function()
          local expr = nodes.new_string{
            position = next_token(),
            value = "hello world",
            src_is_block_str = true,
            src_has_leading_newline = false,
            src_pad = "=",
          }
          return expr
        end
      )
    end -- end string

    do -- nil
      add_test_with_repeatstat(
        "nil",
        "nil",
        function()
          local expr = nodes.new_nil{
            position = next_token(),
          }
          return expr
        end
      )
    end -- end nil

    do -- boolean
      add_test_with_repeatstat(
        "true",
        "true",
        function()
          local expr = next_true_node()
          return expr
        end
      )

      add_test_with_repeatstat(
        "false",
        "false",
        function()
          local expr = nodes.new_boolean{
            position = next_token(),
            value = false,
          }
          return expr
        end
      )
    end -- end boolean

    do -- nil
      add_test_with_repeatstat(
        "vararg in vararg function",
        "...",
        function()
          local expr = nodes.new_vararg{
            position = next_token(),
          }
          return expr
        end
      )

      add_test_with_localfunc(
        "vararg outside vararg function",
        "repeat until ...",
        function(scope)
          append_repeatstat(function()
            local expr = new_invalid(
              error_code_util.codes.vararg_outside_vararg_func,
              peek_next_token(), -- at '...'
              nil,
              {next_token_node()} -- consuming '...'
            )
            return expr
          end, scope)
        end
      )
    end -- end nil

    do -- func_proto/functiondef
      local function add_func_proto_test(label, params_str, set_params)
        add_test_with_repeatstat(
          label,
          "function("..params_str..") ; end",
          function(scope)
            local expr = nodes.new_func_proto{
              func_def = nodes.new_functiondef{
                parent_scope = scope,
                source = test_source,
                function_token = next_token_node(),
                open_paren_token = next_token_node(),
                -- default here, must be overwritten with a new table if comma tokens are expected
                param_comma_tokens = empty_table_or_nil,
              },
            }
            fake_main.func_protos[1] = expr.func_def
            set_params(expr.func_def)
            expr.func_def.close_paren_token = next_token_node()
            append_empty(expr.func_def, next_token_node())
            expr.func_def.end_token = next_token_node()
            return expr
          end
        )
      end

      local function add_func_proto_test_with_x_params(params_str, num_params)
        add_func_proto_test(
          "func_proto with "..num_params.." param"..(num_params == 1 and "" or "s"),
          params_str,
          function(scope)
            if num_params > 1 then
              scope.param_comma_tokens = {}
            end
            for i = 1, num_params do
              scope.locals[i], scope.params[i] = ast.create_local(next_token(), scope, fake_stat_elem)
              scope.locals[i].whole_block = true
              if i ~= num_params then
                scope.param_comma_tokens[i] = next_token_node()
              end
            end
          end
        )
      end

      add_func_proto_test_with_x_params("", 0)
      add_func_proto_test_with_x_params("foo", 1)
      add_func_proto_test_with_x_params("foo, bar", 2)
      add_func_proto_test_with_x_params("foo, bar, baz", 3)

      add_func_proto_test(
        "func_proto with vararg param",
        "...",
        function(scope)
          scope.is_vararg = true
          scope.vararg_token = next_token_node()
        end
      )

      add_func_proto_test(
        "func_proto with 1 param and vararg param",
        "foo, ...",
        function(scope)
          scope.locals[1], scope.params[1] = ast.create_local(next_token(), scope, fake_stat_elem)
          scope.locals[1].whole_block = true
          scope.param_comma_tokens = {next_token_node()}
          scope.is_vararg = true
          scope.vararg_token = next_token_node()
        end
      )

      add_test_with_repeatstat(
        "func_proto without 'end'",
        "function() ;",
        function(scope)
          local function_token = next_token_node()
          local expr = nodes.new_func_proto{
            func_def = nodes.new_functiondef{
              parent_scope = scope,
              source = test_source,
              function_token = function_token,
              open_paren_token = next_token_node(),
              param_comma_tokens = empty_table_or_nil,
              close_paren_token = next_token_node(),
            },
          }
          fake_main.func_protos[1] = expr.func_def
          append_empty(expr.func_def, next_token_node())
          expr.func_def.end_token = new_invalid(
            error_code_util.codes.expected_closing_match,
            peek_next_token(), -- at 'eof'
            {"end", "function", function_token.line..":"..function_token.column}
          )
          return expr
        end
      )

      add_test(
        "func_proto without ')'",
        "repeat until function(... ;",
        function()
          append_repeatstat(function(scope)
            local function_token = next_token_node()
            local expr = nodes.new_func_proto{
              func_def = nodes.new_functiondef{
                parent_scope = scope,
                source = test_source,
                function_token = function_token,
                open_paren_token = next_token_node(),
                param_comma_tokens = empty_table_or_nil,
                -- has to be vararg for this test, because that's the only early return
                -- in par_list that doesn't already test the next token
                is_vararg = true,
                vararg_token = next_token_node(),
                close_paren_token = new_invalid(
                  error_code_util.codes.expected_token,
                  peek_next_token(), -- at ';'
                  {")"}
                ),
              },
            }
            fake_main.func_protos[1] = expr.func_def
            return expr
          end)
          append_empty(fake_main, next_token_node())
        end
      )

      add_test(
        "func_proto without params",
        "repeat until function( ;",
        function()
          append_repeatstat(function(scope)
            local function_token = next_token_node()
            local expr = nodes.new_func_proto{
              func_def = nodes.new_functiondef{
                parent_scope = scope,
                source = test_source,
                function_token = function_token,
                open_paren_token = next_token_node(),
                params = {new_invalid(
                  error_code_util.codes.expected_ident_or_vararg,
                  peek_next_token() -- at ';'
                )},
                param_comma_tokens = empty_table_or_nil,
              },
            }
            fake_main.func_protos[1] = expr.func_def
            return expr
          end)
          append_empty(fake_main, next_token_node())
        end
      )

      add_test(
        "func_proto without '('",
        "repeat until function ;",
        function()
          append_repeatstat(function(scope)
            local function_token = next_token_node()
            local expr = nodes.new_func_proto{
              func_def = nodes.new_functiondef{
                parent_scope = scope,
                source = test_source,
                function_token = function_token,
                open_paren_token = new_invalid(
                  error_code_util.codes.expected_token,
                  peek_next_token(), -- at ';'
                  {"("}
                ),
                param_comma_tokens = empty_table_or_nil,
              },
            }
            fake_main.func_protos[1] = expr.func_def
            return expr
          end)
          append_empty(fake_main, next_token_node())
        end
      )
    end -- end func_proto/functiondef

    do -- constructor
      add_test_with_repeatstat(
        "constructor empty",
        "{}",
        function()
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            comma_tokens = empty_table_or_nil,
            close_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor with 1 list field",
        "{true}",
        function()
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            fields = {
              {type = "list", value = next_true_node()},
            },
            comma_tokens = empty_table_or_nil,
            close_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor with 1 list field starting with an ident",
        "{foo}",
        function(scope)
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            fields = {
              {type = "list", value = get_ref_helper("foo", next_token(), scope)},
            },
            comma_tokens = empty_table_or_nil,
            close_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor with 1 record field using '[]'",
        "{[true] = true}",
        function()
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            fields = {
              {
                type = "rec",
                key_open_token = next_token_node(),
                key = next_true_node(),
                key_close_token = next_token_node(),
                eq_token = next_token_node(),
                value = next_true_node(),
              },
            },
            comma_tokens = empty_table_or_nil,
            close_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor with 1 record field using ident",
        "{foo = true}",
        function()
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            fields = {
              {
                type = "rec",
                key = nodes.new_string{
                  value = "foo",
                  position = next_token(),
                  src_is_ident = true,
                },
                eq_token = next_token_node(),
                value = next_true_node(),
              },
            },
            comma_tokens = empty_table_or_nil,
            close_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor with 2 fields",
        "{true, true}",
        function()
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            fields = {
              {type = "list", value = next_true_node()},
              nil,
            },
            comma_tokens = {next_token_node()},
          }
          expr.fields[2] = {type = "list", value = next_true_node()}
          expr.close_token = next_token_node()
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor with trailing comma",
        "{true,}",
        function()
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            fields = {
              {type = "list", value = next_true_node()},
            },
            comma_tokens = {next_token_node()},
            close_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor with 2 fields using ';' and a trailing ';'",
        "{true; true;}",
        function()
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            fields = {
              {type = "list", value = next_true_node()},
              nil,
            },
            comma_tokens = {next_token_node()},
          }
          expr.fields[2] = {type = "list", value = next_true_node()}
          expr.comma_tokens[2] = next_token_node()
          expr.close_token = next_token_node()
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor with record field using '[]' without '='",
        "{[true]}",
        function()
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            fields = {
              {
                type = "rec",
                key_open_token = next_token_node(),
                key = next_true_node(),
                key_close_token = next_token_node(),
                eq_token = new_invalid(
                  error_code_util.codes.expected_token,
                  peek_next_token(), -- at '}'
                  {"="}
                ),
                value = prevent_assert,
              },
            },
            comma_tokens = empty_table_or_nil,
            close_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor with a standalone ','",
        "{,}",
        function()
          local expr = nodes.new_constructor{
            open_token = next_token_node(),
            fields = {
              {
                type = "list",
                value = new_invalid(
                  error_code_util.codes.unexpected_token,
                  peek_next_token(), -- at ','
                  nil,
                  {next_token_node()} -- consuming ','
                )
              },
            },
            comma_tokens = empty_table_or_nil,
            close_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "constructor without '}'",
        "{",
        function()
          local open_token = next_token_node()
          local expr = nodes.new_constructor{
            open_token = open_token,
            fields = {
              {
                type = "list",
                value = new_invalid(
                  error_code_util.codes.unexpected_token,
                  peek_next_token() -- at ','
                  -- not consuming 'eof'
                )
              },
            },
            comma_tokens = empty_table_or_nil,
            close_token = new_invalid(
              error_code_util.codes.expected_closing_match,
              peek_next_token(), -- at 'eof'
              {"}", "{", open_token.line..":"..open_token.column}
            ),
          }
          return expr
        end
      )
    end -- end constructor

    do -- call
      add_test_with_repeatstat(
        "call with '()'",
        "(true)()",
        function()
          local expr = nodes.new_call{
            ex = next_wrapped_true_node(),
            open_paren_token = next_token_node(),
            args_comma_tokens = empty_table_or_nil,
            close_paren_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "call with '()' with 1 arg",
        "(true)(true)",
        function()
          local expr = nodes.new_call{
            ex = next_wrapped_true_node(),
            open_paren_token = next_token_node(),
            args = {next_true_node()},
            args_comma_tokens = empty_table_or_nil,
            close_paren_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "call with '()' with 2 args",
        "(true)(true, true)",
        function()
          local expr = nodes.new_call{
            ex = next_wrapped_true_node(),
            open_paren_token = next_token_node(),
            args = {next_true_node(), nil},
            args_comma_tokens = {next_token_node()},
          }
          expr.args[2] = next_true_node()
          expr.close_paren_token = next_token_node()
          return expr
        end
      )

      add_test_with_repeatstat(
        "call with a regular string",
        [[(true) "Hello World!"]],
        function()
          local expr = nodes.new_call{
            ex = next_wrapped_true_node(),
            args_comma_tokens = empty_table_or_nil,
            args = {nodes.new_string{
              position = next_token(),
              value = "Hello World!",
              src_value = "Hello World!",
              src_quote = [["]],
            }},
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "call with a block string",
        "(true) [=[Hello World!]=]",
        function()
          local expr = nodes.new_call{
            ex = next_wrapped_true_node(),
            args_comma_tokens = empty_table_or_nil,
            args = {nodes.new_string{
              position = next_token(),
              value = "Hello World!",
              src_is_block_str = true,
              src_has_leading_newline = false,
              src_pad = "=",
            }},
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "call with a constructor",
        "(true){}",
        function()
          local expr = nodes.new_call{
            ex = next_wrapped_true_node(),
            args_comma_tokens = empty_table_or_nil,
            args = {nodes.new_constructor{
              open_token = next_token_node(),
              comma_tokens = empty_table_or_nil,
              close_token = next_token_node(),
            }},
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "call with self and '()'",
        "(true):foo()",
        function()
          local expr = nodes.new_call{
            ex = next_wrapped_true_node(),
            is_selfcall = true,
            colon_token = next_token_node(),
            suffix = nodes.new_string{
              position = next_token(),
              value = "foo",
              src_is_ident = true,
            },
            open_paren_token = next_token_node(),
            args_comma_tokens = empty_table_or_nil,
            close_paren_token = next_token_node(),
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "call with self without func args",
        "(true):foo",
        function()
          local expr = nodes.new_call{
            ex = next_wrapped_true_node(),
            is_selfcall = true,
            colon_token = next_token_node(),
            suffix = nodes.new_string{
              position = next_token(),
              value = "foo",
              src_is_ident = true,
            },
            args = {new_invalid(
              error_code_util.codes.expected_func_args,
              peek_next_token() -- at 'eof'
            )},
            args_comma_tokens = empty_table_or_nil,
          }
          return expr
        end
      )

      add_test_with_repeatstat(
        "call with self without ident",
        "(true):",
        function()
          local expr = nodes.new_call{
            ex = next_wrapped_true_node(),
            is_selfcall = true,
            colon_token = next_token_node(),
            suffix = new_invalid(
              error_code_util.codes.expected_ident,
              peek_next_token() -- at 'eof'
            ),
            args_comma_tokens = empty_table_or_nil,
          }
          return expr
        end
      )

      local function add_call_with_self_without_ident_but_continuing_test(str, func)
        add_test_with_repeatstat(
          "call with self without ident but continuing with '"..str.."'",
          "(true):"..str,
          function()
            local expr = nodes.new_call{
              ex = next_wrapped_true_node(),
              is_selfcall = true,
              colon_token = next_token_node(),
              suffix = new_invalid(
                error_code_util.codes.expected_ident,
                peek_next_token()
              ),
              args_comma_tokens = empty_table_or_nil,
            }
            func(expr)
            return expr
          end
        )
      end
      add_call_with_self_without_ident_but_continuing_test("()", function(expr)
        expr.open_paren_token = next_token_node()
        expr.close_paren_token = next_token_node()
      end)
      add_call_with_self_without_ident_but_continuing_test([[""]], function(expr)
        expr.args = {nodes.new_string{
          position = next_token(),
          value = "",
          src_value = "",
          src_quote = [["]],
        }}
      end)
      add_call_with_self_without_ident_but_continuing_test("{}", function(expr)
        expr.args = {nodes.new_constructor{
          open_token = next_token_node(),
          comma_tokens = empty_table_or_nil,
          close_token = next_token_node(),
        }}
      end)

      add_test_with_repeatstat(
        "call with '(' but without ')'",
        "(true)(true",
        function()
          local ex = next_wrapped_true_node()
          local open_paren_token = next_token_node()
          local expr = nodes.new_call{
            ex = ex,
            open_paren_token = open_paren_token,
            args = {next_true_node()},
            args_comma_tokens = empty_table_or_nil,
            close_paren_token = new_invalid(
              error_code_util.codes.expected_closing_match,
              peek_next_token(), -- at 'eof'
              {")", "(", open_paren_token.line..":"..open_paren_token.column}
            ),
          }
          return expr
        end
      )
    end -- end call

    do -- expression list
      local function add_expression_list_test(str, count)
        add_test_with_repeatstat(
          "expression list with "..count.." expression"..(count == 1 and "" or "s").." (tested with call)",
          "(true)("..str..")",
          function()
            local expr = nodes.new_call{
              ex = next_wrapped_true_node(),
              open_paren_token = next_token_node(),
              args_comma_tokens = count <= 1 and empty_table_or_nil or {},
            }
            for i = 1, count do
              expr.args[i] = next_true_node()
              if i ~= count then
                expr.args_comma_tokens[i] = next_token_node()
              end
            end
            expr.close_paren_token = next_token_node()
            return expr
          end
        )
      end
      add_expression_list_test("true", 1)
      add_expression_list_test("true, true", 2)
      add_expression_list_test("true, true, true", 3)
      add_expression_list_test("true, true, true, true", 4)
    end -- end expression list

    current_testing_scope = main_scope
  end -- end expressions

  add_test(
    "invalid token generates syntax error",
    "\1",
    function()
      local token_node = next_token_node()
      local stat = new_invalid(
        nil,
        token_node, -- at '\1'
        nil,
        {token_node}, -- consuming '\1'
        token_node.error_code_insts[1] -- reusing the already existing error_code_inst for correct references
      )
      append_stat(fake_main, stat)
    end
  )

  add_test(
    "invalid token generates syntax error",
    [["\x]],
    function()
      local token_node = next_token_node()
      -- "floating" invalid node, only in the invalid nodes array
      new_invalid(
        nil,
        token_node, -- at '"\x'
        nil,
        nil,
        token_node.error_code_insts[1] -- reusing the already existing error_code_inst for correct references
      )
      local stat = new_invalid(
        nil,
        token_node, -- at '"\x'
        nil,
        {token_node}, -- consuming '"\x'
        token_node.error_code_insts[2] -- reusing the already existing error_code_inst for correct references
      )
      append_stat(fake_main, stat)
    end
  )

  add_test(
    "blocks end early, expected eof",
    "end",
    function()
      append_stat(fake_main, new_invalid(
        error_code_util.codes.expected_token,
        peek_next_token(), -- at 'end'
        {"eof"}
      ))
      append_stat(fake_main, new_invalid(
        error_code_util.codes.unexpected_token,
        peek_next_token(), -- at 'end'
        nil,
        {next_token_node()} -- consuming 'end'
      ))
    end
  )

  -- TODO: test 'eof' with leading
  -- TODO: test 'return' ending the current block

  -- NOTE: scoping for ifstat (testblock), whilestat, fornum, forlist, repeatstat will be more important
  -- once local definition inside expressions will be a thing, however until then testing for it is difficult
  -- the only way I can think of is using mocking which I consider disgusting
end
