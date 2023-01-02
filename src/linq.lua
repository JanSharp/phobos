
-- function names and behavior inspired by C# System.Linq

---@class LinqObj
---@field __is_linq true
---@field __iter fun():any?
---@field __count integer? @ `nil` when count is unknown
local linq_meta_index = {}
local linq_meta = {__index = linq_meta_index}

-- [x] all
-- [x] any
-- [x] append
-- [x] average
-- [ ] ? chunk
-- [x] contains
-- [x] count
-- [ ] ? default_if_empty
-- [x] distinct
-- [ ] ? element_at
-- [x] except
-- [x] except_by
-- [x] except_lut
-- [x] except_lut_by
-- [x] first
-- [x] for_each
-- [x] group_by
-- [x] group_join
-- [ ] ? index_of
-- [ ] ? index_of_last
-- [ ] ? insert
-- [ ] ? insert_range
-- [x] intersect
-- [x] iterate
-- [x] join
-- [ ] last
-- [x] max
-- [x] max_by
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

---@generic T
---@param self LinqObj|T[]
---@param condition fun(value: T, index: integer?):boolean
---@return boolean
function linq_meta_index:all(condition)
  local i = 1
  for value in self.__iter do
    if not condition(value, i) then
      return false
    end
    i = i + 1
  end
  return true
end

---@generic T
---@param self LinqObj|T[]
---@param condition fun(value: T, index: integer?):boolean
---@return boolean
function linq_meta_index:any(condition)
  local i = 1
  for value in self.__iter do
    if condition(value, i) then
      return true
    end
    i = i + 1
  end
  return false
end

---@generic T
---@generic TResult
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:append(collection)
  local current_iter = self.__iter
  local next_iter
  if collection.__is_linq then
    next_iter = collection.__iter
    if self.__count and collection.__count then
      self.__count = self.__count + collection.__count
    else
      self.__count = nil
    end
  else
    local i = 0
    next_iter = function()
      i = i + 1
      return collection[i]
    end
    if self.__count then
      self.__count = self.__count + #collection
    end
  end
  self.__iter = function()
    local value = current_iter()
    if value == nil then
      if next_iter == nil then return end
      current_iter = next_iter
      next_iter = nil
      value = current_iter()
    end
    return value
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param selector (fun(value: T, index: integer): number)?
---@return number
function linq_meta_index:average(selector)
  -- technically this function contains the same logic 3 times
  -- this is purely for optimization reasons

  if selector then
    local i = 0
    local total = 0
    for value in self.__iter do
      i = i + 1
      total = total + selector(value, i)
    end
    return total / i
  end

  if self.__count then
    local total = 0
    for value in self.__iter do
      total = total + value
    end
    return total / self.__count
  end

  local i = 0
  local total = 0
  for value in self.__iter do
    i = i + 1
    total = total + value
  end
  return total / i
end

---@generic T
---@param self LinqObj|T[]
---@param value T
---@return boolean
function linq_meta_index:contains(value)
  for v in self.__iter do
    if v == value then
      return true
    end
  end
  return false
end

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

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param selector (fun(value: T, index: integer): any)?
---@return LinqObj|T[]
function linq_meta_index:distinct(selector)
  self.__count = nil
  local inner_iter = self.__iter
  local visited_lut = {}
  if selector then
    local i = 0
    self.__iter = function()
      while true do
        local value = inner_iter()
        if value == nil then return end
        i = i + 1
        value = selector(value, i)
        if not visited_lut[value] then
          visited_lut[value] = true
          return value
        end
      end
    end
  else
    -- this is duplicated logic with the selector stuff removed for optimization
    self.__iter = function()
      while true do
        local value = inner_iter()
        if value == nil then return end
        if not visited_lut[value] then
          visited_lut[value] = true
          return value
        end
      end
    end
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@generic T
---@param collection LinqObj|T[]
---@return table<T, true>
local function build_lut_for_except(collection)
  local lut = {}
  if collection.__is_linq then
    for value in collection.__iter do
      lut[value] = true
    end
  else
    for i = 1, #collection do
      lut[collection[i]] = true
    end
  end
  return lut
end

---@generic T
---@param self LinqObj|T[]
---@param lut (table<T, true>)?
---@param collection (LinqObj|T[])?
---@return LinqObj|T[]
local function except_internal(self, lut, collection)
  self.__count = nil
  -- collection will never be nil if lut is nil
  ---@cast collection -nil
  local inner_iter = self.__iter
  self.__iter = function()
    lut = lut or build_lut_for_except(collection)
    local value
    repeat
      value = inner_iter()
    until not lut[value] -- if value is nil it will break out of the loop
    return value
  end
  return self
end

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param key_selector fun(value: T, index: integer): TKey
---@param lut (table<T, true>)?
---@param collection (LinqObj|TKey[])?
---@return LinqObj|T[]
local function except_by_internal(self, key_selector, lut, collection)
  self.__count = nil
  -- collection will never be nil if lut is nil
  ---@cast collection -nil
  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    lut = lut or build_lut_for_except(collection)
    local value
    repeat
      value = inner_iter()
      if value == nil then return end
      i = i + 1
    until not lut[key_selector(value, i)]
    return value
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:except(collection)
  return except_internal(self, nil, collection)
