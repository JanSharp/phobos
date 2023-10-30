
--------------------------------------------------
-- general stuff:

---@class Position
---@field line integer?
---@field column integer?
---@field index nil @ -- TODO: maybe do add the index to all AstTokenNodes

---@class Options
---- tokenizer.lua: should numbers be parsed as signed int32 or doubles?
---- parser.lua: pass it along to the tokenizer
---- optimize/fold_const.lua: throw not supported error, because emulating an int32 machine is difficult
---- il_generator.lua: throw not supported error
---- dump.lua: should the int32 signature be used, size_t be uint32 and Lua numbers be signed int32?
---@field use_int32 boolean?
---checked in several different parts during compilation
---@field optimizations Optimizations

--------------------------------------------------
-- tokens stuff:

---@alias TokenType
---| "blank"
---| "comment"
---| "string"
---| "number"
---| "ident" @ identifier
---| "eof" @ not created in the tokenizer, but created and used by the parser
---| "invalid"
---
---| "+"
---| "*"
---| "/"
---| "%"
---| "^"
---| "#"
---| ";"
---| ","
---| "("
---| ")"
---| "{"
---| "}"
---| "]"
---| "["
---| "<"
---| "<="
---| "="
---| "=="
---| ">"
---| ">="
---| "-"
---| "~="
---| "::"
---| ":"
---| "..."
---| ".."
---| "."
---keywords:
---| "and"
---| "break"
---| "do"
---| "else"
---| "elseif"
---| "end"
---| "false"
---| "for"
---| "function"
---| "if"
---| "in"
---| "local"
---| "nil"
---| "not"
---| "or"
---| "repeat"
---| "return"
---| "then"
---| "true"
---| "until"
---| "while"
---| "goto"

---@class AstTokenParams : Position
---@field token_type TokenType
---for `blank`, `comment`, `string`, `number`, `ident` and `invalid` tokens\
---"blank" tokens shall never contain `\n` in the middle of their value\
---"comment" tokens with `not src_is_block_str` do not contain trailing `\n`
---@field value string|number
---@field src_is_block_str boolean @ for `string` and `comment` tokens
---@field src_quote string @ for non block `string` tokens
---@field src_value string @ for non block `string` and `number` tokens
---@field src_has_leading_newline boolean @ for block `string` and `comment` tokens
---@field src_pad string @ the `=` chain for block `string` and `comment` tokens
---@field leading Token[] @ `blank` and `comment` tokens before this token. Set and used by the parser
---for `invalid` tokens
---@field error_code_insts ErrorCodeInstance[]

---@class Token : AstTokenParams
---@field index integer

--------------------------------------------------
-- ast stuff:

---@alias AstNodeType
---special:
---| "env_scope"
---| "functiondef"
---| "token"
---| "invalid"
---statements:
---| "empty"
---| "ifstat"
---| "testblock"
---| "elseblock"
---| "whilestat"
---| "dostat"
---| "fornum"
---| "forlist"
---| "repeatstat"
---| "funcstat"
---| "localstat"
---| "localfunc"
---| "label"
---| "retstat"
---| "breakstat"
---| "gotostat"
---| "call" @ expression or statement
---| "assignment"
---expressions:
---| "local_ref"
---| "upval_ref"
---| "index"
---| "unop"
---| "binop"
---| "concat"
---| "number"
---| "string"
---| "nil"
---| "boolean"
---| "vararg"
---| "func_proto"
---| "constructor"
---optimizer statements:
---| "inline_iife_retstat" @ inline immediately invoked function expression return statement
---| "loopstat"
---optimizer expressions:
---| "inline_iife" @ inline immediately invoked function expression

---line, column and leading is only used for some node types that represent a single token\
---each ose these nodes have a comment noting this\
---however even those those these value are optional,
---them being omitted means stripped/missing debug info\
---it should also be expected that only some of them could be `nil`
---@class AstNode : Position
---@field node_type AstNodeType
---@field leading Token[]|nil @ `"blank"` and `"comment"` tokens

---uses line, column and leading\
---purely describing the syntax
---@class AstTokenNode : AstNode, Token
---@field node_type "token"
---@field index nil @ overridden to `nil`

---the location of the error is defined in the ErrorCodeInstance\
---indicates a syntax error
---@class AstInvalidNode : AstNode
---@field node_type "invalid"
---@field error_code_inst ErrorCodeInstance
---nodes that ended up being unused due to this syntax error\
---99% of the time these are AstTokenNodes, however for unexpected_expression they
---can be any expression
---@field consumed_nodes AstNode[]|nil

---@class AstStatement : AstNode, ILLNode<AstStatement>
---@field list AstStatementList @ (overridden) back reference
---@field prev AstStatement? @ (overridden) `nil` if this is the first node
---@field next AstStatement? @ (overridden) `nil` if this is the last node

---@class AstParenWrapper
---@field open_paren_token AstTokenNode
---@field close_paren_token AstTokenNode

---@class AstExpression : AstNode
---should the expression be forced to evaluate to only one result
---caused by the expression being wrapped in `()`
---@field force_single_result boolean|nil
---similar to index expressions, the last one to close/most right one is
---the first one in the list/first one you encounter when processing the data
---@field src_paren_wrappers AstParenWrapper[]|nil

---@class AstStatementList : IntrusiveIndexedLinkedList<AstStatement>
---@field scope AstScope
---@field first AstStatement? @ (overridden)
---@field last AstStatement? @ (overridden)

---@class AstScope : AstNode
---@field parent_scope AstScope @ `nil` for AstENVScope (very top level)
---@field child_scopes AstScope[]
---@field body AstStatementList
---@field locals AstLocalDef[]
---@field labels AstLabel[]

