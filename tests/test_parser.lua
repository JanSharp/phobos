
local framework = require("test_framework")
local assert = require("assert")

local tokenize = require("tokenize")
local nodes = require("nodes")
local parser = require("parser")
local ill = require("indexed_linked_list")
local ast = require("ast_util")

local fake_stat_elem = assert.do_not_compare_flag

local fake_env_scope = nodes.new_env_scope{}
-- Lua emits _ENV as if it's a local in the parent scope
-- of the file. I'll probably change this one day to be
-- the first upval of the parent scope, since load()
-- clobbers the first upval anyway to be the new _ENV value
local def = ast.create_local_def("_ENV", fake_env_scope)
def.whole_block = true
fake_env_scope.locals[1] = def

local fake_main = ast.append_stat(fake_env_scope, function(stat_elem)
  local main = nodes.new_functiondef{
    stat_elem = stat_elem,
    is_main = true,
    source = "=(test)",
    parent_scope = fake_env_scope,
    is_vararg = true,
  }
  main.eof_token = nodes.new_token({token_type = "eof", leading = {}})
  return main
end)

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

---@param position Token
---@param tokens? AstTokenNode[]
local function new_invalid(position, tokens)
  local invalid = nodes.new_invalid{
    error_message = assert.do_not_compare_flag,
    position = position,
    tokens = tokens or {},
  }
  expected_invalid_nodes[#expected_invalid_nodes+1] = invalid
  return invalid
end

local function before_each()
  ill.clear(fake_main.body)
  expected_invalid_nodes = {}
end

local function test_stat(str)
  local main, got_invalid_nodes = parser(str, "=(test)")
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

    do
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
        "if true",
          function()
          local testblock = nodes.new_testblock{
            parent_scope = fake_main,
            if_token = next_token_node(),
            condition = new_true_node(next_token()),
            then_token = new_invalid(peek_next_token()),
          }
          local stat = nodes.new_ifstat{
            ifs = {testblock},
          }
          append_stat(fake_main, stat)
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
              then_token = new_invalid(peek_next_token()),
            }
            local stat = nodes.new_ifstat{
              ifs = {testblock},
            }
            append_stat(fake_main, stat)
            append_stat(fake_main, new_invalid(peek_next_token()))
            append_stat(fake_main, new_invalid(peek_next_token(), {next_token_node()}))
          end
        )
      end
      add_ifstat_without_else_but_with("else")
      add_ifstat_without_else_but_with("end")
    end

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

    do
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
    end
  end

  -- TODO: ifstat without 'end'
  -- TODO: whilestat without 'do'
  -- TODO: whilestat without 'end'
  -- TODO: dostat without 'end'
  -- TODO: fornum with invalid ident
  -- TODO: fornum without '='
  -- TODO: fornum without first ','
  -- TODO: fornum without 'do'
  -- TODO: fornum without 'end'
end
