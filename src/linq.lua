
-- function names and behavior inspired by C# System.Linq

local ll = require("linked_list")

---@class LinqObj
---@field __is_linq true
---@field __iter fun():any?
---@field __count integer? @ `nil` when count is unknown
---@field __ordering_definitions {descending: boolean, selector: fun(value: any): any}[]
---@field __ordering_reference_iter (fun():any?)?
local linq_meta_index = {}
local linq_meta = {__index = linq_meta_index}

---@generic T
---@param array T[]
---@param count integer
---@return fun():T
local function make_array_iter(array, count)
  local i = 0
  return function()
    if i >= count then return end
    i = i + 1
    return array[i]
  end
end

-- [x] all
-- [x] any
-- [x] append
-- [x] average
-- [x] chunk
-- [x] contains
-- [x] copy
-- [x] count
-- [x] default_if_empty
-- [x] distinct
-- [x] distinct_by
-- [x] element_at
-- [x] element_at_from_end
-- [x] ensure_knows_count
-- [x] except
-- [x] except_by
-- [x] except_lut
-- [x] except_lut_by
-- [x] first
-- [x] for_each
-- [x] group_by
-- [x] group_by_select
-- [x] group_join
-- [x] index_of (more performant than using `first`)
-- [x] index_of_last (more performant than using `last`)
-- [x] insert
-- [x] insert_range
-- [x] intersect
-- [x] intersect_by
-- [x] intersect_lut
-- [x] intersect_lut_by
-- [x] iterate
-- [x] join
-- [x] keep_at (more performant than using `where`)
-- [x] keep_range (more performant than using `where`)
-- [x] last
-- [x] max
-- [x] max_by
-- [x] min
-- [x] min_by
-- [x] order
-- [x] order_by
-- [x] order_descending
-- [x] order_descending_by
-- [x] prepend
-- [x] remove_at (more performant than using `where`)
-- [x] remove_range (more performant than using `where`)
-- [x] reverse
-- [x] select
-- [x] select_many
-- [x] sequence_equal
-- [x] single
-- [x] skip
-- [x] skip_last
-- [x] skip_last_while
-- [x] skip_while
-- [x] sort
-- [x] sum
-- [x] symmetric_difference
-- [x] symmetric_difference_by
-- [x] take
-- [x] take_last
-- [x] take_last_while
-- [x] take_while
-- [x] then_by
-- [x] then_descending_by
-- [x] to_array
-- [x] to_dict
-- [x] to_linked_list
-- [x] to_lookup
-- [x] union
-- [x] union_by
-- [x] where

-- no need for `then` and `then_descending` because if it was sorting an array of numbers or strings, there's
-- hardly ever a reason to use a selector for the initial `order` call, and then not use one in a `then`.
-- meta methods could sometimes make sense, but why would you willingly destroy your performance that badly

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
---@param size integer
---@return LinqObj|T[][]
function linq_meta_index:chunk(size)
  if self.__count then
    self.__count = math.ceil(self.__count / size)
  end
  local inner_iter = self.__iter
  self.__iter = function()
    local value = inner_iter()
    if value == nil then return end
    local chunk = {value}
    for i = 2, size do
      value = inner_iter()
      if value == nil then break end
      chunk[i] = value
    end
    return chunk
  end
  return self
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
---@return LinqObj|T[]
function linq_meta_index:copy()
  -- NOTE: instead of always creating a new table the linq object could remember if it currently already has
  -- a backing array. That would only be the case if it was just created from an array and no other functions
  -- were called on it so far, or copy was just called. This requires almost every other function to
  -- unset whichever field to store the array.
  -- ensure_knows_count also creates an array, so if this is implemented don't forget about that.
  local values = {}
  local count = 0
  for value in self.__iter do
    count = count + 1
    values[count] = value
  end
  self.__count = count
  -- replace self's iter and create a second one for the copy. that way both can iterate the values separate
  -- from each other, and the wrapped object only got iterated once, since the values are stored in an array
  self.__iter = make_array_iter(values, count)
  return setmetatable({
    __is_linq = true,
    __iter = make_array_iter(values, count),
    __count = count,
  }, linq_meta)
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

---@generic T
---@param self LinqObj|T[]
---@param default any|fun():any @ if this is a function it will be used to lazily get the default value
---@return LinqObj|T[]
function linq_meta_index:default_if_empty(default)
  if self.__count == 0 then
    self.__count = 1
  end
  local inner_iter = self.__iter
  local is_first = true
  self.__iter = function()
    if is_first then
      is_first = false
      local value = inner_iter()
      if value ~= nil then
        return value
      end
      if type(default) == "function" then
        return default()
      end
      return default
    end
    return inner_iter()
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param selector (fun(value: T, index: integer): any)?
---@return LinqObj|T[]
local function distinct_internal(self, selector)
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