---@class AstFunctionDef : AstScope, AstNode
---@field node_type "functiondef"
---@field is_main nil @ overridden by AstMain to be `true`
---@field source string
---is it `function foo:bar() end`?\
---`self` does not get added to `params`, but it does get a `whole_block = true` local,
---which is always the first one
---@field is_method boolean
---@field func_protos AstFunctionDef[]
---@field upvals AstUpvalDef[]
---@field is_vararg boolean
---@field vararg_token AstTokenNode|nil @ used when `is_vararg == true`
---all parameters are `whole_block = true` locals, except vararg
---@field params AstLocalReference[]
---@field param_comma_tokens AstTokenNode[] @ max length is `#params - 1`, min `0`
---@field open_paren_token AstTokenNode
---@field close_paren_token AstTokenNode
---@field function_token AstTokenNode @ position for any `closure` instructions
---@field end_token AstTokenNode
---@field eof_token nil @ overridden by AstMain to be an AstTokenNode

---@class AstFuncBase : AstNode
---@field func_def AstFunctionDef



---@class AstEmpty : AstStatement
---@field node_type "empty"
---@field semi_colon_token AstTokenNode

---@class AstIfStat : AstStatement
---@field node_type "ifstat"
---@field ifs AstTestBlock[]
---@field elseblock AstElseBlock|nil
---@field end_token AstTokenNode

---@class AstTestBlock : AstScope
---@field node_type "testblock"
---@field condition AstExpression
---@field if_token AstTokenNode @ for the first test block this is an `if` node_type, otherwise `elseif`
---@field then_token AstTokenNode @ position for the failure `jup` instruction

---@class AstElseBlock : AstScope
---@field node_type "elseblock"
---@field else_token AstTokenNode

---@class AstLoop
---evaluated by the jump linker. not `nil` after successful linking,
---**but only if there are any `break`s that linked to this loop**
---@field linked_breaks AstBreakStat[]|nil

---@class AstWhileStat : AstStatement, AstScope, AstLoop
---@field node_type "whilestat"
---@field condition AstExpression
---@field while_token AstTokenNode
---@field do_token AstTokenNode @ position for the failure `jmp` instruction
---@field end_token AstTokenNode @ position for the loop `jmp` instruction

---@class AstDoStat : AstStatement, AstScope
---@field node_type "dostat"
---@field do_token AstTokenNode
---@field end_token AstTokenNode

---@class AstForNum : AstStatement, AstScope, AstLoop
---@field node_type "fornum"
---`var` is referring to a `whole_block = true` local
---@field var AstLocalReference
---@field start AstExpression
---@field stop AstExpression
---@field step AstExpression|nil
---`var` is referring to a `whole_block = true` local
---@field for_token AstTokenNode @ position for the `forloop` instruction
---@field eq_token AstTokenNode
---@field first_comma_token AstTokenNode
---@field second_comma_token AstTokenNode|nil @ only used when `step` is not `nil`
---@field do_token AstTokenNode @ position for the `forprep` instruction
---@field end_token AstTokenNode

---@class AstForList : AstStatement, AstScope, AstLoop
---@field node_type "forlist"
---@field name_list AstLocalReference[]
---@field exp_list AstExpression[]
---@field exp_list_comma_tokens AstTokenNode[]
---all `name_list` names are used for a `whole_block = true` local
---@field for_token AstTokenNode @ position for the `tforcall` and `tforloop` instructions
---@field comma_tokens AstTokenNode[] @ max length is `#name_list - 1`
---@field in_token AstTokenNode
---@field do_token AstTokenNode @ position for the `jmp` to `tforcall` instruction
---@field end_token AstTokenNode

---@class AstRepeatStat : AstStatement, AstScope, AstLoop
---@field node_type "repeatstat"
---@field condition AstExpression
---@field repeat_token AstTokenNode
---@field until_token AstTokenNode @ position for the loop `jmp` instruction

---@class AstFuncStat : AstStatement, AstFuncBase
---@field node_type "funcstat"
---@field name AstExpression

---@class AstLocalFunc : AstStatement, AstFuncBase
---@field node_type "localfunc"
---@field name AstLocalReference
---@field local_token AstTokenNode

---@class AstLocalStat : AstStatement
---@field node_type "localstat"
---@field lhs AstLocalReference[]
---@field rhs AstExpression[]|nil @ `nil` = no assignment
---@field local_token AstTokenNode
---@field lhs_comma_tokens AstTokenNode[] @ max length is `#lhs - 1`
---@field rhs_comma_tokens AstTokenNode[]|nil @ `nil` when `rhs` is `nil`. max length is `#rhs - 1`
---@field eq_token AstTokenNode|nil @ only used if `rhs` is not `nil`

---@class AstLabel : AstStatement
---@field node_type "label"
---@field name string
---@field name_token AstTokenNode @ its value is `nil`
---@field open_token AstTokenNode @ opening `::`
---@field close_token AstTokenNode @ closing `::`
---@field linked_gotos AstGotoStat[]|nil @ evaluated by the jump linker. not `nil` after successful linking

---@class AstRetStat : AstStatement
---@field node_type "retstat"
---@field exp_list AstExpression[]|nil @ `nil` = no return values
---@field return_token AstTokenNode @ position for the `return` instruction
---@field exp_list_comma_tokens AstTokenNode[]
---@field semi_colon_token AstTokenNode|nil @ trailing `;`. `nil` = no semi colon

---@class AstBreakStat : AstStatement
---@field node_type "breakstat"
---@field break_token AstTokenNode @ position for the break `jmp` instruction
---@field linked_loop AstLoop[]|nil @ evaluated by the jump linker. not `nil` after successful linking

---@class AstGotoStat : AstStatement
---@field node_type "gotostat"
---@field target_name string @ name of the label to jump to
---@field target_token AstTokenNode @ its value is `nil`
---@field goto_token AstTokenNode @ position for the goto `jmp` instruction
---@field linked_label AstLabel|nil @ evaluated by the jump linker. not `nil` after successful linking

