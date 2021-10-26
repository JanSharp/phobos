
-- for factorio only

-- TODO: use locale for all messages, though it's pretty low priority

-- i could ask for a way to set the "ran command" flag, but it's really not that important

local parser = require("parser")
local jump_linker = require("jump_linker")
local fold_const = require("optimize.fold_const")
local fold_control_statements = require("optimize.fold_control_statements")
local compiler = require("compiler")
local dump = require("dump")

---cSpell:ignore lualib
local util = require("__core__.lualib.util")

-- it can cache the this env in a file level local because if anyone creates globals
-- in commands and then reuses them later they run into the same issues they would if
-- they were using regular commands. (so it's "fine" as long as nobody joined the game
-- since the globals were created. maybe.)
-- it remains a "just don't do that"
-- and i'm creating a copy to make it harder for someone to accidentally break Phobos
-- by making modifications to globals. it's still relatively easy to escape that sandbox
-- if someone is actively trying to do it
-- technically this is more work than even regular commands do (you literally get
-- the env of `level` i believe) but i like it better this way
local command_env

local function phobos_command(args, silent, measured)
  if not args.parameter then
    return
  end
  local player
  if args.player_index then
    player = game.get_player(args.player_index)
  end

  local function print_msg(msg, use_color)
    if player and player.valid then
      if use_color then
        player.print(msg, player.color)
      else
        player.print(msg)
      end
    else
      game.print(msg)
    end
  end

  if player and not player.admin then
    print_msg("Non admins cannot run commands.", true)
    return
  end

  if not silent then
    print_msg((player and (player.name.." ") or "")
      .."(Phobos command): "..args.parameter,
      true
    )
  end

  if not command_env then
    command_env = util.copy(_ENV)
  end

  local profiler = measured and game.create_profiler() or nil
  local success, ast = pcall(parser, args.parameter, args.parameter)
  if not success then
    print_msg("Cannot execute command. "..ast:gsub("^[^:]+:%d+: ", ""))
    return
  end
  jump_linker(ast)
  if measured then
    fold_const(ast)
    fold_control_statements(ast)
  end
  local compiled = compiler(ast, measured)
  local bytecode = dump(compiled)
  local command, err = load(bytecode, nil, "b", command_env)
  if not command then
    error(err) -- Phobos generated broken bytecode
  end
  if measured then
    profiler.stop()
    print_msg{"", "Compilation and Load ", profiler}
    profiler.reset()
  end

  if measured then
    profiler.restart()
  end
  success, err = xpcall(command, function(msg)
    if measured then
      profiler.stop()
    end
    -- this traceback includes 2 lines at the bottom which are not really part of the command.
    -- this control.lua file and the xpcall.
    -- it could blindly remove the last 2 lines but for now i think this is fine.
    return debug.traceback(msg, 2)
  end)
  if measured then
    if success then
      profiler.stop()
    end
    print_msg{"", "Execution ", profiler}
  end

  if not success then
    print_msg("Runtime error in command. "..err)
    return
  end
end

local function silent_phobos_command(args)
  phobos_command(args, true)
end

local function measured_phobos_command(args)
  phobos_command(args, false, true)
end

local phobos_help = "<Phobos command> - Executes a Phobos command (if allowed). \z
  (Debug build; Compiled without optimizations and no tailcalls)"
local silent_phobos_help = "<Phobos command> - Executes a Phobos command (if allowed) \z
  without printing it to the console. \z
  (Debug build; Compiled without optimizations and no tailcalls)"
local measured_phobos_help = "<Phobos command> - Executes a Phobos command (if allowed) \z
  and measures time it took to compile and execute. \z
  (Release build; Compiled with all optimizations)"

---cSpell:ignore spho
commands.add_command("pho", phobos_help, phobos_command)
commands.add_command("phobos", phobos_help, phobos_command)
commands.add_command("spho", silent_phobos_help, silent_phobos_command)
commands.add_command("silent-phobos", silent_phobos_help, silent_phobos_command)
commands.add_command("measured-phobos", measured_phobos_help, measured_phobos_command)