---@generic T
---@param self LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:distinct()
  return distinct_internal(self)
end

---@generic T
---@param self LinqObj|T[]
---@param selector fun(value: T, index: integer): any
---@return LinqObj|T[]
function linq_meta_index:distinct_by(selector)
  return distinct_internal(self, selector)
end

---@generic T
---@param self LinqObj|T[]
---@param index integer
---@return T?
function linq_meta_index:element_at(index)
  -- knows count and index is past the sequence, return nil
  if self.__count and self.__count < index then return end
  local i = 1
  for value in self.__iter do
    if i == index then
      return value
    end
    i = i + 1
  end
end

---@generic T
---@param self LinqObj|T[]
---@param index integer
---@return T?
function linq_meta_index:element_at_from_end(index)
  if self.__count then
    local index_from_front = self.__count - index + 1
    if index_from_front < 0 then return end
    return self:element_at(index_from_front)
  end

  local queue = {}
  local count = 0
  for value in self.__iter do
    queue[(count % index) + 1] = value
    count = count + 1
  end
  return queue[(count % index) + 1]
end

---Ensures this object knows how many elements are contained in this sequence.
---If it is unknown it iterates the sequence, collecting all elements in an array, saves the resulting count
---and replaces the iterator to iterate the array instead of the previous iterator.
---@generic T
---@param self LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:ensure_knows_count()
  if self.__count then
    return self
  end
  local values = {}
  local count = 0
  for value in self.__iter do
    count = count + 1
    values[count] = value
  end
  self.__count = count
  self.__iter = make_array_iter(values, count)
  return self
end

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

local function group_by(self, key_selector, element_selector)
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
        if element_selector then
          value = element_selector(value, i)
        end
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

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param key_selector fun(value: T, index: integer): TKey
---@return LinqObj|(({key: TKey, count: integer}|T[])[])
function linq_meta_index:group_by(key_selector)
  return group_by(self, key_selector)
end

---Needs to be a separate function because of different generic types and with it different return types
---@generic T
---@generic TKey
---@generic TElement
---@param self LinqObj|T[]
---@param key_selector fun(value: T, index: integer): TKey
---@param element_selector fun(value: T, index: integer): TElement
---@return LinqObj|(({key: TKey, count: integer}|TElement[])[])
function linq_meta_index:group_by_select(key_selector, element_selector)
  return group_by(self, key_selector, element_selector)
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
  -- capture as upvalue in case inner_collection gets modified, though nobody should do that anyway
  local inner_iter = inner_collection.__iter
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
        for value in inner_iter do
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

---@generic T
---@param self LinqObj|T[]
---@param value T
---@return integer?
function linq_meta_index:index_of(value)
  local i = 1
  for v in self.__iter do
    if v == value then
      return i
    end
    i = i + 1
  end
end

---@generic T
---@param self LinqObj|T[]
---@param value T
---@return integer?
function linq_meta_index:index_of_last(value)
  local values = {}
  local values_count = 0
  for v in self.__iter do
    values_count = values_count + 1
    values[values_count] = v
  end

  if values_count == 0 then
    return
  end

  for i = values_count, 1, -1 do
    if values[i] == value then
      return i
    end
  end