---@class AstCall : AstStatement, AstExpression
---@field node_type "call"
---@field is_selfcall boolean
---@field ex AstExpression
---only used if `is_selfcall == true`\
---function name. `src_is_ident` is always `true`
---@field suffix AstString
---@field args AstExpression[]
---@field args_comma_tokens AstTokenNode[]
---@field colon_token AstTokenNode @ position for the `self` instruction
---@field open_paren_token AstTokenNode|nil @ position for the `call` instruction
---@field close_paren_token AstTokenNode|nil @ position for `move` instructions moving out of temp regs

---@class AstAssignment : AstStatement
---@field node_type "assignment"
---@field lhs AstExpression[]
---@field rhs AstExpression[]
---@field lhs_comma_tokens AstTokenNode[]
---@field eq_token AstTokenNode
---@field rhs_comma_tokens AstTokenNode[]



---@class AstInlineIIFERetstat : AstStatement
---@field node_type "inline_iife_retstat"
---@field return_token AstTokenNode
---@field exp_list AstExpression[]|nil @ `nil` = no return values
---@field exp_list_comma_tokens AstTokenNode[]
---@field semi_colon_token AstTokenNode|nil @ trailing `;`. `nil` = no semi colon
---@field linked_inline_iife AstInlineIIFE
---@field leave_block_goto AstGotoStat

---@class AstLoopStat : AstStatement, AstScope, AstLoop
---@field node_type "loopstat"
---@field do_jump_back boolean|nil @ when false behaves like a dostat, except breakstat can link to this
---@field open_token AstTokenNode
---@field close_token AstTokenNode @ position for the loop `jmp` instruction



---uses line, column and leading
---@class AstLocalReference : AstExpression
---@field node_type "local_ref"
---@field name string
---@field reference_def AstLocalDef

---uses line, column and leading
---@class AstUpvalReference : AstExpression
---@field node_type "upval_ref"
---@field name string
---@field reference_def AstUpvalDef

---@class AstIndex : AstExpression
---@field node_type "index"
---@field ex AstExpression
---if this is an AstString with `src_is_ident == true`
---then it is representing a literal identifier
---@field suffix AstExpression
---Only used if it is a literal identifier\
---position for index related instructions
---@field dot_token AstTokenNode|nil
---`[` node_type if it is not a literal identifier
---@field suffix_open_token AstTokenNode|nil
---`]` node_type if it is not a literal identifier
---@field suffix_close_token AstTokenNode|nil
---if this is an index into `_ENV` where `_ENV.` did not exist in source
---@field src_ex_did_not_exist boolean|nil

---uses line, column and leading
---@class AstString : AstExpression
---@field node_type "string"
---@field value string
---if it was just an identifier in source.\
---Used in record field keys for table constructors\
---And when indexing with literal identifiers\
---Always `true` for AstCall `suffix` (where `is_selfcall == true`)
---@field src_is_ident boolean|nil
---used when `src_is_ident` is falsy
---@field src_is_block_str boolean|nil
---@field src_quote string|nil @ for non block strings
---@field src_value string|nil @ for non block strings
---@field src_has_leading_newline boolean|nil @ for block strings
---@field src_pad string|nil @ the `=` chain for block strings

---@alias AstUnOpOp "not"|"-"|"#"

---@class AstUnOp : AstExpression
---@field node_type "unop"
---@field op AstUnOpOp
---@field ex AstExpression
---@field op_token AstTokenNode @ position for the various unop instructions

---@alias ILBinOpOpBase "^"|"*"|"/"|"%"|"+"|"-"|"=="|"<"|"<="|"~="|">"|">="
---@alias AstBinOpOp ILBinOpOpBase|"and"|"or"

---@class AstBinOp : AstExpression
---@field node_type "binop"
---@field op AstBinOpOp
---@field left AstExpression
---@field right AstExpression
---@field op_token AstTokenNode @ position for the various binop instructions

---@class AstConcat : AstExpression
---@field node_type "concat"
---@field exp_list AstExpression[]
---max length is `#exp_list - 1`\
---first one is position for the `concat` instruction
---@field op_tokens AstTokenNode[]
---replaced by `concat_src_paren_wrappers`
---@field src_paren_wrappers nil
---replaces `src_paren_wrappers`. Think of each element in the main array
---containing the paren wrappers for the expression at that index.
---The `open_paren_token` comes before that expression, the `close_paren_token`
---comes after the very last expression.\
---For that reason this array will always be 1 shorter than the `exp_list`,
---since the wrappers around the last expression are handled by its own
---`src_paren_wrappers`.\
---a concat node is right associative, which means no paren wrapper can close
---any earlier than after the last expression. That means an expression like
---`(foo..bar)..baz` results in 2 concat nodes, while `foo..(bar..baz)` results in 1
---@field concat_src_paren_wrappers AstParenWrapper[][]

---uses line, column and leading
---@class AstNumber : AstExpression
---@field node_type "number"
---@field value number
---@field src_value string

---uses line, column and leading
---@class AstNil : AstExpression
---@field node_type "nil"

---uses line, column and leading
---@class AstBoolean : AstExpression
---@field node_type "boolean"
---@field value boolean

---uses line, column and leading
---@class AstVarArg : AstExpression
---@field node_type "vararg"

---@class AstFuncProto : AstExpression, AstFuncBase
---@field node_type "func_proto"

---@class AstField
---@field type "rec"|"list"

---@class AstRecordField : AstField
---@field type "rec"
---to represent a literal identifier this is
---a string expression with `src_is_ident == true`
---@field key AstExpression
---@field value AstExpression
---@field key_open_token AstTokenNode|nil @ `[` node_type if the key is using it
---@field key_close_token AstTokenNode|nil @ `]` node_type if the key is using it
---@field eq_token AstTokenNode @ position for the `settable` instruction

