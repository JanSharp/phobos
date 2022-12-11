
local util = require("util")

---@param func ILFunction
local function cyclomatic_complexity(func)
  util.debug_assert(func.has_blocks, "cyclomatic_complexity requires blocks to be evaluated.")

  -- supposedly the definition of cyclomatic complexity is calculated like
  -- amount_of_links - amount_of_blocks + 2
  -- but that seems weird with early returns, they end up reducing the complexity by 1
  -- so instead i'm just counting all blocks that end with a test instruction (in intermediate language)
  -- seems good enough since this was mostly just for fun for now

  -- local block_count = 0
  -- local link_count = 0
  local result = 1

  local block = func.blocks.first
  while block do
    -- block_count = block_count + 1
    -- link_count = link_count + #block.target_links
    if #block.target_links == 2 then
      result = result + 1
    end
    block = block.next
  end

  -- return link_count - block_count + 2
  return result
end

return cyclomatic_complexity
