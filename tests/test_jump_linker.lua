
local framework = require("test_framework")
local assert = require("assert")

local nodes = require("nodes")
local ast = require("ast_util")
local jump_linker = require("jump_linker")
local error_code_util = require("error_code_util")

local tutil = require("testing_util")
local test_source = tutil.test_source
local append_stat = ast.append_stat
local prevent_assert = assert.do_not_compare_flag

do
  local main_scope = framework.scope:new_scope("jump_linker")
  local current_scope = main_scope

  local function add_test(label, make_ast, get_expected_errors)
    current_scope:add_test(label, function()
      local expected_main = ast.new_main(test_source)
      make_ast(expected_main, true)
      local got_main = ast.new_main(test_source)
      make_ast(got_main, false)
      local got_errors = jump_linker(got_main)
      assert.contents_equals(expected_main, got_main, nil, {
        root_name = "main",
        serpent_opts = tutil.serpent_opts_for_ast,
      })
      local expected_errors
      if get_expected_errors then
        expected_errors = get_expected_errors()
      else
        expected_errors = {}
      end
      assert.contents_equals(expected_errors, got_errors, nil, {root_name = "error_code_insts"})
    end)
  end

  local function get_position(position)
    return position.line..":"..position.column
  end

  local function for_each_loop_scope(func)
    func("whilestat", function(main)
      return append_stat(main, nodes.new_whilestat{
        parent_scope = main,
        condition = nodes.new_boolean{value = true},
      })
    end)
    func("fornum", function(main)
      local fornum = append_stat(main, nodes.new_fornum{
        parent_scope = main,
        var = prevent_assert,
        start = nodes.new_number{value = 1},
        stop = nodes.new_number{value = 1},
      })
      local var_def, var_ref = ast.create_local({value = "var"}, fornum)
      var_def.whole_block = true
      fornum.locals[1] = var_def
      fornum.var = var_ref
      return fornum
    end)
    func("forlist", function(main)
      local forlist = append_stat(main, nodes.new_forlist{
        parent_scope = main,
        exp_list = {nodes.new_nil{}},
      })
      local var_def, var_ref = ast.create_local({value = "var"}, forlist)
      var_def.whole_block = true
      forlist.locals[1] = var_def
      forlist.name_list[1] = var_ref
      return forlist
    end)
    func("repeatstat", function(main)
      return append_stat(main, nodes.new_repeatstat{
        parent_scope = main,
        condition = nodes.new_boolean{value = true},
      })
    end)
  end

  local function for_each_scope(func)
    func("functiondef", function(main)
      return main
    end)
    func("ifstat (first testblock)", function(main)
      local ifstat = append_stat(main, nodes.new_ifstat{
        ifs = {
          nodes.new_testblock{
            parent_scope = main,
            condition = nodes.new_boolean{value = true},
          },
        },
      })
      return ifstat.ifs[1]
    end)
    func("ifstat (second testblock)", function(main)
      local ifstat = append_stat(main, nodes.new_ifstat{
        ifs = {
          nodes.new_testblock{
            parent_scope = main,
            condition = nodes.new_boolean{value = true},
          },
          nodes.new_testblock{
            parent_scope = main,
            condition = nodes.new_boolean{value = true},
          },
        },
      })
      return ifstat.ifs[2]
    end)
    func("ifstat (elseblock)", function(main)
      local ifstat = append_stat(main, nodes.new_ifstat{
        elseblock = nodes.new_elseblock{parent_scope = main},
      })
      return ifstat.elseblock
    end)
    func("dostat", function(main)
      return append_stat(main, nodes.new_dostat{parent_scope = main})
    end)
    for_each_loop_scope(func)
  end

  do -- goto
    local goto_scope = main_scope:new_scope("goto")
    current_scope = goto_scope

    -- `leading` does not matter here
    local function new_gotostat(target_name, line)
      if line then
        return nodes.new_gotostat{
          target_name = target_name,
          goto_token = nodes.new_token{
            token_type = "goto",
            line = line,
            column = 1,
          },
          target_token = nodes.new_token{
            token_type = "ident",
            value = target_name,
            line = line,
            column = 6,
          },
        }
      else
        return nodes.new_gotostat{target_name = target_name}
      end
    end
    local function new_label(name, line)
      if line then
        return nodes.new_label{
          name = name,
          open_token = nodes.new_token{
            token_type = "::",
            line = line,
            column = 2,
          },
          name_token = nodes.new_token{
            token_type = "ident",
            value = name,
            line = line,
            column = 3,
          },
          close_token = nodes.new_token{
            token_type = "::",
            line = line,
            column = 3 + #name,
          },
        }
      else
        return nodes.new_label{name = name}
      end
    end

    local function link(go, label)
      go.linked_label = label
      label.linked_gotos[#label.linked_gotos+1] = go
    end

    for_each_scope(function(scope_label, append_scope)
      add_test("(forwards) jump in "..scope_label, function(main, should_link)
        local scope = append_scope(main)
        local go = append_stat(scope, new_gotostat("foo"))
        local label = append_stat(scope, new_label("foo"))
        if should_link then
          link(go, label)
        end
      end)
    end)

    add_test("(forwards) jump in inner function", function(main, should_link)
      local foo_def, foo_ref = ast.create_local({value = "foo"}, main)
      main.locals[1] = foo_def
      local localfunc = append_stat(main, nodes.new_localfunc{
        name = foo_ref,
        func_def = nodes.new_functiondef{
          parent_scope = main,
          source = test_source,
        },
      })
      foo_def.start_at = localfunc
      foo_def.start_offset = 0
      local scope = localfunc.func_def
      main.func_protos[1] = scope
      local go = append_stat(scope, new_gotostat("foo"))
      local label = append_stat(scope, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("2 forwards jumps linking to the same label", function(main, should_link)
      local go1 = append_stat(main, new_gotostat("foo"))
      local go2 = append_stat(main, new_gotostat("foo"))
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go1, label)
        link(go2, label)
      end
    end)

    add_test("forwards jump to parent scope", function(main, should_link)
      local dostat = append_stat(main, nodes.new_dostat{parent_scope = main})
      local go = append_stat(dostat, new_gotostat("foo"))
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("forwards jump to parent scope 2 levels up", function(main, should_link)
      local dostat1 = append_stat(main, nodes.new_dostat{parent_scope = main})
      local dostat2 = append_stat(dostat1, nodes.new_dostat{parent_scope = main})
      local go = append_stat(dostat2, new_gotostat("foo"))
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("forwards jump with local before goto", function(main, should_link)
      local bar_def, bar_ref = ast.create_local({value = "bar"}, main)
      main.locals[1] = bar_def
      local localstat = append_stat(main, nodes.new_localstat{lhs = {bar_ref}})
      bar_def.start_at = localstat
      bar_def.start_offset = 1
      local go = append_stat(main, new_gotostat("foo"))
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("forwards jump to end of block", function(main, should_link)
      local go = append_stat(main, new_gotostat("foo"))
      local bar_def, bar_ref = ast.create_local({value = "bar"}, main)
      main.locals[1] = bar_def
      local localstat = append_stat(main, nodes.new_localstat{lhs = {bar_ref}})
      bar_def.start_at = localstat
      bar_def.start_offset = 1
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("forwards jump to end of block with extra labels and empty stats", function(main, should_link)
      local go = append_stat(main, new_gotostat("foo"))
      local bar_def, bar_ref = ast.create_local({value = "bar"}, main)
      main.locals[1] = bar_def
      local localstat = append_stat(main, nodes.new_localstat{lhs = {bar_ref}})
      bar_def.start_at = localstat
      bar_def.start_offset = 1
      local label = append_stat(main, new_label("foo"))
      -- labels and empty stats should be ignored when checking if a label is at the end of a block
      append_stat(main, new_label("baz"))
      append_stat(main, new_label("bat"))
      append_stat(main, nodes.new_empty{})
      append_stat(main, nodes.new_empty{})
      if should_link then
        link(go, label)
      end
    end)

    -- needed because the result of is_end_of_block is cached, so this is testing caching
    add_test("2 forwards jumps to end of block", function(main, should_link)
      local go1 = append_stat(main, new_gotostat("foo"))
      local go2 = append_stat(main, new_gotostat("foo"))
      local bar_def, bar_ref = ast.create_local({value = "bar"}, main)
      main.locals[1] = bar_def
      local localstat = append_stat(main, nodes.new_localstat{lhs = {bar_ref}})
      bar_def.start_at = localstat
      bar_def.start_offset = 1
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go1, label)
        link(go2, label)
      end
    end)

    add_test("forwards jump with 2 labels with the same name links to inner label", function(main, should_link)
      local dostat = append_stat(main, nodes.new_dostat{parent_scope = main})
      local go = append_stat(dostat, new_gotostat("foo"))
      local label = append_stat(dostat, new_label("foo"))
      append_stat(main, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    for _, with_tokens in ipairs{true, false} do
      local go, label, bar_ref
      local function add_forwards_jump_into_scope_of_new_local_test(test_label, make_local)
        add_test(
          "invalid forwards jump into scope of new "..test_label
            ..(with_tokens and " with tokens" or "without tokens"),
          function(main, should_link)
            go = append_stat(main, new_gotostat("foo", with_tokens and 1 or nil))
            make_local(main)
            label = append_stat(main, new_label("foo", with_tokens and 3 or nil))
            append_stat(main, nodes.new_dostat{parent_scope = main}) -- to make ::foo:: not be at the end of the block
          end,
          function()
            return {
              error_code_util.new_error_code{
                error_code = error_code_util.codes.jump_to_label_in_scope_of_new_local,
                position = with_tokens and ast.get_main_position(go) or nil,
                location_str = with_tokens and (" at "..get_position(ast.get_main_position(go))) or " at 0:0",
                message_args = with_tokens
                  and {
                    "foo", get_position(ast.get_main_position(label)),
                    "bar", get_position(ast.get_main_position(bar_ref))
                  }
                  or {"foo", "0:0", "bar", "0:0"},
                source = test_source,
              },
            }
          end
        )
      end
      local local_token_node = nodes.new_token{
        token_type = "local",
        line = 2,
        column = 1,
      }
      local ident_token = with_tokens and {value = "bar", line = 2, column = 16} or {value = "bar"}
      add_forwards_jump_into_scope_of_new_local_test("localstat", function(main)
        local bar_def
        bar_def, bar_ref = ast.create_local(ident_token, main)
        main.locals[1] = bar_def
        local localstat = append_stat(main, nodes.new_localstat{
          local_token = with_tokens and local_token_node or nil,
          lhs = {bar_ref},
        })
        bar_def.start_at = localstat
        bar_def.start_offset = 1
      end)
      add_forwards_jump_into_scope_of_new_local_test("localfunc", function(main)
        local bar_def
        bar_def, bar_ref = ast.create_local(ident_token, main)
        main.locals[1] = bar_def
        local localstat = append_stat(main, nodes.new_localfunc{
          local_token = with_tokens and local_token_node or nil,
          name = bar_ref,
          func_def = nodes.new_functiondef{
            parent_scope = main,
            source = test_source,
            function_token = with_tokens and nodes.new_token{
              token_type = "function",
              line = 2,
              column = 7,
            } or nil,
            open_paren_token = with_tokens and nodes.new_token{
              token_type = "(",
              line = 2,
              column = 19,
            } or nil,
            close_paren_token = with_tokens and nodes.new_token{
              token_type = ")",
              line = 2,
              column = 20,
            } or nil,
            end_token = with_tokens and nodes.new_token{
              token_type = "end",
              line = 2,
              column = 22,
            } or nil,
          },
        })
        bar_def.start_at = localstat
        bar_def.start_offset = 0
      end)
    end

    local function jump_to_label_in_scope_of_new_local(goto_name, local_name)
      return error_code_util.new_error_code{
        error_code = error_code_util.codes.jump_to_label_in_scope_of_new_local,
        position = nil,
        location_str = " at 0:0",
        message_args = {goto_name, "0:0", local_name, "0:0"},
        source = test_source,
      }
    end

    add_test("invalid forwards jump into scope of new localstat with multiple lhs", function(main, should_link)
      append_stat(main, new_gotostat("foo"))
      local one_def, one_ref = ast.create_local({value = "one"}, main)
      local two_def, two_ref = ast.create_local({value = "two"}, main)
      main.locals[1] = one_def
      main.locals[2] = two_def
      local localstat = append_stat(main, nodes.new_localstat{lhs = {one_ref, two_ref}})
      one_def.start_at = localstat
      one_def.start_offset = 1
      two_def.start_at = localstat
      two_def.start_offset = 1
      append_stat(main, new_label("foo"))
      append_stat(main, nodes.new_dostat{parent_scope = main})
    end, function()
      return {
        jump_to_label_in_scope_of_new_local("foo", "two"),
      }
    end)

    -- needed because the result of is_end_of_block is cached, so this is testing caching
    add_test("2 invalid forwards jumps into scope of new localstat", function(main, should_link)
      append_stat(main, new_gotostat("foo"))
      append_stat(main, new_gotostat("foo"))
      local bar_def, bar_ref = ast.create_local({value = "bar"}, main)
      main.locals[1] = bar_def
      local localstat = append_stat(main, nodes.new_localstat{lhs = {bar_ref}})
      bar_def.start_at = localstat
      bar_def.start_offset = 1
      append_stat(main, new_label("foo"))
      append_stat(main, nodes.new_dostat{parent_scope = main})
    end, function()
      return {
        jump_to_label_in_scope_of_new_local("foo", "bar"),
        jump_to_label_in_scope_of_new_local("foo", "bar"),
      }
    end)

    add_test("invalid forwards jump to label at end of repeatstat into scope of new localstat", function(main, should_link)
      local repeatstat = append_stat(main, nodes.new_repeatstat{
        parent_scope = main,
        condition = nodes.new_boolean{value = true},
      })
      append_stat(repeatstat, new_gotostat("foo"))
      local bar_def, bar_ref = ast.create_local({value = "bar"}, repeatstat)
      repeatstat.locals[1] = bar_def
      local localstat = append_stat(repeatstat, nodes.new_localstat{lhs = {bar_ref}})
      bar_def.start_at = localstat
      bar_def.start_offset = 1
      append_stat(repeatstat, new_label("foo"))
    end, function()
      return {
        jump_to_label_in_scope_of_new_local("foo", "bar"),
      }
    end)

    -- needed because the result of is_end_of_block is cached, so this is testing caching
    add_test("2 invalid forwards jumps to label at end of repeatstat into scope of new localstat", function(main, should_link)
      local repeatstat = append_stat(main, nodes.new_repeatstat{
        parent_scope = main,
        condition = nodes.new_boolean{value = true},
      })
      append_stat(repeatstat, new_gotostat("foo"))
      append_stat(repeatstat, new_gotostat("foo"))
      local bar_def, bar_ref = ast.create_local({value = "bar"}, repeatstat)
      repeatstat.locals[1] = bar_def
      local localstat = append_stat(repeatstat, nodes.new_localstat{lhs = {bar_ref}})
      bar_def.start_at = localstat
      bar_def.start_offset = 1
      append_stat(repeatstat, new_label("foo"))
    end, function()
      return {
        jump_to_label_in_scope_of_new_local("foo", "bar"),
        jump_to_label_in_scope_of_new_local("foo", "bar"),
      }
    end)

    local function no_visible_label(name)
      return error_code_util.new_error_code{
        error_code = error_code_util.codes.no_visible_label,
        position = nil,
        location_str = " at 0:0",
        message_args = {name},
        source = test_source,
      }
    end

    for _, with_tokens in ipairs{true, false} do
      local go
      add_test("jump without label "..(with_tokens and "with tokens" or "without tokens"), function(main, should_link)
        go = append_stat(main, new_gotostat("foo", with_tokens and 1 or nil))
      end, function()
        return {
          error_code_util.new_error_code{
            error_code = error_code_util.codes.no_visible_label,
            position = with_tokens and ast.get_main_position(go) or nil,
            location_str = with_tokens
              and (" at "..get_position(ast.get_main_position(go)))
              or " at 0:0",
            message_args = {"foo"},
            source = test_source,
          },
        }
      end)
    end

    add_test("2 jumps without label", function(main, should_link)
      append_stat(main, new_gotostat("foo"))
      append_stat(main, new_gotostat("bar"))
    end, function()
      return {
        no_visible_label("foo"),
        no_visible_label("bar"),
      }
    end)

    add_test("invalid forwards jump with label in inner scope", function(main, should_link)
      append_stat(main, new_gotostat("foo"))
      local dostat = append_stat(main, nodes.new_dostat{parent_scope = main})
      append_stat(dostat, new_label("foo"))
    end, function()
      return {
        no_visible_label("foo"),
      }
    end)

    add_test("invalid forwards jump with label on same level with a step down in between", function(main, should_link)
      local dostat1 = append_stat(main, nodes.new_dostat{parent_scope = main})
      append_stat(dostat1, new_gotostat("foo"))
      local dostat2 = append_stat(main, nodes.new_dostat{parent_scope = main})
      append_stat(dostat2, new_label("foo"))
    end, function()
      return {
        no_visible_label("foo"),
      }
    end)

    add_test("backwards jump", function(main, should_link)
      local label = append_stat(main, new_label("foo"))
      local go = append_stat(main, new_gotostat("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("2 backwards jumps linking to the same label", function(main, should_link)
      local label = append_stat(main, new_label("foo"))
      local go1 = append_stat(main, new_gotostat("foo"))
      local go2 = append_stat(main, new_gotostat("foo"))
      if should_link then
        link(go1, label)
        link(go2, label)
      end
    end)

    add_test("backwards jump to parent scope", function(main, should_link)
      local label = append_stat(main, new_label("foo"))
      local dostat = append_stat(main, nodes.new_dostat{parent_scope = main})
      local go = append_stat(dostat, new_gotostat("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("backwards jump to parent scope 2 levels up", function(main, should_link)
      local label = append_stat(main, new_label("foo"))
      local dostat1 = append_stat(main, nodes.new_dostat{parent_scope = main})
      local dostat2 = append_stat(dostat1, nodes.new_dostat{parent_scope = main})
      local go = append_stat(dostat2, new_gotostat("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("backwards jump with 2 labels with the same name links to inner label", function(main, should_link)
      append_stat(main, new_label("foo"))
      local dostat = append_stat(main, nodes.new_dostat{parent_scope = main})
      local label = append_stat(dostat, new_label("foo"))
      local go = append_stat(dostat, new_gotostat("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("invalid backwards jump with label in inner scope", function(main, should_link)
      local dostat = append_stat(main, nodes.new_dostat{parent_scope = main})
      append_stat(dostat, new_label("foo"))
      append_stat(main, new_gotostat("foo"))
    end, function()
      return {
        no_visible_label("foo"),
      }
    end)

    add_test("invalid backwards jump with label on same level with a step down in between", function(main, should_link)
      local dostat1 = append_stat(main, nodes.new_dostat{parent_scope = main})
      append_stat(dostat1, new_label("foo"))
      local dostat2 = append_stat(main, nodes.new_dostat{parent_scope = main})
      append_stat(dostat2, new_gotostat("foo"))
    end, function()
      return {
        no_visible_label("foo"),
      }
    end)

    add_test("forwards and backwards jumps linking to the same label", function(main, should_link)
      local go1 = append_stat(main, new_gotostat("foo"))
      local go2 = append_stat(main, new_gotostat("foo"))
      local label = append_stat(main, new_label("foo"))
      local go3 = append_stat(main, new_gotostat("foo"))
      local go4 = append_stat(main, new_gotostat("foo"))
      if should_link then
        link(go1, label)
        link(go2, label)
        link(go3, label)
        link(go4, label)
      end
    end)

    current_scope = main_scope
  end -- end goto

  do -- break
    local break_scope = main_scope:new_scope("break")
    current_scope = break_scope

    local function link(breakstat, scope)
      breakstat.linked_loop = scope
      scope.linked_breaks[#scope.linked_breaks+1] = breakstat
    end

    for_each_loop_scope(function(scope_label, append_scope)
      add_test("break in "..scope_label, function(main, should_link)
        local scope = append_scope(main)
        local breakstat = append_stat(scope, nodes.new_breakstat{})
        if should_link then
          link(breakstat, scope)
        end
      end)
    end)

    add_test("break breaks out of the inner loop", function(main, should_link)
      local whilestat1 = append_stat(main, nodes.new_whilestat{
        parent_scope = main,
        condition = nodes.new_boolean{value = true},
      })
      local whilestat2 = append_stat(whilestat1, nodes.new_whilestat{
        parent_scope = main,
        condition = nodes.new_boolean{value = true},
      })
      local breakstat = append_stat(whilestat2, nodes.new_breakstat{})
      if should_link then
        link(breakstat, whilestat2)
      end
    end)

    for _, with_tokens in ipairs{true, false} do
      local breakstat
      add_test("break outside of loops "..(with_tokens and "with tokens" or "without tokens"), function(main, should_link)
        breakstat = append_stat(main, nodes.new_breakstat{
          break_token = with_tokens and nodes.new_token{
            token_type = "break",
            line = 1,
            column = 1,
          } or nil,
        })
      end, function()
        return {
          error_code_util.new_error_code{
            error_code = error_code_util.codes.break_outside_loop,
            position = with_tokens and ast.get_main_position(breakstat) or nil,
            location_str = with_tokens
              and (" at "..get_position(ast.get_main_position(breakstat)))
              or " at 0:0",
            source = test_source,
          }
        }
      end)
    end

    local function break_outside_loop()
      return error_code_util.new_error_code{
        error_code = error_code_util.codes.break_outside_loop,
        position = nil,
        location_str = " at 0:0",
        source = test_source,
      }
    end

    add_test("2 breaks outside of loops", function(main, should_link)
      append_stat(main, nodes.new_breakstat{})
      append_stat(main, nodes.new_breakstat{})
    end, function()
      return {
        break_outside_loop(),
        break_outside_loop(),
      }
    end)

    break_scope = current_scope
  end -- end break
end