---@class AstListField : AstField
---@field type "list"
---@field value AstExpression

---@class AstConstructor : AstExpression
---@field node_type "constructor"
---@field fields AstField[]
---@field open_token AstTokenNode @ position for the `newtable` instruction
---`,` or `;` tokens, max length is `#fields`\
---position for `setlist` instructions if they are in the middle of the table constructor\
---(so the ones created because of fields per flush being reached)\
---also position for `call` instructions for calls without `open_paren_token`
---@field comma_tokens AstTokenNode[]
---position for `setlist` instructions if they are the last one\
---(so the ones not created because of fields per flush being reached)\
---also position for `move` instructions out of temp regs for calls without `close_paren_token`
---@field close_token AstTokenNode



---@class AstInlineIIFE : AstExpression, AstScope
---@field node_type "inline_iife"
---@field leave_block_label AstLabel
---@field linked_inline_iife_retstats AstInlineIIFERetstat[]



---@class AstUpvalDef
---@field def_type "upval"
---@field name string
---@field scope AstScope
---@field parent_def AstUpvalDef|AstLocalDef
---@field child_defs AstUpvalDef[]
---@field refs AstUpvalReference[] @ all upval references referring to this upval

---@class AstLocalDef
---@field def_type "local"
---@field name string
---@field scope AstScope
---i think this means it is defined at the start of
---the block and lasts for the entire block
---@field whole_block boolean?
---@field start_at AstStatement?
---@field start_offset (0|1)? @ `0` for "start before/at", `1` for "start after"
---@field child_defs AstUpvalDef[]
---@field refs AstLocalReference[] @ all local references referring to this local
---when true this did not exist in source, but
---was added because methods implicitly have the `self` parameter
---@field src_is_method_self boolean?

---NOTE: inheriting AstScope even though AstFunctionDef already inherits it [...]
---because sumneko.lua `3.4.2` otherwise thinks AstMain isn't an AstScope
---@class AstMain : AstFunctionDef, AstStatement, AstScope
---@field parent_scope AstENVScope
---@field is_main true
---@field is_method false
---@field line 0
---@field column 0
---@field end_line 0
---@field end_column 0
---@field is_vararg true
---if the first character of the parsed string is `#` then this contains
---the first line terminated by `\n` exclusive, but inclusive `#`
---@field shebang_line string|nil
---@field eof_token AstTokenNode @ to store trailing blank and comment tokens

---@class AstENVScope : AstScope
---@field node_type "env_scope"
---@field parent_scope nil @ overridden
---@field main AstMain
---@field body AstStatementList @ always empty
---@field locals AstLocalDef[] @ always exactly 1 `whole_block = true` local with the name `_ENV`
---@field labels AstLabel[] @ always empty

--------------------------------------------------
-- intermediate language:

---these are totally valid:
---- only containing one group
---- purely containing registers which require moves (all of their `index_in_linked_groups` is `nil`)
---@class ILLinkedRegisterGroupsGroup
---@field groups_lut table<ILRegisterGroup, true>
---@field groups ILRegisterGroup[] @ sorted by `group.inst.index` ascending
-- ---@field forced_offsets ILLinkedRegisterGroup.ForcedOffsets[]
---
---Evaluated in the step after best register indexes within the linked groups have been determined
---@field predetermined_base_index integer @ zero based

---This data structure is created right before compilation as it is only needed during compilation
---@class ILRegisterGroup
---@field linked_groups ILLinkedRegisterGroupsGroup
---@field inst ILInstruction
---@field regs ILRegister[]
---@field is_input boolean @ `false` means "is output"
---the index for the first register in the `regs` array, once it has been determined
-- ---@field first_reg_index integer?
---@field offset_to_next_group integer?
---
---Temporary during determination of best index offsets
---@field offset_to_prev_group integer?
---@field prev_group ILRegisterGroup?
---@field next_group ILRegisterGroup?
---
---Temporary during insertion of move instructions
---@field replaced_regs ({index: integer, old_reg: ILRegister}[])?
---@field replaced_regs_lut table<integer, ILRegister>?
---
---Set when/after best register indexes have been determined
---@field index_in_linked_groups integer @ zero based

---@alias ILPointerType
---| "reg"
---| "number"
---| "string"
---| "boolean"
---| "nil"

---@class ILPointer
---@field ptr_type ILPointerType

---@class ILRegister : ILPointer
---@field ptr_type "reg"
---@field name string|nil
---`requires_move_into_register_group` is always true for param regs because
---parameters can never be used in place in reg groups
---@field is_parameter boolean
---@field requires_move_into_register_group boolean
---@field is_vararg boolean
---@field is_gap boolean? @ indicates a gap in register lists
---@field is_internal boolean? @ registers purely internal inside of instruction groups
---@field captured_as_upval boolean?
---post IL generation data
---@field start_at ILInstruction
---@field stop_at ILInstruction
---@field prev_reg_in_func ILRegister?
---@field next_reg_in_func ILRegister?
---@field current_reg ILCompiledRegister
---temp compilation data
---@field reg_groups ILRegisterGroup[]?
---zero based\
---when not `nil` then there's at least 1 register group this register must not be moved into/has a fixed index
---@field index_in_linked_groups integer?
---@field predetermined_reg_index integer @ zero based
---@field instantly_stop_again boolean? @ temporary flag for regs which start and stop at the same instruction

---@class ILVarargRegister : ILRegister
---@field name nil
---@field is_vararg true

---@class ILNumber : ILPointer
---@field ptr_type "number"
---@field value number

---@class ILString : ILPointer
---@field ptr_type "string"
---@field value string

---@class ILBoolean : ILPointer
---@field ptr_type "boolean"
---@field value boolean

---@class ILNil : ILPointer
---@field ptr_type "nil"

