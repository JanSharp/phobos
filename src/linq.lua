
-- function names and behavior inspired by C# System.Linq

---@class LinqObj
---@field __is_linq true
---@field __iter fun():any?
---@field __count integer? @ `nil` when count is unknown
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
-- [x] select_many
-- [ ] sequence_equal
-- [ ] single
-- [ ] skip
-- [ ] skip_last
-- [ ] skip_while
-- [ ] sort
-- [ ] sum
-- [x] take
-- [ ] take_last
-- [x] take_while
-- [ ] to_array
-- [ ] to_dict
-- [ ] to_linked_list
-- [ ] to_lookup
-- [ ] union
-- [ ] union_by
-- [x] where



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
  if self.__count then
    return self.__count
  end
  local count = 0
  while self.__iter() ~= nil do
    count = count + 1
  end
  return count
end

---@generic T
---@param self LinqObj|T[]
---@return fun(state: nil, index: integer?):integer?, T? iter
---@return nil state
---@return nil key
function linq_meta_index:iterate()
  return self.__iter
end

---@generic T
---@generic TResult
---@param self LinqObj|T[]
---@param selector fun(value: T, i: integer):TResult
---@return LinqObj|TResult[]
function linq_meta_index:select(selector)
  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    local value = inner_iter()
    if value == nil then return end
    i = i + 1
    return selector(value, i)
  end
  return self
end

---@generic T
---@generic TResult
---@param self LinqObj|T[]
---@param selector fun(value: T, i: integer):(LinqObj|TResult[]) @ can either return an array or a linq object
---@return LinqObj|TResult[]
function linq_meta_index:select_many(selector)
  local inner_iter = self.__iter
  local i = 0
  local collection
  ---used if the collection is a linq object
  local collection_iter
  ---used if the collection is an array
  local collection_length
  local collection_index
  self.__iter = function()
    while true do
      if collection then
        if collection_iter then
          local value = collection_iter()
          if value ~= nil then
            return value
          end
        else
          collection_index = collection_index + 1
          if collection_index <= collection_length then
            return collection[collection_index]
          end
        end
      end

      local value = inner_iter()
      if value == nil then return end
      i = i + 1
      collection = selector(value, i)
      if collection.__is_linq then
        collection_iter = collection.__iter
      else
        collection_iter = nil
        collection_length = #collection
        collection_index = 0
      end
    end
  end
  return self
end

-- the language server says that this function has a duplicate set on the `__iter` field... it's drunk

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param count integer
---@return LinqObj|T[]
function linq_meta_index:take(count)
  if count == 0 then
    self.__iter = function() end
    self.__count = 0
    return self
  end
  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    if i >= count then return end
    i = i + 1
    return inner_iter()
  end
  if self.__count then
    self.__count = math.min(self.__count, count)
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@generic T
---@param self LinqObj|T[]
---@param condition fun(value: T, i: integer):boolean
---@return LinqObj|T[]
function linq_meta_index:take_while(condition)
  self.__count = nil
  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    local value = inner_iter()
    i = i + 1
    if value == nil or not condition(value, i) then return end
    return value
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param condition fun(value: T, i: integer):boolean
---@return LinqObj|T[]
function linq_meta_index:where(condition)
  self.__count = nil
  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    local value
    repeat
      value = inner_iter()
      if value == nil then return end
      i = i + 1
    until condition(value, i)
    return value
  end
  return self
end

---@generic T
---@param tab T[]
---@return LinqObj|T[]
local function linq(tab)
  local count = #tab
  local i = 0
  return setmetatable({
    __is_linq = true,
    __iter = function()
      if i >= count then return end
      i = i + 1
      return tab[i]
    end,
    __count = count,
  }, linq_meta)
end

return linq
