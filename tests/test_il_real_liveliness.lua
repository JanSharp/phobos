
local framework = require("test_framework")
local assert = require("assert")

local parser = require("parser")
local jump_linker = require("jump_linker")
local il_generator = require("il_generator")
local il = require("il_util")
local il_blocks = require("il_blocks")
local ill = require("indexed_linked_list")
local util = require("util")
local il_pretty_print = require("il_pretty_print")

local il_real_liveliness = require("il_real_liveliness")

-- TODO: Add proper support for extra output to the test runner, or something.
local output_pretty_printed = false

---@param parent_func ILFunction?
---@return ILFunction
---@return ILRet
local function new_il_func(parent_func)
  ---@type ILFunction
  local il_func = {
    parent_func = parent_func,
    inner_functions = {},
    instructions = ill.new(),
    upvals = {},
    param_regs = {},
    is_vararg = false,
    source = "=(test)",
    defined_position = util.new_pos(0, 0),
    last_defined_position = util.new_pos(0, 0),

    has_blocks = false,
    has_borders = false,
    has_reg_liveliness = false,
    has_real_reg_liveliness = false,
    has_types = false,
    is_compiling = false,
  }
  local ret = il.append_inst(il_func, il.new_ret{})
  if parent_func then
    parent_func.inner_functions[#parent_func.inner_functions+1] = il_func
  end
  return il_func, ret
end

---@generic T : ILInstruction
---@param il_func ILFunction
---@param inst T
---@return T
local function add(il_func, inst)
  return il.insert_before_inst(il_func, il_func.instructions.last, inst)
end

---@param il_func ILFunction
---@param index integer
local function get_inst(il_func, index)
  local i = 1
  local inst = il_func.instructions.first
  while i < index do
    inst = util.debug_assert(inst.next, "Trying to get inst #"..index.." when there is only "..i)
    i = i + 1
  end
  return inst
end

---@param source_code string
---@return ILFunction
local function get_il(source_code)
  local ast = parser(source_code, "=(test)")
  jump_linker(ast)
  local il_func = il_generator(ast)
  return il_func
end

---@param il_func ILFunction
local function run(il_func)
  il_real_liveliness.create_real_reg_liveliness_recursive(il_func)
end

local il_instruction_line_format = util.parse_interpolated_string(
  "{line:%3d} {column:%3d} IL1: {func_id:%3d}f  {pc:%4d}  {index:%4d}  \z
    {label:%-8s}  {block_id}  {description:%-26s}  {real_live_regs}"
) -- Add "[ {group_label:%-8s} ] " before "{label:%-8s}" if seeing instruction groups is desired.

do
  local main_scope = framework.scope:new_scope("il_real_liveliness")

  ---@param name string
  ---@param func fun(): string|ILFunction, fun(func: ILFunction)
  local function add_test(name, func)
    if output_pretty_printed then
      main_scope:add_test(name.." (pretty printed)", function()
        local il_func = func()
        if type(il_func) == "string" then
          il_func = get_il(il_func)
        end
        il.create_blocks_recursive(il_func)
        run(il_func)
        local block_ids = {}
        local next_block_id = 0
        error("\n"..il_pretty_print(il_func, function(data)
          data.line = data.inst.position and data.inst.position.line or 0
          data.column = data.inst.position and data.inst.position.column or 0
          data.func_id = 1--il_func_id
          local block_id = block_ids[data.inst.block]
          if not block_id then
            block_id = next_block_id
            next_block_id = next_block_id + 1
            block_ids[data.inst.block] = block_id
          end
          data.block_id = block_id
          if data.real_live_regs ~= "" then
            data.real_live_regs = "live: "..data.real_live_regs
          end
          return util.format_interpolated(il_instruction_line_format, data)
        end):sub(1, -2))
      end)
    end

    main_scope:add_test(name, function()
      local il_func, validate_result = func()
      if type(il_func) == "string" then
        il_func = get_il(il_func)
      end
      run(il_func)
      validate_result(il_func)
    end)

    main_scope:add_test(name.." (has valid set_insts)", function()
      local il_func = func()
      if type(il_func) == "string" then
        il_func = get_il(il_func)
      end
      run(il_func)

      local block = il_func.blocks.first
      ---@param checkpoint ILExecutionCheckpoint
      local function assert_set_insts(checkpoint)
        for _, live_range in ipairs(checkpoint.real_live_regs) do
          if live_range.is_param then
            assert.equals(nil, live_range.set_insts, "set_insts when is_param")
          else
            assert.not_equals(nil, live_range.set_insts, "set_insts when not is_param")
            assert.not_equals(nil, live_range.set_insts[1], "set_insts[1] when not is_param")
          end
        end
      end
      while block do
        for inst in il_blocks.iterate(il_func, block) do
          if inst ~= block.start_inst then
            assert_set_insts(inst.prev_border)
          end
        end
        if block.straight_link then
          assert_set_insts(block.straight_link)
        end
        if block.jump_link then
          assert_set_insts(block.jump_link)
        end
        block = block.next
      end
    end)
  end

  add_test("simple", function()
    local func, ret = new_il_func()
    local foo_reg = il.new_reg("foo")
    local move = add(func, il.new_move{result_reg = foo_reg, right_ptr = il.new_string("hello world")})
    ret.ptrs[1] = foo_reg
    return func, function()
      assert(move.next_border.real_live_regs[1])
      assert.equals(nil, move.next_border.real_live_regs[1].is_param)
      assert.equals(foo_reg, move.next_border.real_live_regs[1].reg)
      assert.equals(move, move.next_border.real_live_regs[1].set_insts[1])
    end
  end)

  add_test("Multiple set_insts for one live reg range", function()
    return [[
      local foo
      if true then
        foo = 100
      else
        foo = 200
      end
      return foo
    ]], function(func)
      local reg_range = get_inst(func, 7).next_border.real_live_regs[1]
      assert.not_equals(nil, reg_range.set_insts[1], "set_insts[1]")
      assert.not_equals(nil, reg_range.set_insts[2], "set_insts[2]")
      assert.equals(nil, reg_range.set_insts[3], "set_insts[3]")
      assert.not_equals(reg_range.set_insts[1], reg_range.set_insts[2], "set_insts[1] ~= set_insts[2]")
    end
  end)

  add_test("Continuous live range through links for loop blocks", function()
    return [[
      local foo = 100
      while true do
        local bar = foo
        foo = 200
      end
    ]], function(func)
      local live_range
      ---@param checkpoint ILExecutionCheckpoint
      local function assert_same(checkpoint)
        if not live_range then
          live_range = assert(checkpoint.real_live_regs[1])
          return
        end
        assert.equals(live_range, checkpoint.real_live_regs[1])
      end
      assert_same(get_inst(func, 1).block.straight_link)
      assert_same(get_inst(func, 2).next_border)
      assert_same(get_inst(func, 3).block.straight_link)
      assert_same(get_inst(func, 5).next_border)
      assert_same(get_inst(func, 6).block.jump_link)
    end
  end)
end