---@class ILUpval
---@field name string|nil
---@field parent_type "upval"|"local"|"env"
---@field parent_upval ILUpval|nil @ used if `parent_type == "upval"`
---@field reg_in_parent_func ILRegister|nil @ used if `parent_type == "local"`
---@field child_upvals ILUpval[]
---temp compilation data
---@field upval_index integer @ **zero based** needed for instructions using upvals

---technically most `ILPosition`s are tokens and therefore most of them have `leading` but it's not used atm
---@alias ILPosition Position

---@alias ILTypeFlags
---| 1 @ nil
---| 2 @ boolean
---| 4 @ number
---| 8 @ string
---| 16 @ function
---| 32 @ table
---| 64 @ userdata
---| 128 @ thread

---TODO: add some way to represent `NaN`
---@class ILType
---@field type_flags ILTypeFlags @ bit field
---bit field. Will never contain `table`. `userdata` only affects `light_userdata_prototypes`
---@field inferred_flags ILTypeFlags
---@field number_ranges ILTypeNumberRanges? @ -- TODO: make ranges non nullable when the flag is set
---@field string_ranges ILTypeNumberRanges? @ restriction on strings, like tostring-ed numbers
---@field string_values string[]? @ nil means no restriction - any string
---@field boolean_value boolean?
---@field function_prototypes ILFunction[]?
---TODO: this being `nil` means "any identity", which means an empty type actually requires an empty array.
---I'm pretty sure this is handled incorrectly for most type operations
---@field identities ILTypeIdentity[]?
---@field table_classes ILClass[]? @ union of classes
---@field userdata_classes ILClass[]? @ union of classes with metatables for full userdata objects
---@field light_userdata_prototypes string[]? @ named light userdata to make it comparable

-- TODO: what do threads even look like and what data do I need to represent a group of them?

---@class ILClass
---@field kvps ILClassKvp[]? @ `nil` if this class is for a (full) userdata object
---@field metatable ILClass?
---@field inferred boolean?

---@class ILClassKvp
---@field key_type ILType
---@field value_type ILType

---@alias ILTypeNumberRangePointType
---| 0 @ nothing
---| 1 @ everything
---| 2 @ integral
---| 3 @ non_integral

---@alias ILTypeNumberRanges ILTypeNumberRangePoint[]

---the first point in a ranges array must always exist and must be (-1/0) inclusive\
---points in a ranges array must be in order and there must not be duplicates
---@class ILTypeNumberRangePoint
---@field range_type ILTypeNumberRangePointType
---@field value number
---@field inclusive boolean

---The big benefit with this is that none of the data needs to be compared,
---it's just the id that needs to match
---@class ILTypeIdentity
---@field id number @ -- TODO: just how global is this id? I feel like it has to be truly unique
---@field type_flag ILTypeFlags @ a single flag indicating what type the identity is for
---@field function_instance any? @ -- TODO: what data structure
---@field table_instance any? @ -- TODO: what data structure
---@field userdata_instance any? @ -- TODO: what data structure
---@field thread_instance any? @ -- TODO: what data structure

---@alias ILInstructionType
---| "move"
---| "get_upval"
---| "set_upval"
---| "get_table"
---| "set_table"
---| "set_list"
---| "new_table"
---| "concat"
---| "binop"
---| "unop"
---| "label"
---| "jump"
---| "test"
---| "call"
---| "ret"
---| "closure"
---| "vararg"
---| "close_up"
---| "scoping"
---| "to_number"
---
---| "forprep_inst"
---| "forloop_inst"
---| "tforcall_inst"
---| "tforloop_inst"

---@alias ILInstructionGroupType
---| "forprep"
---| "forloop"
---| "tforcall"
---| "tforloop"

---@class ILInstructionGroup
---@field group_type ILInstructionGroupType
---@field start ILInstruction
---@field stop ILInstruction
---@field position Position?

---@class ILForprepGroup : ILInstructionGroup
---@field group_type "forprep"
---@field index_reg ILRegister
---@field limit_reg ILRegister
---@field step_reg ILRegister
---@field loop_jump ILJump

---@class ILForloopGroup : ILInstructionGroup
---@field group_type "forloop"
---@field index_reg ILRegister
---@field limit_reg ILRegister
---@field step_reg ILRegister
---@field local_reg ILRegister
---@field loop_jump ILJump

---@class ILTforcallGroup : ILInstructionGroup
---@field group_type "tforcall"

---@class ILTforloopGroup : ILInstructionGroup
---@field group_type "tforloop"

---@class ILInstruction : ILLNode<ILInstruction>
---@field list ILInstructionList @ (overridden) back reference
---@field prev ILInstruction? @ (overridden) `nil` if this is the first node
---@field next ILInstruction? @ (overridden) `nil` if this is the last node
---@field inst_type ILInstructionType
---@field inst_group ILInstructionGroup
---@field position ILPosition|nil
---post IL generation data
---@field block ILBlock
---@field regs_start_at_list ILRegister[]
---@field regs_start_at_lut table<ILRegister, boolean>
---@field regs_stop_at_list ILRegister[]
---@field regs_stop_at_lut table<ILRegister, boolean>
---@field prev_border ILBorder? @ the border between the prev inst and this inst. `nil` for first inst
---@field next_border ILBorder? @ the border between this inst and the next inst. `nil` for last inst
---@field pre_state ILState
---@field post_state ILState
---@field input_reg_group ILRegisterGroup?
---@field output_reg_group ILRegisterGroup?
---@field forced_list_index integer?

---@class ILInstructionList : IntrusiveIndexedLinkedList<ILInstruction>
---@field first ILInstruction @ (overridden) empty instruction lists are malformed, therefore never `nil`
---@field last ILInstruction @ (overridden) empty instruction lists are malformed, therefore never `nil`