end

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param index integer @ if this index is past the sequence, the value will be appended
---@param value T
---@return LinqObj|T[]
function linq_meta_index:insert(index, value)
  if self.__count then
    self.__count = self.__count + 1
  end
  local inner_iter = self.__iter

  if self.__count then
    if index > self.__count then
      -- if it ends up appending, set the index to right past the known count of the inner sequence
      -- (note that __count has already been incremented above)
      index = self.__count
    end
    local i = 0
    self.__iter = function()
      i = i + 1
      if i == index then
        return value
      end
      return inner_iter()
    end
    return self
  end

  local i = 0
  local did_insert = false
  self.__iter = function()
    i = i + 1
    if i == index then
      if did_insert then
        -- this happens when the index is 6 for a sequence of 4 values. the bottom logic inserts the value,
        -- the next iteration i gets incremented to 6, so we enter this block, but it should not insert again
        return
      end
      did_insert = true
      return value
    end
    local current_value = inner_iter()
    if current_value == nil and not did_insert then
      did_insert = true
      return value
    end
    return current_value
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param index integer
---@param collection LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:insert_range(index, collection)
  if collection.__is_linq then -- collection is a linq obj
    if collection.__count == 0 then
      -- optimization
      return self
    end
    self.__count = (self.__count and collection.__count) and (self.__count + collection.__count) or nil

    local inner_iter = self.__iter
    local i = 1
    local iterating_collection = false
    local collection_iter = collection.__iter
    local did_insert = false
    self.__iter = function()
      ::entry::
      if iterating_collection then
        local value = collection_iter()
        if value ~= nil then
          return value
        end
        iterating_collection = false
        did_insert = true
      end

      if i == index and not did_insert then
        -- switch to collection
        iterating_collection = true
        goto entry
      end
      i = i + 1
      local value = inner_iter()
      if value == nil and not did_insert then
        -- switch to collection
        iterating_collection = true
        goto entry
      end
      return value
    end

    return self
  else -- collection is an array
    local collection_count = #collection
    if collection_count == 0 then
      -- this early return is not only better but also required. The iterator below would break without it
      return self
    end
    if self.__count then
      self.__count = self.__count + collection_count
    end

    local inner_iter = self.__iter
    local i = 1
    local collection_index
    local did_insert = false
    self.__iter = function()
      if collection_index then
        collection_index = collection_index + 1
        if collection_index <= collection_count then
          return collection[collection_index]
        end
        collection_index = nil
        did_insert = true
      end

      if i == index and not did_insert then
        collection_index = 1
        return collection[1]
      end
      i = i + 1
      local value = inner_iter()
      if value == nil and not did_insert then
        collection_index = 1
        return collection[1]
      end
      return value
    end

    return self
  end
end
---@diagnostic enable: duplicate-set-field

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param inner_collection (LinqObj|(T|TKey)[])? @ either this
---@param lut table<(T|TKey), true>? @ or this
---@param key_selector (fun(value: T, index: integer): TKey)?
---@return LinqObj|T[]
local function intersect_internal(self, inner_collection, lut, key_selector)
  self.__count = nil
  -- must use a different table for making results distinct when the given lookup table is a parameter,
  -- because we must not modify the given table
  local distinct_lut = lut and {} or nil
  local inner_iter = self.__iter
  local inner_i = 0
  ---@cast inner_collection -nil
  -- capture as upvalue in case collection gets modified, though nobody should do that anyway
  local collection_iter = not lut and inner_collection.__iter
  self.__iter = function()
    if not lut then
      lut = {}
      if inner_collection.__is_linq then
        for value in collection_iter do
          lut[value] = true
        end
      else
        for i = 1, #inner_collection do
          lut[inner_collection[i]] = true
        end
      end
    end
    if key_selector then
      while true do
        local value = inner_iter()
        if value == nil then return end
        inner_i = inner_i + 1
        local key = key_selector(value, inner_i)
        if lut[key] then
          if distinct_lut then
            if not distinct_lut[key] then
              distinct_lut[key] = true
              return value
            end
          else
            lut[key] = nil -- make it distinct
            return value
          end
        end
      end
    else
      -- copy paste for better performance
      while true do
        local value = inner_iter()
        -- flipped the order of these if checks for a tiny bit of extra performance
        if lut[value] then
          if distinct_lut then
            if not distinct_lut[value] then
              distinct_lut[value] = true
              return value
            end
          else
            lut[value] = nil -- make it distinct
            return value
          end
        end
        if value == nil then return end
      end
    end
  end
  return self
end

---Results are distinct.
---@generic T
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:intersect(collection)
  return intersect_internal(self, collection, nil)
end

---Results are distinct.
---@generic T
---@param self LinqObj|T[]
---@param lut table<T, true>
---@return LinqObj|T[]
function linq_meta_index:intersect_lut(lut)
  return intersect_internal(self, nil, lut)
end

---Results are distinct. If 2 different values select the same key, only the first one will be in the output.
---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param key_collection LinqObj|TKey[]
---@param key_selector fun(value: T, index: integer): TKey
---@return LinqObj|T[]
function linq_meta_index:intersect_by(key_collection, key_selector)
  return intersect_internal(self, key_collection, nil, key_selector)
end

---Results are distinct. If 2 different values select the same key, only the first one will be in the output.
---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param lut table<TKey, true>
---@param key_selector fun(value: T, index: integer): TKey
---@return LinqObj|T[]
function linq_meta_index:intersect_lut_by(lut, key_selector)
  return intersect_internal(self, nil, lut, key_selector)
