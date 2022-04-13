
local util = require("util")
local Path = require("lib.path")
local compile_util = require("compile_util")

---There is actually no use for this right now, but I'm keeping it just in case it will be needed later
local function new_sandbox()
  -- keep package as a reference because the vast majority of it
  -- only works if the real _ENV is modified
  local real_package = package
  package = nil
  local env = util.copy(_ENV)
  package = real_package
  env.package = real_package
  return env
end

local template_separator = util.debug_assert(package.config:match("[^\n]+\n([^\n]+)"),
  "Could not setup template separator. 'package.config' is most likely invalid."
)
if #template_separator > 1 then
  util.abort("Unsupported Lua configuration for the template separator '"
    ..template_separator.."'. Phobos only supports single character separators."
  )
end

---TODO: this is still a bit of a prototype, I'd like to refine it before calling it done
local function enable_phobos_require()
  local pho_path_cache = {}
  local function get_pho_path()
    local pho_path = pho_path_cache[package.path]
    if not pho_path then
      local paths = {}
      for path_str in package.path:gmatch("[^%"..template_separator.."]+") do
        local path = Path.new(path_str)
        path = path:sub(1, -2) / (path:filename()..".pho")
        paths[#paths+1] = path:str()
      end
      pho_path = table.concat(paths, template_separator)
      pho_path_cache[package.path] = pho_path
    end
    return pho_path
  end

  local function pho_loader(module_name, filename)
    local context = compile_util.new_context()
    local loadable_chunk = compile_util.compile({
      filename = filename,
      source_name = "@?",
      accept_bytecode = true,
      error_message_count = 8,
    }, context)
    if not loadable_chunk then
      error()
    end
    return assert(load(loadable_chunk))(filename)
  end

  local function pho_searcher(module_name)
    local filename, err = package.searchpath(module_name, get_pho_path())
    if not filename then
      return err
    end
    return pho_loader, filename
  end

  table.insert(package.searchers, math.min(#package.searchers, 3), pho_searcher)
end

local files

local function reset_required_filenames()
  files = {}
end

local function get_required_filenames()
  return files
end

local files_cache = {}
local function add_file(filename)
  if not files_cache[filename] then
    files_cache[filename] = true
    files[#files+1] = filename
  end
end

local module_cache = {}
local raw_require = require
local function custom_require(module_name)
  if module_cache[module_name] then
    add_file(module_cache[module_name])
  elseif not package.loaded[module_name] then
    for _, searcher in ipairs(package.searchers) do
      local loader, filename = searcher(module_name)
      if type(loader) == "function" then
        if filename then -- if not filename then it's a preload or some other custom loader
          add_file(filename)
          module_cache[module_name] = filename
        end
        break
      end
    end
  end
  return raw_require(module_name)
end

local function hook_require()
  require = custom_require
end

local function unhook_require()
  require = raw_require
end

local raw_loadfile = loadfile
local function custom_loadfile(filename, mode, env)
  files[#files+1] = filename
  return raw_loadfile(filename, mode, env)
end

local function hook_loadfile()
  loadfile = custom_loadfile
end

local function unhook_loadfile()
  loadfile = raw_loadfile
end

local function hook(do_not_reset_required_files)
  if not do_not_reset_required_files then
    reset_required_filenames()
  end
  hook_require()
  hook_loadfile()
end

local function unhook()
  unhook_require()
  unhook_loadfile()
  return get_required_filenames()
end

-- local function save_loaded_state()
--   local state = {}
--   for k in pairs(package.loaded) do
--     state[k] = true
--   end
--   return state
-- end

-- local function diff_loaded_state(prev_state)
--   local diff = {}
--   for k in pairs(package.loaded) do
--     if not prev_state[k] then
--       diff[#diff+1] = k
--     end
--   end
--   table.sort(diff)
--   return diff
-- end

return {
  new_sandbox = new_sandbox,
  enable_phobos_require = enable_phobos_require,
  reset_required_filenames = reset_required_filenames,
  get_required_filenames = get_required_filenames,
  hook = hook,
  unhook = unhook,
}