---A point in time during the execution of a function where the program's execution flow is passing by.\
---Nothing is happening at this point, unlike instructions which perform some action.\
---These points in time are all ILBorders within an ILBlock, and all ILBlockLinks.\
---Therefore the fields in this data structure are `nil` for all borders between two ILBlocks.
---@class ILExecutionCheckpoint
---@field real_live_regs ILLiveRegisterRange[]
---@field live_range_by_reg table<ILRegister, ILLiveRegisterRange>

---The border between 2 instructions.
---@class ILBorder : ILExecutionCheckpoint
---@field prev_inst ILInstruction
---@field next_inst ILInstruction
---@field live_regs ILRegister[]

---@class ILLiveRegisterRange
---@field reg ILRegister
---@field color integer @ 1 based.
---@field adjacent_regs ILLiveRegisterRange[] @ Temp data for interference graph for color eval.
---@field adjacent_regs_lut table<ILLiveRegisterRange, true> @ Temp data for interference graph for color eval.
---Parameter live register ranges do not have an instruction which sets them initially.
---Keep in mind that a register can have multiple live ranges, but only one of them will have this flag set.
---@field is_param boolean?
---Does this live register range get captured as an upvalue for an inner function?
---@field is_captured_as_upval boolean?
---The instructions setting/writing to this live reg range, the beginning(s) of its lifetime.\
---`nil` when `is_param` is `true`.
---@field set_insts ILInstruction[]

---@class ILState
---@field reg_types table<ILRegister, ILType>

---@class ILMove : ILInstruction
---@field inst_type "move"
---@field result_reg ILRegister
---@field right_ptr ILPointer

---@class ILGetUpval : ILInstruction
---@field inst_type "get_upval"
---@field result_reg ILRegister
---@field upval ILUpval

---@class ILSetUpval : ILInstruction
---@field inst_type "set_upval"
---@field upval ILUpval
---@field right_ptr ILPointer

---@class ILGetTable : ILInstruction
---@field inst_type "get_table"
---@field result_reg ILRegister
---@field table_reg ILRegister
---@field key_ptr ILPointer

---@class ILSetTable : ILInstruction
---@field inst_type "set_table"
---@field table_reg ILRegister
---@field key_ptr ILPointer
---@field right_ptr ILPointer

---@class ILSetList : ILInstruction
---@field inst_type "set_list"
---@field table_reg ILRegister
---@field start_index integer
---@field right_ptrs ILPointer[] @ The last one can be an `ILVarargRegister`

---@class ILNewTable : ILInstruction
---@field inst_type "new_table"
---@field result_reg ILRegister
---@field array_size integer
---@field hash_size integer

---@class ILConcat : ILInstruction
---@field inst_type "concat"
---@field result_reg ILRegister
---@field right_ptrs ILPointer[]

---@class ILBinop : ILInstruction
---@field inst_type "binop"
---@field result_reg ILRegister
---@field op ILBinOpOpBase @ note the absence of "and" and "or"
---@field left_ptr ILPointer
---@field right_ptr ILPointer
---@field raw boolean @ wether or not this instruction can use meta methods or not. Used for fornum

---@class ILUnop : ILInstruction
---@field inst_type "unop"
---@field result_reg ILRegister
---@field op AstUnOpOp
---@field right_ptr ILPointer

---@class ILLabel : ILInstruction
---@field inst_type "label"
---@field name string|nil
---temp compilation data
---@field target_inst ILCompiledInstruction @ the instruction jumps to this label will jump to

---@class ILJump : ILInstruction
---@field inst_type "jump"
---@field label ILLabel
---@field allow_setting_label_while_in_inst_group boolean
---temp compilation data\
---the jmp instruction that needs its `sbx` set after `inst_index`es have been evaluated
---@field jump_inst ILCompiledInstruction

---@class ILTest : ILInstruction
---@field inst_type "test"
---@field label ILLabel
---@field allow_setting_label_while_in_inst_group boolean
---@field condition_ptr ILPointer
---@field jump_if_true boolean
---temp compilation data\
---the jmp instruction that needs its `sbx` set after `inst_index`es have been evaluated
---@field jump_inst ILCompiledInstruction

---@class ILCall : ILInstruction
---@field inst_type "call"
---@field func_reg ILRegister
---@field arg_ptrs ILPointer[] @ The last one can be an `ILVarargRegister`
---@field result_regs ILRegister[] @ The last one can be an `ILVarargRegister`

---@class ILRet : ILInstruction
---@field inst_type "ret"
---@field ptrs ILPointer[] @ The last one can be an `ILVarargRegister`

---@class ILClosure : ILInstruction
---@field inst_type "closure"
---@field result_reg ILRegister
---@field func ILFunction

---@class ILVararg : ILInstruction
---@field inst_type "vararg"
---@field result_regs ILRegister[] @ The last one can be an `ILVarargRegister`

---@class ILCloseUp : ILInstruction
---@field inst_type "close_up"
---@field regs ILRegister[]

---@class ILScoping : ILInstruction
---@field inst_type "scoping"
---@field regs ILRegister[]
---When true this must be the very first instruction in the instruction list where `regs` is a reference to
---`ILFunction.param_regs`.
---@field is_entry boolean

---@class ILToNumber : ILInstruction
---@field inst_type "to_number"
---@field result_reg ILRegister
---@field right_ptr ILPointer

---@class ILForprepInst : ILInstruction
---@field inst_type "forprep_inst"
---@field index_reg ILRegister
---@field limit_reg ILRegister
---@field step_reg ILRegister
---@field label ILLabel

---@class ILForloopInst : ILInstruction
---@field inst_type "forloop_inst"
---@field index_reg ILRegister
---@field limit_reg ILRegister
---@field step_reg ILRegister
---@field local_reg ILRegister
---@field label ILLabel

---@class ILTforcallInst : ILInstruction
---@field inst_type "tforcall_inst"

---@class ILTforloopInst : ILInstruction
---@field inst_type "tforloop_inst"

