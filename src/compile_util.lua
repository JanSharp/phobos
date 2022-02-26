
---@type LFS
local lfs = require("lfs")
local error_code_util = require("error_code_util")
local parser = require("parser")
local jump_linker = require("jump_linker")
local fold_const = require("optimize.fold_const")
local fold_control_statements = require("optimize.fold_control_statements")
local compiler = require("compiler")
local dump = require("dump")
local constants = require("constants")

local io_util = require("io_util")

local function get_source_name(file_data)
  return file_data.text and file_data.text_source or file_data.source_name:gsub("%?", file_data.filename)
end

---@return CompileUtilContext
local function new_context()
  return {
    syntax_error_count = 0,
    files_with_syntax_error_count = 0,
  }
end

---@class CompileUtilFileData
---@field filename string
---@field text string
---@field text_source string
---@field source_name string @ `?` is a placeholder for `filename`
---@field accept_bytecode boolean
---@field inject_scripts fun(ast:AstFunctionDef)[]
---@field ignore_syntax_errors boolean
---@field no_syntax_error_messages boolean
---@field use_load boolean

---@class CompilerOptions
---@field optimizations table<string, boolean>

---@class CompileUtilContext
---@field syntax_error_count integer
---@field files_with_syntax_error_count integer

---@param file_data CompileUtilFileData
---@param compiler_options CompilerOptions
---@param context CompileUtilContext
---@return string? loadable_chunk @ bytecode or a string using `load()`. Depends on `use_load`
local function compile(file_data, compiler_options, context)
  local function check_and_print_errors(errors)
    if errors[1] then
      context.syntax_error_count = context.syntax_error_count + #errors
      context.files_with_syntax_error_count = context.files_with_syntax_error_count + 1
      local msg = error_code_util.get_message_for_list(errors, "syntax errors in "
        ..(file_data.text and file_data.text_source or file_data.filename)
      )
      if file_data.ignore_syntax_errors then
        if not file_data.no_syntax_error_messages then
          print(msg)
        end
        return true
      else
        error(msg)
      end
    end
  end

  local text = file_data.text or io_util.read_file(file_data.filename)
  if file_data.accept_bytecode and text:sub(1, 4) == constants.lua_signature_str then
    return text
  end
  local ast, parser_errors = parser(text, get_source_name(file_data))
  if check_and_print_errors(parser_errors) then
    return nil
  end
  local jump_linker_errors = jump_linker(ast)
  if check_and_print_errors(jump_linker_errors) then
    return nil
  end
  if file_data.inject_scripts then
    for _, inject_script in ipairs(file_data.inject_scripts) do
      inject_script(ast)
    end
  end
  if compiler_options.optimizations then
    if compiler_options.optimizations.fold_const then
      fold_const(ast)
    end
    if compiler_options.optimizations.fold_control_statements then
      fold_control_statements(ast)
    end
  end
  local compiled = compiler(ast, compiler_options)
  local bytecode = dump(compiled)
  if file_data.use_load then
    return string.format("local main_chunk=assert(load(%q,nil,'b'))\nreturn main_chunk(...)", bytecode)
  else
    return bytecode
  end
end

return {
  new_context = new_context,
  compile = compile,
}