end

---@generic T
---@param self LinqObj|T[]
---@return fun(state: nil, index: integer?): (T?) iterator
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
  -- capture as upvalue in case inner_collection gets modified, though nobody should do that anyway
  local inner_iter = inner_collection.__iter
  self.__iter = function()
    if not groups_lut then
      groups_lut = {}
      if inner_collection.__is_linq then
        local i = 0
        for value in inner_iter do
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

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param index integer
---@return LinqObj|T[]
function linq_meta_index:keep_at(index)
  if self.__count then
    if index > self.__count then
      self.__count = 0
      self.__iter = function() end
      return self
    end
    self.__count = 1
  end
  local inner_iter = self.__iter
  local done = false
  self.__iter = function()
    if done then return end
    local i = 1
    for value in inner_iter do
      if i == index then
        done = true
        return value
      end
      i = i + 1
    end
    -- index is out of range of the sequence
    done = true
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param start integer
---@param stop integer
---@return LinqObj|T[]
function linq_meta_index:keep_range(start, stop)
  if self.__count then
    if start > self.__count or start > stop then
      self.__count = 0
      self.__iter = function() end
      return self
    end
    stop = math.min(self.__count--[[@as integer]], stop)
    self.__count = stop - start + 1
  end

  local inner_iter = self.__iter
  local i = 1
  self.__iter = function()
    while i < start do
      inner_iter()
      i = i + 1
    end
    if i > stop then return end
    i = i + 1
    -- if stop is past the sequence, it doesn't matter because the inner iter will just return nil
    return inner_iter()
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@generic T
---@param self LinqObj|T[]
---@param condition (fun(value: T, index: integer): boolean)?
---@return T? value
---@return integer? index
function linq_meta_index:last(condition)
  local values = {}
  local values_count = 0
  for value in self.__iter do
    values_count = values_count + 1
    values[values_count] = value
  end

  if values_count == 0 then
    return
  end

  if condition then
    for i = values_count, 1, -1 do
      local value = values[i]
      if condition(value, i) then
        return value, i
      end
    end
    return
  end

  return values[values_count], values_count
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
---@param self LinqObj|T[]
---@param left_is_lesser_func (fun(left: T, right: T): boolean)?
---@return T
function linq_meta_index:min(left_is_lesser_func)
  local min = max_or_min(self, left_is_lesser_func or function(left, right) return left < right end)
  if min == nil then error("Attempt to evaluate min value on an empty collection.") end
  return min
end

---@generic T
---@generic TValue
---@param self LinqObj|T[]
---@param selector fun(value: T, index: integer): TValue
---@param left_is_lesser_func (fun(left: TValue, right: TValue): boolean)?
---@return T
function linq_meta_index:min_by(selector, left_is_lesser_func)
  local result = max_or_min_by(self, selector, left_is_lesser_func or function(left, right)
    return left < right
  end)
  if result == nil then error("Attempt to evaluate min value on an empty collection.") end
  return result
end

---@generic T
---@param self LinqObj|T[]
---@return LinqObj|T[]
local function order_internal(self, first_ordering_definition)
  local ordering_definitions = {first_ordering_definition}
  self.__ordering_definitions = ordering_definitions
  local values
  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    if not values then
      values = {}
      local count = self.__count
      if count then
        for j = 1, count do
          values[j] = inner_iter()
        end
      else
        count = 0
        for value in inner_iter do
          count = count + 1
          values[count] = value
        end
      end
      table.sort(values, function(left, right)
        for _, definition in ipairs(ordering_definitions) do
          local left_value
          local right_value
          local selector = definition.selector
          if selector then
            left_value = selector(left)
            right_value = selector(right)
          else
            left_value = left
            right_value = right
          end
          if left_value == right_value then
            goto continue
          end
          if definition.descending then
            return left_value > right_value
          else
            return left_value < right_value
          end
          ::continue::
        end
        ---@diagnostic disable-next-line: unreachable-code
        return false -- it is reachable though...
      end)
    end
    i = i + 1
    return values[i]
  end
  self.__ordering_reference_iter = self.__iter
  return self
end

---@generic T
---@param self LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:order()
  return order_internal(self, {selector = nil, descending = false})
end

---@generic T
---@param self LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:order_descending()
  return order_internal(self, {selector = nil, descending = true})
end