---@class ILFunction
---@field parent_func ILFunction|nil @ `nil` if main chunk
---@field inner_functions ILFunction[]
---Intrusive ILL\
---Every path through the blocks must end with a return instruction, which means there is always at least 1.\
---Functions with at least one parameter must have a scoping instruction as their first instruction where the
---`regs` table of said instruction is a reference to this function's `param_regs`.\
---(note that to ensure proper lifetime in relation to loops and upvalues there usually is
---also a scoping instruction with all parameter registers before the last instruction,
---however that one must not use a reference to the same table. It isn't guaranteed to contain all
---param regs, and it could get moved or removed. There are no special rules for this instruction.)
---@field instructions ILInstructionList
---@field upvals ILUpval[]
---@field param_regs ILRegister[]
---@field is_vararg boolean
---@field source string?
---@field defined_position Position? @ usually the position of the `function_token`
---@field last_defined_position Position? @ usually the position of the `end_token`
---post IL generation data
---@field has_blocks boolean @ `blocks` on ILFunction and `block` on ILInstruction
---@field blocks ILBLockList @ intrusive linked list
---@field has_borders boolean @ `prev_border` and `next_border` on ILInstruction
---Depends on `has_borders`\
---`regs_(start|stop)_at_(list|lut)` on ILInstruction\
---`live_regs` on ILBorder\
---`all_regs` on ILFunction and with it `(prev|next)_reg_in_func` on ILRegister
---@field has_reg_liveliness boolean
---@field all_regs ILRegisterList
---Depends on `has_blocks` and `has_borders`\
---`real_live_regs` on ILExecutionCheckpoint\
---`param_live_reg_range_lut` on ILFunction
---@field has_real_reg_liveliness boolean
---May not contain a range for each param. Unused params don't have one.
---@field param_live_reg_range_lut table<ILRegister, ILLiveRegisterRange>
---@field has_types boolean @ `(pre|post)_state` on ILInstruction
---Search for "temp compilation data" in classes.lua for all the data related to this step.\
---During compilation modification of IL is prohibited. The above data would not get updated.
---@field is_compiling boolean
---
---@field temp ILFunctionTemp
---temp compilation data
---@field closure_index integer @ **zero based** needed for closure instructions to know the function index

---@class ILRegisterList
---@field first ILRegister?
---@field last ILRegister?

---@class ILBlock
---@field prev ILBlock? @ `nil` if this is the first block
---@field next ILBlock? @ `nil` if this is the last block
---@field is_main_entry_block boolean?
---@field source_links ILBlockLink[] @ blocks flowing into this block
---@field start_inst ILInstruction @ the first instruction in this block
---@field stop_inst ILInstruction @ the last instruction in this block
---@field straight_link ILBlockLink? @ used when this block flows directly into the next block
---@field jump_link ILBlockLink? @ only used by "test" and "jump" instructions, linking to the label's block

---@class ILBLockList
---@field first ILBlock @ empty instruction lists are malformed, therefore never nil
---@field last ILBlock @ empty instruction lists are malformed, therefore never nil

---@class ILBlockLink : ILExecutionCheckpoint
---@field source_block ILBlock @ the block flowing to `target_block`
---@field target_block ILBlock @ the block `source_block` is flowing to
---a loop link is the link determined to be the one closing the loop of a collection of blocks
---which are ultimately forming a loop.
---(currently all backwards jumps are marked as loop links)
---@field is_loop boolean
---`true` when this is the `jump_link` of the source_block, otherwise it's the `straight_link`.
---@field is_jump_link boolean?

---@class ILFunctionTemp
---@field local_reg_lut table<AstLocalDef, ILRegister>
---@field upval_def_lut table<AstUpvalDef, ILUpval>
---@field break_jump_lut table<AstBreakStat, ILJump>
---@field label_inst_lut table<AstLabel, ILLabel>
---@field goto_inst_lut table<AstGotoStat, ILJump>

--------------------------------------------------
-- generated/bytecode stuff:

---@alias OpcodeParamType
---| 1 @ register
---| 2 @ constant
---| 3 @ register_or_constant
---| 4 @ upval
---| 5 @ bool
---| 6 @ floating_byte
---| 7 @ jump_pc_offset
---| 8 @ other
---| nil @ unused

---@class OpcodeParams
---@field a OpcodeParamType
---@field b OpcodeParamType
---@field c OpcodeParamType
---@field ax OpcodeParamType
---@field bx OpcodeParamType
---@field sbx OpcodeParamType

---by how much the raw value has to be reduced to get the actual value
---of the param if the raw value is not equal to zero.\
---Used for a few params where 0 has a special meaning line `var`
---@class OpcodeReduceIfNotZero
---@field a number|nil
---@field b number|nil
---@field c number|nil
---@field ax number|nil
---@field bx number|nil
---@field sbx number|nil

---technically only used for`name == "extraarg"`\
---these param types completely override the entire `params` of the referenced opcode
---@class OpcodeNextOpcode
---@field name string @ name of the opcode that has to follow this opcode
---Under what condition this opcode has to be followed by this next opcode as defined here
---@field condition nil|fun(inst: Instruction):boolean
---@field a OpcodeParamType
---@field b OpcodeParamType
---@field c OpcodeParamType
---@field ax OpcodeParamType
---@field bx OpcodeParamType
---@field sbx OpcodeParamType

---@class Opcode
---@field id integer @ **zero based**
---@field name string @ opcode name. Commonly used as the identifier to look up opcodes
---@field label string @ the `name` but all caps
---@field params OpcodeParams
---@field reduce_if_not_zero OpcodeReduceIfNotZero
---@field next_op OpcodeNextOpcode|nil

---@class InstructionArguments
---@field a integer
---@field b integer
---@field c integer
---@field ax integer
---@field bx integer
---@field sbx integer

