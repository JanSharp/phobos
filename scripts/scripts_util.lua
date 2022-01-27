
local function read_info_json()
  local file = assert(io.open("info.json", "r"))
  local info_json = file:read("*a")
  assert(file:close())
  return info_json
end

local function write_info_json(info_json)
  local file = assert(io.open("info.json", "w"))
  assert(file:write(info_json))
  assert(file:close())
  return info_json
end

local info_json_version_pattern = "(\"version\"%s*:%s*\")(%d+%.%d+%.%d+)\""

local function get_info_json_version_str(info_json)
  local _, version_str = info_json:match(info_json_version_pattern)
  if not version_str then
    error("Unable to get version from info.json")
  end
  return version_str
end

local function set_info_json_version_str(info_json, version_str)
  return info_json:gsub(info_json_version_pattern, function(prefix)
    return prefix..version_str..'"'
  end)
end

return {
  read_info_json = read_info_json,
  write_info_json = write_info_json,
  get_info_json_version_str = get_info_json_version_str,
  set_info_json_version_str = set_info_json_version_str,
}