---@generic T
---@generic TValue
---@param self LinqObj|T[]
---@param selector fun(value: T):TValue
---@return LinqObj|T[]
function linq_meta_index:order_by(selector)
  return order_internal(self, {selector = selector, descending = false})
end

---@generic T
---@generic TValue
---@param self LinqObj|T[]
---@param selector fun(value: T):TValue
---@return LinqObj|T[]
function linq_meta_index:order_descending_by(selector)
  return order_internal(self, {selector = selector, descending = true})
end

---@generic T
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:prepend(collection)
  local current_iter
  ---@type fun()?
  local next_iter = self.__iter
  if collection.__is_linq then
    current_iter = collection.__iter
    if self.__count and collection.__count then
      self.__count = self.__count + collection.__count
    else
      self.__count = nil
    end
  else
    local i = 0
    current_iter = function()
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
---@param index integer
---@return LinqObj|T[]
function linq_meta_index:remove_at(index)
  if self.__count then
    if index > self.__count then
      -- index is past the sequence, just do nothing
      return self
    end
    self.__count = self.__count - 1
  end
  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    i = i + 1
    if i == index then
      inner_iter()
      i = i + 1
    end
    return inner_iter()
  end
  return self
end

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param start integer
---@param stop integer
---@return LinqObj|T[]
function linq_meta_index:remove_range(start, stop)
  local count = self.__count
  if count then
    stop = math.min(count, stop)
    count = count - (stop - start + 1)
    -- if start is 3 and stop is 1, it would add 1 to count. That's why it's >= not just ==
    if count >= self.__count then
      -- removes nothing, just return
      return self
    end
    self.__count = count
    if count == 0 then
      self.__iter = function() end
      return self
    end

    local inner_iter = self.__iter
    local i = 1
    self.__iter = function()
      if i == start then
        if stop == count then
          -- don't even iterate the rest if it would skip the rest of the values anyway
          return
        end
        while i <= stop do
          i = i + 1
          inner_iter()
        end
      end
      i = i + 1
      return inner_iter()
    end
    return self
  end

  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    i = i + 1
    if i == start then
      while i <= stop do
        if inner_iter() == nil then
          -- stop could be far past the end of the sequence, so check if that's the case and early return
          return
        end
        i = i + 1
      end
    end
    return inner_iter()
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@generic T
---@param self LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:reverse()
  local values
  local values_index = 1
  local inner_iter = self.__iter
  self.__iter = function()
    if not values then
      values = {}
      for value in inner_iter do
        values[values_index] = value
        values_index = values_index + 1
      end
    end
    values_index = values_index - 1
    return values[values_index] -- if values_index is zero, it returns nil
  end
  return self
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

---@generic T
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@return boolean
function linq_meta_index:sequence_equal(collection)
  if collection.__is_linq then
    if self.__count and collection.__count and self.__count ~= collection.__count then
      return false
    end
    while true do
      local value = self.__iter()
      if value ~= collection.__iter() then
        return false
      end
      if value == nil then
        return true
      end
    end
  end

  local count = #collection
  if self.__count and self.__count ~= count then
    return false
  end
  for i = 1, count do
    if self.__iter() ~= collection[i] then
      return false
    end
  end
  -- if self.__count is not nil then we know both the count and all values are equal
  -- if the count is unknown then we must call the iterator one more time to check if it has reached the end
  return self.__count and true or self.__iter() == nil
end

---@generic T
---@param self LinqObj|T[]
---@param condition (fun(value: T, i: integer):boolean)?
---@return T
function linq_meta_index:single(condition)
  if condition then
    local result
    local i = 0
    for value in self.__iter do
      i = i + 1
      if condition(value, i) then
        if result == nil then
          result = value
        else
          error("Expected a single value in the sequence to match the condition, got multiple.")
        end
      end
    end
    if result == nil then
      error("Expected a single value in the sequence to match the condition, got zero.")
    end
    return result
  end

  if self.__count and self.__count ~= 1 then
    error("Expected a single value in the sequence, got "..self.__count..".")
  end
  local result = self.__iter()
  if not self.__count then
    if result == nil then
      error("Expected a single value in the sequence, got zero.")
    elseif self.__iter() ~= nil then
      error("Expected a single value in the sequence, got multiple.")
    end
  end
  return result
