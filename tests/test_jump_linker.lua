
local framework = require("test_framework")
local assert = require("assert")

local nodes = require("nodes")
local ast = require("ast_util")
local jump_linker = require("jump_linker")

local tutil = require("testing_util")
local append_stat = tutil.append_stat
local fake_stat_elem = assert.do_not_compare_flag
nodes = tutil.wrap_nodes_constructors(nodes, fake_stat_elem)

do
  local main_scope = framework.scope:new_scope("jump_linker")
  local current_scope = main_scope

  local function add_test(label, make_ast)
    current_scope:add_test(label, function()
      local expected_main = ast.new_main(tutil.test_source)
      make_ast(expected_main, true)
      local got_main = ast.new_main(tutil.test_source)
      make_ast(got_main, false)
      jump_linker(got_main)
      assert.contents_equals(expected_main, got_main, nil, {
        root_name = "main",
        serpent_opts = tutil.serpent_opts_for_ast,
      })
    end)
  end

  do -- goto
    local function new_gotostat(target_name)
      return nodes.new_gotostat{target_name = target_name}
    end
    local function new_label(name)
      return nodes.new_label{name = name}
    end

    local function link(go, label)
      go.linked_label = label
      label.linked_gotos[#label.linked_gotos+1] = go
    end

    local goto_scope = main_scope:new_scope("goto")
    current_scope = goto_scope

    add_test("forwards jump", function(main, should_link)
      local go = append_stat(main, new_gotostat("foo"))
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("backwards jump", function(main, should_link)
      local label = append_stat(main, new_label("foo"))
      local go = append_stat(main, new_gotostat("foo"))
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

    add_test("2 backwards jumps linking to the same label", function(main, should_link)
      local label = append_stat(main, new_label("foo"))
      local go1 = append_stat(main, new_gotostat("foo"))
      local go2 = append_stat(main, new_gotostat("foo"))
      if should_link then
        link(go1, label)
        link(go2, label)
      end
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

    add_test("forwards jump to parent scope", function(main, should_link)
      local dostat = append_stat(main, nodes.new_dostat{})
      local go = append_stat(dostat, new_gotostat("foo"))
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("forwards jump to parent scope 2 levels up", function(main, should_link)
      local dostat1 = append_stat(main, nodes.new_dostat{})
      local dostat2 = append_stat(dostat1, nodes.new_dostat{})
      local go = append_stat(dostat2, new_gotostat("foo"))
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("backwards jump to parent scope", function(main, should_link)
      local label = append_stat(main, new_label("foo"))
      local dostat = append_stat(main, nodes.new_dostat{})
      local go = append_stat(dostat, new_gotostat("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("backwards jump to parent scope 2 levels up", function(main, should_link)
      local label = append_stat(main, new_label("foo"))
      local dostat1 = append_stat(main, nodes.new_dostat{})
      local dostat2 = append_stat(dostat1, nodes.new_dostat{})
      local go = append_stat(dostat2, new_gotostat("foo"))
      if should_link then
        link(go, label)
      end
    end)

    add_test("forwards jump to end of block", function(main, should_link)
      local go = append_stat(main, new_gotostat("foo"))
      local bar_def, bar_ref = ast.create_local({value = "bar"}, main, fake_stat_elem)
      main.locals[1] = bar_def
      local localstat = append_stat(main, nodes.new_localstat{lhs = {bar_ref}})
      bar_def.start_at = localstat
      bar_def.start_offset = 1
      local label = append_stat(main, new_label("foo"))
      if should_link then
        link(go, label)
      end
    end)

    current_scope = main_scope
  end -- end goto
end
