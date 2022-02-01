
local framework = require("test_framework")
local assert = require("assert")

local invert = require("invert")
local nodes = require("nodes")
local parser = require("parser")
local ill = require("indexed_linked_list")
local ast = require("ast_util")

local prevent_assert = nodes.new_invalid{
  error_message = "<not assigned for this test>",
}

local function new_token_node(token_type, line, column, leading, value)
  return nodes.new_token({
    token_type = token_type,
    line = line,
    column = column,
    leading = leading or {},
    value = value,
  })
end

---intermediate state of tokens do have leading. blank and comment don't, so default is `nil`
---@param leading? Token[]
local function new_token(token_type, line, column, value, leading)
  return {
    token_type = token_type,
    index = assert.do_not_compare_flag,
    line = line,
    column = column,
    value = value,
    leading = leading,
  }
end

local function new_token_node_with_blank_leading(token_type, line, column, value)
  return new_token_node(token_type, line, column, {
    new_token("blank", line, column - 1, " "),
  }, value)
end

local function new_position(line, column, leading)
  return {
    line = line,
    column = column,
    leading = leading or {},
  }
end

local function new_blank(line, column, value)
  return new_token("blank", line, column, value)
end

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
  main.eof_token = new_token_node("eof")
  return main
end)
local fake_body = fake_main.body
local fake_stat_elem = ill.append(fake_body, nil)
-- value set in test_stat

local function test_stat(str, expected_stat, expected_invalid_nodes)
  local main, invalid_nodes = parser(str, "=(test)")
  fake_stat_elem.value = expected_stat
  assert.contents_equals(fake_main, main, nil, {root_name = "main"})
  assert.contents_equals(expected_invalid_nodes or {}, invalid_nodes, nil, {root_name = "invalid_nodes"})
end

local function add_statements_to_scope(scope, statements)
  for _, stat in ipairs(statements) do
    ast.append_stat(scope, function(stat_elem)
      stat.stat_elem = stat_elem
      return stat
    end)
  end
  return scope
end

local function add_empty_to_scope(line, column, leading, scope)
  return add_statements_to_scope(scope, {nodes.new_empty{
    stat_elem = prevent_assert,
    semi_colon_token = new_token_node(";", line, column, leading),
  }})
end

local function new_dummy_true_expr(line, column)
  return nodes.new_boolean{
    stat_elem = fake_stat_elem,
    position = new_position(line, column, {new_blank(line, column - 1, " ")}),
    value = true,
  }
end