end

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param count integer
---@return LinqObj|T[]
function linq_meta_index:skip(count)
  if count == 0 then return self end
  if self.__count then
    self.__count = math.max(0, self.__count - count)
    if self.__count == 0 then
      self.__iter = function() end
      return self
    end
  end
  local inner_iter = self.__iter
  local done_skipping = false
  self.__iter = function()
    if not done_skipping then
      for _ = 1, count do
        inner_iter()
      end
      done_skipping = true
    end
    return inner_iter()
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param count integer
---@return LinqObj|T[]
function linq_meta_index:skip_last(count)
  if count == 0 then return self end
  local keep_count

  if self.__count then
    keep_count = math.max(0, self.__count - count)
    self.__count = keep_count
    if keep_count == 0 then
      self.__iter = function() end
      return self
    end

    -- if we know count then we also know when to stop, so no need to create a temporary table
    local inner_iter = self.__iter
    local i = 0
    self.__iter = function()
      if i >= keep_count then return end
      i = i + 1
      return inner_iter()
    end
    return self
  end

  local values
  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    if not values then
      values = {}
      local j = 0
      for value in inner_iter do
        j = j + 1
        values[j] = value
      end
      keep_count = j - count -- can result in a negative value, but it doesn't matter. see below if check
    end
    if i >= keep_count then return end
    i = i + 1
    return values[i]
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@generic T
---@param self LinqObj|T[]
---@param condition fun(value: T, i: integer): boolean
---@return LinqObj|T[]
function linq_meta_index:skip_last_while(condition)
  self.__count = nil
  local inner_iter = self.__iter
  local values
  local i = 0
  local keep_count = 0
  self.__iter = function()
    if not values then
      values = {}
      local count = 0
      for value in inner_iter do
        count = count + 1
        values[count] = value
      end
      for j = count, 1, -1 do
        if not condition(values[j], j) then
          keep_count = j
          break
        end
      end
    end
    if i >= keep_count then return end
    i = i + 1
    return values[i]
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param condition fun(value: T, i: integer): boolean
---@return LinqObj|T[]
function linq_meta_index:skip_while(condition)
  self.__count = nil
  local inner_iter = self.__iter
  local done_skipping = false
  self.__iter = function()
    if not done_skipping then
      done_skipping = true
      local i = 1
      local value
      while true do
        value = inner_iter()
        if value == nil then return end
        if not condition(value, i) then return value end
        i = i + 1
      end
    end
    return inner_iter()
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param comparator fun(left: T, right: T): boolean
---@return LinqObj|T[]
function linq_meta_index:sort(comparator)
  local values
  local inner_iter = self.__iter
  local i = 0
  self.__iter = function()
    if not values then
      values = {}
      local count = self.__count
      if count then
        for j = 1, count do
          values[j] = inner_iter()
        end
      else
        count = 0
        for value in inner_iter do
          count = count + 1
          values[count] = value
        end
      end
      table.sort(values, comparator)
    end
    i = i + 1
    return values[i]
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param selector (fun(value: T, index: integer): number)?
---@return number
function linq_meta_index:sum(selector)
  local result = 0
  if selector then
    if self.__count then
      local iter = self.__iter
      for i = 1, self.__count do
        result = result + selector(iter(), i)
      end
    else
      local i = 0
      for value in self.__iter do
        i = i + 1
        result = result + selector(value, i)
      end
    end
  else
    for value in self.__iter do
      result = result + value
    end
  end
  return result
end

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@param key_selector (fun(value: T): TKey)? @ no index, because it's used on both collections
---@return LinqObj|T[]
local function symmetric_difference_internal(self, collection, key_selector)
  self.__count = nil
  local outer_iter = self.__iter
  -- capture as upvalue in case collection gets modified, though nobody should do that anyway
  local inner_iter = collection.__iter
  local inner_i = 0
  local inner_count = 0
  local inner_lut
  local inner_list
  local inner_key_list
  local outer_lut
  local iterating_inner = false
  self.__iter = function()
    ::go_again::
    if iterating_inner then
      while true do
        if inner_i == inner_count then return end -- we're done
        inner_i = inner_i + 1
        local value = inner_list[inner_i]
        local key = value
        if key_selector then
          key = inner_key_list[inner_i]
        end
        if not outer_lut[key] then
          return value -- inner_list is already distinct
        end
      end
      -- loop is only exited through returns, this is unreachable
    end

    if not inner_lut then
      inner_lut = {}
      inner_list = {}
      if key_selector then
        inner_key_list = {}
      end
      if collection.__is_linq then
        for value in inner_iter do
          local key = value
          if key_selector then
            key = key_selector(value)
          end
          if inner_lut[key] then goto continue end -- make it distinct
          inner_count = inner_count + 1
          inner_list[inner_count] = value
          if key_selector then
            inner_key_list[inner_count] = key
          end
          inner_lut[key] = true
          ::continue::
        end
      else
        -- copy paste for optimization
        for i = 1, #collection do
          local value = collection[i]
          local key = value
          if key_selector then
            key = key_selector(value)
          end
          if inner_lut[key] then goto continue end -- make it distinct
          inner_count = inner_count + 1
          inner_list[inner_count] = value
          if key_selector then
            inner_key_list[inner_count] = key
          end
          inner_lut[key] = true
          ::continue::
        end
      end
    end

    outer_lut = outer_lut or {}
    while true do
      local value = outer_iter()
      if value == nil then
        iterating_inner = true
        goto go_again
      end
      local key = value
      if key_selector then
        key = key_selector(value)
      end
      if not outer_lut[key] then -- make it distinct
        -- add it to the outer_lut regardless of if it is in inner_lut,
        -- because when returning inner results it must also exclude these values
        outer_lut[key] = true
        if not inner_lut[key] then
          return value
        end
      end
    end
    -- loop is only exited through returns or a goto to top, this is unreachable
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:symmetric_difference(collection)
  return symmetric_difference_internal(self, collection)
