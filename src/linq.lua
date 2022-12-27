
-- function names and behavior inspired by C# System.Linq

---@class LinqObj
---@field __tab any[]
---@field __start_index integer
---@field __stop_index integer
local linq_meta_index = {}
local linq_meta = {__index = linq_meta_index}

-- select
-- where
-- order_by
-- order_by_desc
-- sort
-- to_array
-- iterate

-- [ ] all
-- [ ] any
-- [ ] append
-- [ ] append_range
-- [ ] append_linq
-- [ ] average
-- [ ] ? chunk
-- [ ] contains
-- [x] count
-- [ ] ? default_if_empty
-- [ ] distinct
-- [ ] distinct_by
-- [ ] ? element_at
-- [ ] except
-- [ ] except_by
-- [ ] find
-- [ ] find_last
-- [ ] first
-- [ ] foreach
-- [ ] group_by
-- [ ] group_join
-- [ ] ? index_of
-- [ ] ? index_of_last
-- [ ] ? insert
-- [ ] ? insert_range
-- [ ] intersect
-- [ ] intersect_by
-- [x] iterate
-- [ ] join
-- [ ] last
-- [ ] max
-- [ ] max_by
-- [ ] min
-- [ ] min_by
-- [ ] order
-- [ ] order_by
-- [ ] order_desc
-- [ ] order_desc_by
-- [ ] prepend
-- [ ] ? remove_first
-- [ ] ? remove_last
-- [ ] ? remove_at
-- [ ] ? remove_range
-- [ ] reverse
-- [x] select
-- [ ] select_many
-- [ ] sequence_equal
-- [ ] single
-- [ ] skip
-- [ ] skip_last
-- [ ] skip_while
-- [ ] sort
-- [ ] sum
-- [x] take
-- [ ] take_last
-- [ ] take_while
-- [ ] to_array
-- [ ] to_dict
-- [ ] to_linked_list
-- [ ] to_lookup
-- [ ] union
-- [ ] union_by
-- [ ] where



-- ---@generic T
-- ---@generic TResult
-- ---@param self LinqObj|T[]
-- ---@param selector fun(value: T, i: integer):TResult
-- ---@return LinqObj|TResult[]
-- function linq_meta:select(selector)
--   local tab = self.__tab
--   for i = 1, self.count do
--     tab[i] = selector(tab[i], i)
--   end
--   return self
-- end

-- ---@generic T
-- ---@param self LinqObj|T[]
-- ---@param condition fun(value: T, i: integer):boolean
-- ---@return LinqObj|T[]
-- function linq_meta:where(condition)
--   local tab = self.__tab
--   local new_i = 0
--   for i = 1, self.count do
--     local value = tab[i]
--     tab[i] = nil
--     if condition(value, i) then
--       new_i = new_i + 1
--       tab[new_i] = tab[i]
--     end
--   end
--   self.count = new_i
--   return self
-- end

-- ---@generic T
-- ---@param self LinqObj|T[]
-- ---@param selector fun(value: T):any
-- ---@return LinqObj|T[]
-- function linq_meta:order_by(selector)
--   table.sort(self.__tab, function(left, right)
--     return selector(left) < selector(right)
--   end)
--   return self
-- end

-- ---@generic T
-- ---@param self LinqObj|T[]
-- ---@param selector fun(value: T):any
-- ---@return LinqObj|T[]
-- function linq_meta:order_by_desc(selector)
--   table.sort(self.__tab, function(left, right)
--     return selector(left) > selector(right)
--   end)
--   return self
-- end

-- ---@generic T
-- ---@param self LinqObj|T[]
-- ---@param sort fun(left: T, right: T):boolean
-- ---@return LinqObj|T[]
-- function linq_meta:sort(sort)
--   table.sort(self.__tab, sort)
--   return self
-- end

-- ---Returns the internal array without copying it
-- ---@generic T
-- ---@param self LinqObj|T[]
-- ---@return T[]
-- function linq_meta:array()
--   return self.__tab
-- end

-- ---Copies the internal array and returns it
-- ---@generic T
-- ---@param self LinqObj|T[]
-- ---@return T[]
-- function linq_meta:to_array()
--   local tab = self.__tab
--   local tab_copy = {}
--   for i = 1, #tab do
--     tab_copy[i] = tab[i]
--   end
--   return tab_copy
-- end

-- ---@generic T
-- ---@param self LinqObj|T[]
-- ---@return fun(table: T[], i?: integer):integer, T iter
-- ---@return T[] state
-- ---@return nil key
-- function linq_meta:iterate()
--   return ipairs(self.__tab)
-- end

---@generic T
---@param self LinqObj|T[]
---@return integer
function linq_meta_index:count()
  return self.__stop_index - self.__start_index + 1
end

---@generic T
---@param state LinqObj|T[]
---@param index integer?
---@return integer? index
---@return T? value
local function linq_next(state, index)
  index = state.__start_index + (index or 0)
  if index > state.__stop_index then return end
  return index - state.__start_index + 1, state.__tab[index]
end

---@generic T
---@param self LinqObj|T[]
---@return fun(table: T[], i: integer?):integer?, T? iter
---@return LinqObj|T[] state
---@return nil key
function linq_meta_index:iterate()
  return linq_next, self
end

---@generic T
---@generic TResult
---@param self LinqObj|T[]
---@param selector fun(value: T, i: integer):TResult
---@return LinqObj|TResult[]
function linq_meta_index:select(selector)
  local tab = self.__tab
  for i = self.__start_index, self.__stop_index do
    tab[i] = selector(tab[i], i)
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param amount integer
---@return LinqObj|T[]
function linq_meta_index:take(amount)
  self.__stop_index = math.min(self.__stop_index, self.__start_index + amount - 1)
  return self
end

---@generic T
---@param tab T[]
---@param do_copy boolean?
---@return LinqObj|T[]
local function linq(tab, do_copy)
  if do_copy then
    local tab_copy = {}
    for i = 1, #tab do
      tab_copy[i] = tab[i]
    end
    tab = tab_copy
  end
  return setmetatable({
    __tab = tab,
    __start_index = 1,
    __stop_index = #tab,
  }, linq_meta)
end

return linq
