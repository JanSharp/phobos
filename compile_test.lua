
local phobos_env = {}
for k, v in pairs(_G) do
  phobos_env[k] = v
end
phobos_env.arg = nil

local compiled_modules
local cached_modules = {}
function phobos_env.require(module)
  if cached_modules[module] then
    return cached_modules[module]
  end
  local original_module = module
  if module:find("/") then
    if not module:find("%.lua$") then
      module = module..".lua"
    end
  else
    module = module:gsub("%.", "/")..".lua"
  end

  local chunk = assert(compiled_modules[module], "No module '"..module.."'.")
  local result = {chunk()}
  cached_modules[original_module] = result[1] == nil and true or result[1]
  return table.unpack(result)
end

local parser
local jump_linker
local fold_const
local phobos
local dump

local compiled

local req

local function init()
  parser = req("parser")
  jump_linker = req("jump_linker")
  fold_const = req("optimize.fold_const")
  phobos = req("phobos")
  dump = req("dump")
end

local function compile(filename)
  local file = assert(io.open(filename,"r"))
  local text = file:read("*a")
  file:close()

  local ast = parser(text, "@"..filename)
  jump_linker(ast)
  fold_const(ast)
  phobos(ast)
  local bytecode = dump(ast)
  compiled[filename] = assert(load(bytecode, nil, "b", phobos_env))
end

local lfs = require("lfs")

local function process_dir(dir)
  for entry_name in lfs.dir(dir or ".") do
    if entry_name ~= "." and entry_name ~= ".."
      and entry_name:sub(1, 1) ~= "."
    then
      local relative_name = dir and (dir.."/"..entry_name) or entry_name
      if lfs.attributes(relative_name, "mode") == "directory" then
        process_dir(relative_name)
      elseif relative_name:find("%.lua$") then
        print(relative_name)
        compile(relative_name)
      end
    end
  end
end

compiled = {}
req = require
init()
process_dir()
local lua_result = compiled

print("----")

compiled_modules = lua_result
compiled = {}
req = phobos_env.require
init()
process_dir()
local pho_result = compiled

print("----")

local success = true
for k, v in pairs(pho_result) do
  if v ~= lua_result[k] then
    print("Bytecode differs for "..k..".")
    success = false
  end
end
if success then
  print("No differences - Success!")
end