end

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@param key_selector fun(value: T): TKey @ no index, because it's used on both collections
---@return LinqObj|T[]
function linq_meta_index:symmetric_difference_by(collection, key_selector)
  return symmetric_difference_internal(self, collection, key_selector)
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

---@diagnostic disable: duplicate-set-field
---@generic T
---@param self LinqObj|T[]
---@param count integer
---@return LinqObj|T[]
function linq_meta_index:take_last(count)
  if count == 0 then
    self.__iter = function() end
    self.__count = 0
    return self
  end

  if self.__count then
    -- really no need to reimplement this, so just call skip
    return self:skip(math.max(0, self.__count - count))
  end

  -- Using a queue like data structure because we know the maximum amount of values to iterate
  -- so only that amount of values need to be kept in a table.
  -- Reduces the amount of rehashes and total memory usage.
  local inner_iter = self.__iter
  local value_queue
  local queue_end
  local i = 0
  self.__iter = function()
    if not value_queue then
      value_queue = {}
      local actual_count = 0
      for value in inner_iter do
        value_queue[(actual_count % count) + 1] = value
        actual_count = actual_count + 1
      end
      queue_end = ((actual_count - 1) % count) + 1
      i = (math.max(0, actual_count - count) % count) + 1
      return value_queue[i]
    end
    if i == queue_end then return end
    i = (i % count) + 1
    return value_queue[i]
  end
  return self
end
---@diagnostic enable: duplicate-set-field

---@generic T
---@param self LinqObj|T[]
---@param condition fun(value: T, i: integer):boolean
---@return LinqObj|T[]
function linq_meta_index:take_last_while(condition)
  self.__count = nil
  local inner_iter = self.__iter
  local values
  local i = 0
  self.__iter = function()
    if not values then
      values = {}
      for value in inner_iter do
        i = i + 1
        values[i] = value
      end
      while i > 0 and condition(values[i], i) do
        i = i - 1
      end
    end
    i = i + 1
    return values[i]
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@param condition fun(value: T, i: integer):boolean
---@return LinqObj|T[]
function linq_meta_index:take_while(condition)
  self.__count = nil
  local inner_iter = self.__iter
  local i = 0
  local done = false
  self.__iter = function()
    if done then return end
    local value = inner_iter()
    i = i + 1
    if value == nil or not condition(value, i) then
      done = true
      return
    end
    return value
  end
  return self
end