end

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param collection LinqObj|TKey[]
---@param key_selector fun(value: T, index: integer): TKey
---@return LinqObj|T[]
function linq_meta_index:except_by(collection, key_selector)
  return except_by_internal(self, key_selector, nil, collection)
end

---@generic T
---@param self LinqObj|T[]
---@param lut table<T, true>
---@return LinqObj|T[]
function linq_meta_index:except_lut(lut)
  return except_internal(self, lut)
end

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param lut table<TKey, true>
---@param key_selector fun(value: T, index: integer): TKey
---@return LinqObj|T[]
function linq_meta_index:except_lut_by(lut, key_selector)
  return except_by_internal(self, key_selector, lut)
end

---@generic T
---@param self LinqObj|T[]
---@param condition (fun(value: T, index: integer): boolean)?
---@return T? value
---@return integer? index
function linq_meta_index:first(condition)
  if condition then
    local i = 1
    for value in self.__iter do
      if condition(value, i) then
        return value, i
      end
      i = i + 1
    end
    return
  end
  local value = self.__iter()
  if value ~= nil then
    return value, 1
  end
end

---@generic T
---@param self LinqObj|T[]
---@param action fun(value: T, index: integer)
function linq_meta_index:for_each(action)
  local i = 0
  for value in self.__iter do
    i = i + 1
    action(value, i)
  end
end

-- TODO: probably add an element selector to group_by, effectively performing a
-- select before putting the elements inside of the grouping results

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param key_selector fun(value: T, index: integer): TKey
---@return LinqObj|(({key: TKey, count: integer}|T[])[])
function linq_meta_index:group_by(key_selector)
  self.__count = nil
  local inner_iter = self.__iter
  local i = 0
  local groups
  local groups_index = 0
  self.__iter = function()
    if not groups then
      groups = {}
      local groups_count = 0
      local groups_lut = {}
      for value in inner_iter do
        i = i + 1
        local key = key_selector(value, i)
        local group = groups_lut[key]
        if group then
          local count = group.count + 1
          group.count = count
          group[count] = value
        else
          group = {
            key = key,
            count = 1,
            value,
          }
          groups_lut[key] = group
          groups_count = groups_count + 1
          groups[groups_count] = group
        end
      end
    end

    groups_index = groups_index + 1
    return groups[groups_index]
  end
  return self
end