do
  local main_scope = framework.scope:new_scope("parser")

  do
    local stat_scope = main_scope:new_scope("statements")

    stat_scope:register_test("empty", function()
      test_stat(";", nodes.new_empty{
        stat_elem = fake_stat_elem,
        semi_colon_token = new_token_node(";", 1, 1),
      })
    end)

    stat_scope:register_test("ifstat with 1 testblock", function()
      test_stat("if true then;end", nodes.new_ifstat{
        stat_elem = fake_stat_elem,
        ifs = {
          add_empty_to_scope(1, 13, nil, nodes.new_testblock{
            stat_elem = fake_stat_elem,
            parent_scope = fake_main,
            if_token = new_token_node("if", 1, 1),
            condition = new_dummy_true_expr(1, 4),
            then_token = new_token_node_with_blank_leading("then", 1, 9),
          }),
        },
        end_token = new_token_node("end", 1, 14),
      })
    end)

    stat_scope:register_test("ifstat with 2 testblocks", function()
      test_stat("if true then;elseif true then;end", nodes.new_ifstat{
        stat_elem = fake_stat_elem,
        ifs = {
          add_empty_to_scope(1, 13, nil, nodes.new_testblock{
            stat_elem = fake_stat_elem,
            parent_scope = fake_main,
            if_token = new_token_node("if", 1, 1),
            condition = new_dummy_true_expr(1, 4),
            then_token = new_token_node_with_blank_leading("then", 1, 9),
          }),
          add_empty_to_scope(1, 30, nil, nodes.new_testblock{
            stat_elem = fake_stat_elem,
            parent_scope = fake_main,
            if_token = new_token_node("elseif", 1, 14),
            condition = new_dummy_true_expr(1, 21),
            then_token = new_token_node_with_blank_leading("then", 1, 26),
          }),
        },
        end_token = new_token_node("end", 1, 31),
      })
    end)

    stat_scope:register_test("ifstat with elseblock", function()
      test_stat("if true then;else;end", nodes.new_ifstat{
        stat_elem = fake_stat_elem,
        ifs = {
          add_empty_to_scope(1, 13, nil, nodes.new_testblock{
            stat_elem = fake_stat_elem,
            parent_scope = fake_main,
            if_token = new_token_node("if", 1, 1),
            condition = new_dummy_true_expr(1, 4),
            then_token = new_token_node_with_blank_leading("then", 1, 9),
          }),
        },
        elseblock = add_empty_to_scope(1, 18, nil, nodes.new_elseblock{
          stat_elem = fake_stat_elem,
          parent_scope = fake_main,
          else_token = new_token_node("else", 1, 14),
        }),
        end_token = new_token_node("end", 1, 19),
      })
    end)

    stat_scope:register_test("whilestat", function()
      test_stat("while true do;end", add_empty_to_scope(1, 14, nil, nodes.new_whilestat{
        stat_elem = fake_stat_elem,
        parent_scope = fake_main,
        while_token = new_token_node("while", 1, 1),
        condition = new_dummy_true_expr(1, 7),
        do_token = new_token_node_with_blank_leading("do", 1, 12),
        end_token = new_token_node("end", 1, 15),
      }))
    end)

    stat_scope:register_test("dostat", function()
      test_stat("do;end", add_empty_to_scope(1, 3, nil, nodes.new_dostat{
        stat_elem = fake_stat_elem,
        do_token = new_token_node("do", 1, 1),
        end_token = new_token_node("end", 1, 4),
        parent_scope = fake_main,
      }))
    end)

    stat_scope:register_test("fornum without step", function()
      local var_def, var_ref = ast.create_local(
        new_token("ident", 1, 5, "i", {new_blank(1, 4, " ")}), fake_main, fake_stat_elem
      )
      var_def.whole_block = true
      test_stat("for i = true, true do;end", add_empty_to_scope(1, 22, nil, nodes.new_fornum{
        stat_elem = fake_stat_elem,
        parent_scope = fake_main,
        for_token = new_token_node("for", 1, 1),
        var = var_ref,
        locals = {var_def},
        eq_token = new_token_node_with_blank_leading("=", 1, 7),
        start = new_dummy_true_expr(1, 9),
        first_comma_token = new_token_node(",", 1, 13),
        stop = new_dummy_true_expr(1, 15),
        do_token = new_token_node_with_blank_leading("do", 1, 20),
        end_token = new_token_node("end", 1, 23),
      }))
    end)

    stat_scope:register_test("fornum with step", function()
      local var_def, var_ref = ast.create_local(
        new_token("ident", 1, 5, "i", {new_blank(1, 4, " ")}), fake_main, fake_stat_elem
      )
      var_def.whole_block = true
      test_stat("for i = true, true, true do;end", add_empty_to_scope(1, 28, nil, nodes.new_fornum{
        stat_elem = fake_stat_elem,
        parent_scope = fake_main,
        for_token = new_token_node("for", 1, 1),
        var = var_ref,
        locals = {var_def},
        eq_token = new_token_node_with_blank_leading("=", 1, 7),
        start = new_dummy_true_expr(1, 9),
        first_comma_token = new_token_node(",", 1, 13),
        stop = new_dummy_true_expr(1, 15),
        second_comma_token = new_token_node(",", 1, 19),
        step = new_dummy_true_expr(1, 21),
        do_token = new_token_node_with_blank_leading("do", 1, 26),
        end_token = new_token_node("end", 1, 29),
      }))
    end)
  end

  -- TODO: ifstat without 'then'
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