---@generic T
---@param self LinqObj|T[]
---@return LinqObj|T[]
local function then_by_internal(self, next_ordering_definition)
  -- The comparison of the iter functions isn't perfect because some linq functions don't always
  -- replace the iterator for optimization reasons. However the check is better than nothing as it still has
  -- a good chance of catching mistakes during development.
  if not self.__ordering_definitions or self.__ordering_reference_iter ~= self.__iter then
    error("'then_by' and 'then_descending_by' must only be used directly after any of the \z
      'order' functions, or another 'then' function."
    )
  end
  -- see `order_internal` for the implementation
  self.__ordering_definitions[#self.__ordering_definitions+1] = next_ordering_definition
  return self
end

---@generic T
---@generic TValue
---@param self LinqObj|T[]
---@param selector fun(value: T):TValue
---@return LinqObj|T[]
function linq_meta_index:then_by(selector)
  return then_by_internal(self, {selector = selector, descending = false})
end

---@generic T
---@generic TValue
---@param self LinqObj|T[]
---@param selector fun(value: T):TValue
---@return LinqObj|T[]
function linq_meta_index:then_descending_by(selector)
  return then_by_internal(self, {selector = selector, descending = true})
end

---@generic T
---@param self LinqObj|T[]
---@return T[]
function linq_meta_index:to_array()
  local array = {}
  if self.__count then
    local iter = self.__iter
    for i = 1, self.__count do
      array[i] = iter()
    end
  else
    local i = 0
    for value in self.__iter do
      i = i + 1
      array[i] = value
    end
  end
  return array
end

---@generic T
---@generic TKey
---@generic TValue
---@param self LinqObj|T[]
---@param kvp_selector fun(value: T, i: integer): TKey, TValue
---@return table<TKey, TValue>
function linq_meta_index:to_dict(kvp_selector)
  local dict = {}
  if self.__count then
    local iter = self.__iter
    for i = 1, self.__count do
      local key, value = kvp_selector(iter(), i)
      dict[key] = value
    end
  else
    local i = 0
    for inner_value in self.__iter do
      i = i + 1
      local key, value = kvp_selector(inner_value, i)
      dict[key] = value
    end
  end
  return dict
end

---@generic T
---@param self LinqObj|T[]
---@param name string? @ (default: `nil`) the name used for next and prev keys.
---`nil` => `node.next` and `node.prev`\
---`"sibling"` => `node.next_sibling` and `node.prev_sibling`
---@param track_liveliness boolean? @ (default: `false`) `true` enables usage of `is_alive`
---@return {first: T?, last: T?}
function linq_meta_index:to_linked_list(name, track_liveliness)
  return ll.from_iterator(self.__iter, name, track_liveliness)
end

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param key_selector (fun(value: T, i: integer): TKey)?
---@return table<TKey, true>
function linq_meta_index:to_lookup(key_selector)
  local lookup = {}
  if self.__count then
    local iter = self.__iter
    for i = 1, self.__count do
      local key = iter()
      if key_selector then
        key = key_selector(key, i)
      end
      lookup[key] = true
    end
  else
    local i = 0
    for key in self.__iter do
      i = i + 1
      if key_selector then
        key = key_selector(key, i)
      end
      lookup[key] = true
    end
  end
  return lookup
end

---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@param key_selector (fun(value: T): TKey)? @ no index, because it's used on both collections
---@return LinqObj|T[]
local function union_internal(self, collection, key_selector)
  self.__count = nil
  local iter = self.__iter
  local iterating_collection = false
  local lut = {}
  local collection_is_linq = collection.__is_linq
  -- capture as upvalue in case collection gets modified, though nobody should do that anyway
  local collection_iter = collection.__iter
  local collection_index = 0
  self.__iter = function()
    ::entry::
    if iterating_collection then
      local value
      while true do
        if collection_is_linq then
          value = collection_iter()
        else
          collection_index = collection_index + 1
          value = collection[collection_index]
        end
        if value == nil then return end
        local key = value
        if key_selector then
          key = key_selector(value)
        end
        if not lut[key] then
          lut[key] = true
          return value
        end
      end
    else
      while true do
        local value = iter()
        if value == nil then
          iterating_collection = true
          goto entry
        end
        local key = value
        if key_selector then
          key = key_selector(value)
        end
        if not lut[key] then
          lut[key] = true
          return value
        end
      end
    end
  end
  return self
end

---Results are distinct.
---@generic T
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@return LinqObj|T[]
function linq_meta_index:union(collection)
  return union_internal(self, collection)
end

---Results are distinct. If 2 different values select the same key, only the first one will be in the output.
---`self` first, then `collection`.
---@generic T
---@generic TKey
---@param self LinqObj|T[]
---@param collection LinqObj|T[]
---@param key_selector fun(value: T): TKey @ no index, because it's used on both collections
---@return LinqObj|T[]
function linq_meta_index:union_by(collection, key_selector)
  return union_internal(self, collection, key_selector)
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
---@param tab_or_iter T[]|fun(state: TState, key: T?):(T?) @ an array or an iterator returning a single value
---@param state TState? @ used if this is an iterator
---@param starting_value T? @ used if this is an iterator
---@return LinqObj|T[]
local function linq(tab_or_iter, state, starting_value)
  if type(tab_or_iter) == "table" then
    local count = #tab_or_iter
    return setmetatable({
      __is_linq = true,
      __iter = make_array_iter(tab_or_iter, count),
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
