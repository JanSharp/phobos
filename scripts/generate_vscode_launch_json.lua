
local json = require("scripts.json_util")

local result = {version = "0.2.0"}
json.set_comments(result, {
  version = "\z
    ====================================================================================================\n\z
    This file is generated. To make changes to this file modify the\n\z
    scripts/generate_vscode_launch_json.lua file and run it.\n\z
    To run the script ensure the current working directory is the root of the project\n\z
    and run it from a terminal with `bin/<platform>/lua -- scripts/generate_vscode_launch_json.lua`\n\z
    where '<platform>' is 'linux', 'osx' or 'windows'.\n\z
    \n\z
    Additional note: This file is still included in git purely for convenience. Just make sure to\n\z
    commit both the changed script and the generated output in the same commit.\n\z
    ====================================================================================================\n\z
    \n\z
    Use IntelliSense to learn about possible attributes.\n\z
    Hover to view descriptions of existing attributes.\n\z
    For more information, visit: https://go.microsoft.com/fwlink/?linkid=830387\z
  "
})
local configurations = {}
result.configurations = configurations
local inputs = {}
result.inputs = inputs
json.set_order(result, {
  "version",
  "configurations",
  "inputs",
})

local function add_profile(profile)
  json.set_order(profile, {
    "name",
    "type",
    "request",
    "preLaunchTask",
  })
  configurations[#configurations+1] = profile
end

local function add_input(input)
  json.set_order(input, {
    "id",
    "type",
  })
  inputs[#inputs+1] = input
end

---cSpell:ignore factoriomod, freeplay

local function new_factorio_profile(params)
  local profile = {
    name = params.name,
    type = "factoriomod",
    request = "launch",
    preLaunchTask = "Build Factorio Mod Debug",
    factorioPath = "${env:PHOBOS_FACTORIO_PATH}",
    modsPath = "${workspaceFolder}/out/debug_factorio",
    allowDisableBaseMod = true,
    adjustMods = {
      phobos = true,
    },
    disableExtraMods = true,
    factorioArgs = {
      "--load-scenario", params.scenario,
      "--window-size", "1280x720",
    },
  }
  for _, mod in ipairs(params.base_mods) do
    profile.adjustMods[mod] = true
  end
  return profile
end

add_profile(new_factorio_profile{
  name = "Factorio Mod (base)",
  base_mods = {"base"},
  scenario = "base/freeplay",
})
add_profile(new_factorio_profile{
  name = "Factorio Mod (minimal no base)",
  base_mods = {
    "minimal-no-base-mod",
    "JanSharpDevEnv",
  },
  scenario = "JanSharpDevEnv/NoBase",
})

local function add_phobos_profiles(params)
  for _, compiler in ipairs{"Lua", "Phobos"} do
    local function make_platform_specific_stuff(platform)
      local args = {
        compiler == "Phobos" and "out/src/debug" or "src",
        "bin/"..platform,
        platform == "windows" and ".dll" or ".so",
        params.main_filename
          or compiler == "Phobos"
            and "out/src/debug/"..params.main_filename_in_phobos_root
            or "src/"..params.main_filename_in_phobos_root,
      }
      json.set_comments(args, {
        "root",
        "c_lib_root",
        "c_lib_extension",
        "main_filename",
        "arguments passed along to the main file",
      })
      if params.args then
        local param_args = type(params.args) == "table" and params.args or params.args(platform)
        for _, arg in ipairs(param_args) do
          args[#args+1] = arg
        end
      end
      return {
        program = {
          lua = "bin/"..platform.."/lua",
          file = compiler == "Phobos" and "out/src/debug/entry_point.lua" or "src/entry_point.lua",
        },
        args = args,
      }
    end
    local profile = {
      name = compiler.." "..params.name,
      type = "lua-local",
      request = "launch",
      linux = make_platform_specific_stuff("linux"),
      osx = make_platform_specific_stuff("osx"),
      windows = make_platform_specific_stuff("windows"),
      -- hm, apparently it doesn't complain anymore when it's omitted but defined for all platforms
      -- program = {
      --   lua = "",
      --   file = "",
      -- },
    }
    -- json.set_comments(profile, {
    --   program = "uh, I guess? vscode is complaining without this",
    -- })
    profile.preLaunchTask = compiler == "Phobos" and "Build Debug" or nil
    add_profile(profile)
  end
end

add_phobos_profiles{
  name = "debugging/main",
  main_filename = "debugging/main.lua",
  args = {"temp/test.lua"},
}
add_phobos_profiles{
  name = "debugging/formatter",
  main_filename = "debugging/formatter.lua",
  args = {"temp/test.lua"},
}
add_phobos_profiles{
  name = "tests/compile_test",
  main_filename = "tests/compile_test.lua",
}
add_phobos_profiles{
  name = "tests/main",
  main_filename = "tests/main.lua",
}
local function add_test_id_input(postfix)
  add_input{
    id = "testId"..postfix,
    type = "promptString",
    description = "The test id of the test to run.",
    default = nil,
    password = false,
  }
end
add_test_id_input("1")
add_test_id_input("2")
add_phobos_profiles{
  name = "tests/main test id",
  main_filename = "tests/main.lua",
  args = {"--test-ids", "${input:testId1}"}
}
add_phobos_profiles{
  name = "tests/main test ids",
  main_filename = "tests/main.lua",
  args = {"--test-ids", "${input:testId1}", "${input:testId2}"}
}
add_input{
  id = "testScope",
  type = "promptString",
  description = "The scope to run.",
  default = nil,
  password = false,
}
add_phobos_profiles{
  name = "tests/main test scope",
  main_filename = "tests/main.lua",
  args = {"--scopes", "${input:testScope}"}
}
add_phobos_profiles{
  name = "tests/main test scope and id",
  main_filename = "tests/main.lua",
  args = {"--scopes", "${input:testScope}", "--test-ids", "${input:testId1}"}
}
add_phobos_profiles{
  name = "src/main (debug profile)",
  main_filename_in_phobos_root = "main.lua",
  args = function(platform) return {"--profile-names", "debug", "--", "--platform", platform} end,
}
add_phobos_profiles{
  name = "src/main (debug profile with docs)",
  main_filename_in_phobos_root = "main.lua",
  args = function(platform) return {
    "--profile-names", "debug", "--", "--platform", platform, "--generate-docs",
  } end,
}
add_phobos_profiles{
  name = "src/main (debug_factorio profile)",
  main_filename_in_phobos_root = "main.lua",
  args = {"--profile-names", "debug_factorio"},
}

local file = assert(io.open(".vscode/launch.json", "w"))
assert(file:write(json.to_json(result, {
  default_empty_table_type = "array",
  use_trailing_comma = true,
  indent = "  ",
})))
assert(file:close())