---@generic TOuter
---@generic TInner
---@generic TKey
---@param self LinqObj|TOuter[]
---@param inner_collection LinqObj|TInner[]
---@param outer_key_selector fun(value: TOuter, index: integer): TKey
---@param inner_key_selector fun(value: TInner, index: integer): TKey
---@return LinqObj|{key: TKey, outer: TOuter, inner: TInner[]}[]
function linq_meta_index:group_join(inner_collection, outer_key_selector, inner_key_selector)
  local iter = self.__iter
  local results
  local results_index = 0
  self.__iter = function()
    if not results then
      local groups_lut = {}
      results = {}
      local i = 0
      for value in iter do
        i = i + 1
        local key = outer_key_selector(value, i)
        local group = groups_lut[key]
        local result
        if group then
          result = {key = key, outer = value, inner = group, requires_copy = true}
        else
          group = {}
          groups_lut[key] = group
          result = {key = key, outer = value, inner = group}
        end
        results[i] = result
      end

      if inner_collection.__is_linq then
        i = 0
        for value in inner_collection.__iter do
          i = i + 1
          local key = inner_key_selector(value, i)
          local group = groups_lut[key]
          if group then
            group[#group+1] = value
          end
        end
      else
        for j = 1, #inner_collection do
          local value = inner_collection[j]
          local key = inner_key_selector(value, j)
          local group = groups_lut[key]
          if group then
            group[#group+1] = value
          end
        end
      end
    end

    results_index = results_index + 1
    local result = results[results_index]
    if not result then return end
    if result.requires_copy then
      local copy = {}
      local group = result.inner
      for i = 1, #group do
        copy[i] = group[i]
      end
      result.inner = copy
      result.requires_copy = nil
    end
    return result
  end
  return self
end

---@diagnostic disable: duplicate-set-field
---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@param key_selector (fun(value: T): TKey)? @ no index, because it's used on both collections
---@return LinqObj|T[]
function linq_meta_index:intersect(collection, key_selector)
  self.__count = nil
  local inner_iter = self.__iter
  local lut
  if key_selector then
    self.__iter = function()
      if not lut then
        lut = {}
        if collection.__is_linq then
          for value in collection.__iter do
            lut[key_selector(value)] = true
          end
        else
          for i = 1, #collection do
            lut[key_selector(collection[i])] = true
          end
        end
      end
      while true do
        local value = inner_iter()
        if value == nil then return end
        if lut[key_selector(value)] then return value end
      end
    end
  else
    -- duplicated for optimization, simply removed calls to `key_selector`
    self.__iter = function()
      if not lut then
        lut = {}
        if collection.__is_linq then
          for value in collection.__iter do
            lut[value] = true
          end
        else
          for i = 1, #collection do
            lut[collection[i]] = true
          end
        end
      end
      while true do
        local value = inner_iter()
        -- and flipped the order of these if checks for a tiny bit of extra performance
        if lut[value] then return value end
        if value == nil then return end
      end
    end
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@generic T
---@param self LinqObj|T[]
---@return fun(state: nil, index: integer?):integer?, T? iter
---@return nil state
---@return nil key
function linq_meta_index:iterate()
  return self.__iter
end

---@generic TOuter
---@generic TInner
---@generic TKey
---@generic TResult
---@param self LinqObj|TOuter[]
---@param inner_collection LinqObj|TInner[]
---@param outer_key_selector fun(value: TOuter, index: integer): TKey
---@param inner_key_selector fun(value: TInner, index: integer): TKey
---@param result_selector fun(outer: TOuter, inner: TInner, index: integer): TResult
---@return LinqObj|TResult[]
function linq_meta_index:join(inner_collection, outer_key_selector, inner_key_selector, result_selector)
  self.__count = nil
  local iter = self.__iter
  local outer_i = 0
  local current_outer
  local current_group
  local current_group_index = 0
  local groups_lut
  local results_index = 0
  self.__iter = function()
    if not groups_lut then
      groups_lut = {}
      if inner_collection.__is_linq then
        local i = 0
        for value in inner_collection.__iter do
          i = i + 1
          local key = inner_key_selector(value, i)
          local group = groups_lut[key]
          if group then
            group[#group+1] = value
          else
            groups_lut[key] = {value}
          end
        end
      else
        for j = 1, #inner_collection do
          local value = inner_collection[j]
          local key = inner_key_selector(value, j)
          local group = groups_lut[key]
          if group then
            group[#group+1] = value
          else
            groups_lut[key] = {value}
          end
        end
      end
    end

    local inner
    while true do
      while not current_group do
        current_outer = iter()
        if current_outer == nil then return end
        outer_i = outer_i + 1
        current_group = groups_lut[outer_key_selector(current_outer, outer_i)]
      end
      current_group_index = current_group_index + 1
      inner = current_group[current_group_index]
      if inner ~= nil then break end
      current_group = nil
      current_group_index = 0
    end

    results_index = results_index + 1
    return result_selector(current_outer, inner, results_index)
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param comparator fun(left: T, right: T): boolean
---@return T
local function max_or_min(self, comparator)
  local result
  for value in self.__iter do
    if result == nil or comparator(value, result) then
      result = value
    end
  end
  return result
end

---@generic T
---@generic TValue
---@param self LinqObj|T[]
---@param selector fun(value: T, index: integer): TValue
---@param comparator fun(left: T, right: T): boolean
---@return T
local function max_or_min_by(self, selector, comparator)
  local result_value
  local result
  local i = 0
  for value in self.__iter do
    i = i + 1
    local num_value = selector(value, i)
    if result_value == nil or comparator(num_value, result_value) then
      result_value = num_value
      result = value
    end
  end
  return result
end

---@generic T
---@param self LinqObj|T[]
---@param left_is_greater_func (fun(left: T, right: T): boolean)?
---@return T
function linq_meta_index:max(left_is_greater_func)
  local max = max_or_min(self, left_is_greater_func or function(left, right) return left > right end)
  if max == nil then error("Attempt to evaluate max value on an empty collection.") end
  return max
end

---@generic T
---@generic TValue
---@param self LinqObj|T[]
---@param selector fun(value: T, index: integer): TValue
---@param left_is_greater_func (fun(left: TValue, right: TValue): boolean)?
---@return T
function linq_meta_index:max_by(selector, left_is_greater_func)
  local result = max_or_min_by(self, selector, left_is_greater_func or function(left, right)
    return left > right
  end)
  if result == nil then error("Attempt to evaluate max value on an empty collection.") end
  return result
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
  self.__count = nil
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
---@generic TState
---@generic TKey
---@param tab_or_iter T[]|fun(state: TState, key: T?):(T?) @ an array or an iterator returning a single value
---@param state TState? @ used if this is an iterator
---@param starting_value T? @ used if this is an iterator
---@return LinqObj|T[]
local function linq(tab_or_iter, state, starting_value)
  if type(tab_or_iter) == "table" then
    local count = #tab_or_iter
    local i = 0
    return setmetatable({
      __is_linq = true,
      __iter = function()
        if i >= count then return end
        i = i + 1
        return tab_or_iter[i]
      end,
      __count = count,
    }, linq_meta)
  else
    local value = starting_value
    return setmetatable({
      __is_linq = true,
      __iter = function()
        value = tab_or_iter(state, value)
        return value
      end,
      -- __count = nil,
    }, linq_meta)
  end
end

return linq
