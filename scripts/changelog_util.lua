
local util = require("util")

local parse_version = util.parse_version
local print_version = util.format_version

local function compare_version(left, right)
  return left.major == right.major
    and left.minor == right.minor
    and left.patch == right.patch
end

local function decode(text)
  local i = 1
  local line = 1

  local function test_next(pattern, is_plain)
    local match_start, match_end = text:find((is_plain and "" or "^")..pattern, i, is_plain)
    if match_end and (not is_plain or match_start == i) then
      i = match_end + 1
      if pattern == "\n" then
        line = line + 1
      end
      return true
    else
      return false
    end
  end

  local function print_pattern(pattern, is_plain)
    if is_plain then
      return '"'..pattern..'"'
    else
      return string.format("pattern %q", pattern):gsub("\\\n", "\\n")
    end
  end

  local function assert_next(pattern, is_plain)
    if not test_next(pattern, is_plain) then
      error("Expected "..print_pattern(pattern, is_plain).." on line "..line)
    end
  end

  local function assert_match(pattern)
    local matches = {text:match("^"..pattern.."()", i)}
    if not matches[1] then
      error("Expected "..print_pattern(pattern).." on line "..line)
    end
    i = matches[#matches]
    return table.unpack(matches, 1, #matches - 1)
  end

  local function assert_parse_version()
    local version, end_pos = parse_version(text, i)
    if not version then
      error("Expected version on line "..line)
    end
    i = end_pos
    return version
  end

  local function prev()
    return text:sub(i - 1, i - 1)
  end

  local function read_newlines()
    while test_next("\n") do end
    return i <= #text
  end

  local function parse_entry(category)
    if prev() ~= "\n" then
      return false
    end
    if test_next("    - ", true) then
      local lines = {}
      category.entries[#category.entries+1] = lines
      local function add_line()
        lines[#lines+1] = assert_match("([^\n ][^\n]*)")
      end
      add_line()
      while test_next("\n"..string.rep(" ", 6)) do
        line = line + 1
        add_line()
      end
      return true
    else
      return false
    end
  end

  local function parse_category(version_block)
    if prev() ~= "\n" then
      return false
    end
    if test_next("Date: ", true) then
      if version_block.date then
        error("Duplicate date at line "..line)
      end
      version_block.date = assert_match("([^\n]*)")
      return true
    elseif test_next("  [^ ]") then
      i = i - 1
      local category = {
        name = assert_match("([^\n ][^\n]*):"),
        entries = {},
      }
      version_block.categories[#version_block.categories+1] = category
      while read_newlines() and parse_entry(category) do end
      return true
    else
      return false
    end
  end

  local function parse_version_block(version_blocks)
    if (prev() ~= "\n" and i ~= 1)
      or (not test_next(string.rep("-", 99), true))
      or (i > #text)
    then
      return false
    end
    assert_next("\n")
    assert_next("Version: ", true)
    local version_block = {
      version = assert_parse_version(),
      categories = {},
    }
    version_blocks[#version_blocks+1] = version_block
    while read_newlines() and parse_category(version_block) do end
    return true
  end

  local version_blocks = {}
  while read_newlines() and parse_version_block(version_blocks) do end
  if i <= #text then
    error("Invalid line "..line)
  end

  return version_blocks
end

local function encode(changelog)
  local out = {}
  local function add(str)
    out[#out+1] = str
  end

  local function add_entry(entry)
    local line_start = "    - "
    for _, line in ipairs(entry) do
      add(line_start)
      add(line)
      add("\n")
      line_start = string.rep(" ", 6)
    end
  end

  local function add_category(category)
    add("  ")
    add(category.name)
    add(":")
    add("\n")
    for _, entry in ipairs(category.entries) do
      add_entry(entry)
    end
  end

  local function add_version_block(version_block)
    add(string.rep("-", 99))
    add("\n")
    add("Version: ")
    add(print_version(version_block.version))
    add("\n")
    if version_block.date then
      add("Date: ")
      add(version_block.date)
      add("\n")
    end
    for _, category in ipairs(version_block.categories) do
      add_category(category)
    end
  end

  for _, version_block in ipairs(changelog) do
    add_version_block(version_block)
  end

  out[#out] = nil
  return table.concat(out)
end

return {
  decode = decode,
  encode = encode,
  parse_version = parse_version,
  print_version = print_version,
  compare_version = compare_version,
}