---@class Instruction : InstructionArguments, Position
---@field op Opcode
---@field column integer? @ stored in Phobos debug symbols (overridden just for the comment)
---@field source string? @ stored in Phobos debug symbols

---@alias CompiledConstant AstString|AstNumber|AstBoolean|AstNil

---@class CompiledRegister
---@field index integer @ **zero based** index of the register
---@field name string @ this name is for from start_at until stop_at
---@field start_at integer @ **one based including**
---@field stop_at integer @ **one based including**
---temporary data during compilation
---@field level integer
---@field scope AstScope
---@field in_scope_at integer|nil @ pc **one based including** used to figure out how many upvals to close

---@class CompiledUpval
---@field name string
---@field in_stack boolean
---used when `in_stack` is `false`. index of the parent upval for bytecode
---@field upval_idx integer?
---used when `in_stack` is `true`.
---register index of the local variable at the time of creating the closure
---@field local_idx integer?
---temporary data during compilation
---@field index integer @ **zero based** index for inner functions to figure out their `upval_idx`s

---@class CompiledFunc
---@field line_defined integer|nil
---@field column_defined integer|nil @ stored in Phobos debug symbols
---@field last_line_defined integer|nil
---@field last_column_defined integer|nil @ stored in Phobos debug symbols
---@field num_params integer
---@field is_vararg boolean
---@field max_stack_size integer @ min 2, reg0/1 always valid
---@field instructions Instruction[]
---@field constants CompiledConstant[]
---@field inner_functions CompiledFunc[]
---@field upvals CompiledUpval[]
---@field source string|nil
---@field debug_registers CompiledRegister[] @ which names are used for registers when debugging
---temporary data during compilation
---@field live_regs CompiledRegister[]
---@field next_reg integer @ **zero based** index of next register to use
---@field constant_lut table<any, CompiledConstant> @ mapping from any value to it's CompiledConstant
---@field nil_constant_idx number|nil @ **zero based** index of the `nil` CompiledConstant
---@field nan_constant_idx number|nil @ **zero based** index of the nan (`0/0`) CompiledConstant
---@field level integer? @ only available during generation process
---@field scope_levels? table<AstScope, integer> @ only available during generation process
---@field current_scope? AstScope @ only available during generation process

--------------------------------------------------
-- emmy lua stuff:

---@alias EmmyLuaTypeType
---| "literal"
---| "dictionary"
---| "reference"
---| "function"
---| "array"
---| "union"

---@class EmmyLuaType
---@field type_type EmmyLuaTypeType
---@field start_position Position @ inclusive
---@field stop_position Position @ inclusive

---NOTE: this is currently purely a literal string, any other literal is currently not supported
---@class EmmyLuaLiteralType : EmmyLuaType
---@field type_type "literal"
---@field value string @ has quotes

---@class EmmyLuaDictionaryType : EmmyLuaType
---@field type_type "dictionary"
---@field key_type EmmyLuaType
---@field value_type EmmyLuaType

---@class EmmyLuaReferenceType : EmmyLuaType
---@field type_type "reference"
---@field type_name string
---Once the linker ran `nil` means it could not resolve the reference
---@field reference_sequence EmmyLuaClassSequence|EmmyLuaAliasSequence|nil

---@class EmmyLuaFunctionType : EmmyLuaType
---@field type_type "function"
---@field description string[]
---@field params EmmyLuaParam[]
---@field returns EmmyLuaReturn[]

---@class EmmyLuaParam
---@field description string[]
---@field name string
---@field optional boolean
---@field param_type EmmyLuaType

---@class EmmyLuaReturn
---@field description string[]
---@field name string|nil @ always `nil` if a `fun()` type, if it is a sequence it is simply optional
---@field optional boolean
---@field return_type EmmyLuaType

---@class EmmyLuaArrayType : EmmyLuaType
---@field type_type "array"
---@field value_type EmmyLuaType

---@class EmmyLuaUnionType : EmmyLuaType
---@field type_type "union"
---@field union_types EmmyLuaType[]

---@alias EmmyLuaSequenceType
---| "class"
---| "alias"
---| "function"
---| "none"

---@class EmmyLuaSequence
---@field sequence_type EmmyLuaSequenceType
---@field node AstNode|nil @ whichever node this sequence was preceding
---@field source string|nil @ function source -- TODO: check if nil source would cause any trouble
---@field start_position Position @ inclusive
---@field stop_position Position @ inclusive

---@class EmmyLuaTypeDefiningSequence : EmmyLuaSequence
---@field type_name string
---@field type_name_start_position Position @ inclusive
---@field type_name_stop_position Position @ inclusive
---Set by the linker if this is a duplicate type name
---@field duplicate_type_error_code_inst ErrorCodeInstance|nil

---@class EmmyLuaClassSequence : EmmyLuaTypeDefiningSequence
---@field sequence_type "class"
---@field node AstLocalStat|nil
---@field description string[]
---@field base_classes EmmyLuaType[] @ Only `"reference"`s to other classes are valid
---@field fields EmmyLuaField[]
---@field is_builtin boolean

---@class EmmyLuaField
---If the `field_type` is a function then its `description` and this one must refer to the same table
---@field description string[]
---@field name string
---@field optional boolean
---@field field_type EmmyLuaType

---@class EmmyLuaAliasSequence : EmmyLuaTypeDefiningSequence
---@field sequence_type "alias"
---@field node nil @ overridden to be nil
---@field description string[]
---@field aliased_type EmmyLuaType

---@class EmmyLuaFunctionSequence : EmmyLuaSequence, EmmyLuaFunctionType
---@field sequence_type "function"
---@field node AstFuncStat|AstLocalFunc

---@class EmmyLuaNoneSequence : EmmyLuaSequence
---@field sequence_type "none"
---@field node AstLocalStat|nil
---@field description string[]
