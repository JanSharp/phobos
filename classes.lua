
--------------------------------------------------
-- ast stuff:

---@alias AstNodeType
---special:
---| '"env"'
---| '"functiondef"'
---| '"token"'
---statements:
---| '"empty"'
---| '"ifstat"'
---| '"testblock"'
---| '"elseblock"'
---| '"whilestat"'
---| '"dostat"'
---| '"fornum"'
---| '"forlist"'
---| '"repeatstat"'
---| '"funcstat"'
---| '"localstat"'
---| '"localfunc"'
---| '"label"'
---| '"retstat"'
---| '"breakstat"'
---| '"gotostat"'
---| '"selfcall"' @ expression or statement
---| '"call"' @ expression or statement
---| '"assignment"'
---expressions:
---| '"local_ref"'
---| '"upval_ref"'
---| '"index"'
---| '"ident"'
---| '"unop"'
---| '"binop"'
---| '"concat"'
---| '"number"'
---| '"string"'
---| '"nil"'
---| '"boolean"'
---| '"vararg"'
---| '"func_proto"'
---| '"constructor"'
---optimizer statements:
---| '"inline_iife_retstat"' @ inline immediately invoked function expression return statement
---optimizer expressions:
---| '"inline_iife"' @ inline immediately invoked function expression

---line, column and leading is only used for some node types that represent a single token\
---each ose these nodes have a comment noting this\
---however even those those these value are optional,
---them being omitted means stripped/missing debug info\
---it should also be expected that only some of them could be `nil`
---@class AstNode
---@field node_type AstNodeType
---@field line integer|nil
---@field column integer|nil
---@field leading Token[]|nil @ `"blank"` and `"comment"` tokens

---@class AstStatement : AstNode

---@class AstParenWrapper
---@field open_paren_token AstTokenNode
---@field close_paren_token AstTokenNode

---@class AstExpression : AstNode
---should the expression be forced to evaluate to only one result
---caused by the expression being wrapped in `()`
---@field force_single_result boolean|nil
---@field src_paren_wrappers AstParenWrapper[]|nil

-- since every scope inherits AstNode and AstBody, AstScope now does as well

---@class AstScope : AstNode, AstBody
---@field parent_scope AstScope|nil @ `nil` for the top level scope, the main function


---@class AstBody
---@field body AstStatement[]
---@field locals AstLocalDef[]
---@field labels AstLabel[]

---@class AstFunctionDef : AstBody, AstScope, AstNode
---@field node_type '"functiondef"'
---@field is_main 'nil' @ overridden by AstMain to be `true`
---@field source string
---@field is_method boolean @ is it `function foo:bar() end`?
---@field func_protos AstFunctionDef[]
---@field upvals AstUpvalDef[]
---@field is_vararg boolean
---@field n_params integer
---all parameters are `whole_block = true` locals, except vararg
---@field param_comma_tokens AstTokenNode[] @ max length is `n_params - 1`, min `0`
---@field open_paren_token AstTokenNode
---@field close_paren_token AstTokenNode
---@field function_token AstTokenNode
---@field end_token AstTokenNode

---@class AstFuncBase : AstNode
---@field func_def AstFunctionDef



---@class AstEmpty : AstStatement
---@field node_type '"empty"'
---@field semi_colon_token AstTokenNode

---Like an empty node, no-op, purely describing the syntax
---@class AstTokenNode : AstNode
---@field node_type '"token"'
---some token nodes are purely used for their line, column and leading data\
---specifically those with dynamic values where their value is already stored
---on the parent/main node\
---each of these have a comment noting that their `value` is `nil`
---@field value string|nil

---@class AstIfStat : AstStatement
---@field node_type '"ifstat"'
---@field ifs AstTestBlock[]
---@field elseblock AstElseBlock|nil
---@field end_token AstTokenNode

---@class AstTestBlock : AstStatement, AstBody, AstScope
---@field node_type '"testblock"'
---@field condition AstExpression
---@field if_token AstTokenNode @ for the first test block this is an `if` node_type, otherwise `elseif`
---@field then_token AstTokenNode

---@class AstElseBlock : AstStatement, AstBody, AstScope
---@field node_type '"elseblock"'
---@field else_token AstTokenNode

---@class AstLoop
---evaluated by the jump linker. not `nil` after successful linking,
---**but only if there are any `break`s that linked to this loop**
---@field linked_breaks AstBreakStat[]|nil

---@class AstWhileStat : AstStatement, AstBody, AstScope, AstLoop
---@field node_type '"whilestat"'
---@field condition AstExpression
---@field while_token AstTokenNode
---@field do_token AstTokenNode
---@field end_token AstTokenNode

---@class AstDoStat : AstStatement, AstBody, AstScope
---@field node_type '"dostat"'
---@field do_token AstTokenNode
---@field end_token AstTokenNode

---@class AstForNum : AstStatement, AstBody, AstScope, AstLoop
---@field node_type '"fornum"'
---`var` is referring to a `whole_block = true` local
---@field var AstLocalReference
---@field start AstExpression
---@field stop AstExpression
---@field step AstExpression|nil
---`var` is referring to a `whole_block = true` local
---@field locals AstLocalDef[]
---@field for_token AstTokenNode
---@field eq_token AstTokenNode
---@field first_comma_token AstTokenNode
---@field second_comma_token AstTokenNode|nil @ only used when `step` is not `nil`
---@field do_token AstTokenNode
---@field end_token AstTokenNode

---@class AstForList : AstStatement, AstBody, AstScope, AstLoop
---@field node_type '"forlist"'
---@field name_list AstLocalReference[]
---@field exp_list AstExpression[]
---@field exp_list_comma_tokens AstTokenNode[]
---all `name_list` names are used for a `whole_block = true` local
---@field locals AstLocalDef[]
---@field for_token AstTokenNode
---@field comma_tokens AstTokenNode[] @ max length is `#name_list - 1`
---@field in_token AstTokenNode
---@field do_token AstTokenNode
---@field end_token AstTokenNode

---@class AstRepeatStat : AstStatement, AstBody, AstScope, AstLoop
---@field node_type '"repeatstat"'
---@field condition AstExpression
---@field repeat_token AstTokenNode
---@field until_token AstTokenNode

---@class AstFuncStat : AstStatement, AstFuncBase
---@field node_type '"funcstat"'
---@field name AstExpression

---@class AstLocalFunc : AstStatement, AstFuncBase
---@field node_type '"localfunc"'
---@field name AstLocalReference
---@field local_token AstTokenNode

---@class AstLocalStat : AstStatement
---@field node_type '"localstat"'
---@field lhs AstLocalReference[]
---@field rhs AstExpression[]|nil @ `nil` = no assignment
---@field local_token AstTokenNode
---@field lhs_comma_tokens AstTokenNode[] @ max length is `#lhs - 1`
---@field rhs_comma_tokens AstTokenNode[]|nil @ `nil` when `rhs` is `nil`. max length is `#rhs - 1`
---@field eq_token AstTokenNode|nil @ only used if `rhs` is not `nil`

---@class AstLabel : AstStatement
---@field node_type '"label"'
---@field name string
---@field name_token AstTokenNode @ it's value is `nil`
---@field open_token AstTokenNode @ opening `::`
---@field close_token AstTokenNode @ closing `::`
---@field linked_gotos AstGotoStat[]|nil @ evaluated by the jump linker. not `nil` after successful linking

---@class AstRetStat : AstStatement
---@field node_type '"retstat"'
---@field return_token AstTokenNode
---@field exp_list AstExpression[]|nil @ `nil` = no return values
---@field exp_list_comma_tokens AstTokenNode[]
---@field semi_colon_token AstTokenNode|nil @ trailing `;`. `nil` = no semi colon

---@class AstBreakStat : AstStatement
---@field node_type '"breakstat"'
---@field break_token AstTokenNode
---@field linked_loop AstStatement[]|nil @ evaluated by the jump linker. not `nil` after successful linking

---@class AstGotoStat : AstStatement
---@field node_type '"gotostat"'
---@field target string @ name of the label to jump to
---@field target_token AstTokenNode @ it's value is `nil`
---@field goto_token AstTokenNode
---@field linked_label AstLabel|nil @ evaluated by the jump linker. not `nil` after successful linking

---@class AstSelfCall : AstStatement, AstExpression
---@field node_type '"selfcall"'
---@field ex AstExpression
---@field suffix AstString @ function name. `src_is_ident` is always `true`
---@field args AstExpression[]
---@field args_comma_tokens AstTokenNode[]
---@field colon_token AstTokenNode
---@field open_paren_token AstTokenNode|nil
---@field close_paren_token AstTokenNode|nil

---@class AstCall : AstStatement, AstExpression
---@field node_type '"call"'
---@field ex AstExpression
---@field args AstExpression[]
---@field args_comma_tokens AstTokenNode[]
---@field open_paren_token AstTokenNode|nil
---@field close_paren_token AstTokenNode|nil

---@class AstAssignment : AstStatement
---@field node_type '"assignment"'
---@field lhs AstExpression[]
---@field lhs_comma_tokens AstTokenNode[]
---@field eq_token AstTokenNode
---@field rhs AstExpression[]
---@field rhs_comma_tokens AstTokenNode[]



---@class AstInlineIIFERetstat : AstStatement
---@field node_type '"inline_iife_retstat"'
---@field return_token AstTokenNode
---@field exp_list AstExpression[]|nil @ `nil` = no return values
---@field exp_list_comma_tokens AstTokenNode[]
---@field semi_colon_token AstTokenNode|nil @ trailing `;`. `nil` = no semi colon
---@field linked_inline_iife AstInlineIIFE
---@field leave_block_goto AstGotoStat



---uses line, column and leading
---@class AstLocalReference : AstExpression
---@field node_type '"local_ref"'
---@field name string
---@field reference_def AstLocalDef

---uses line, column and leading
---@class AstUpvalReference : AstExpression
---@field node_type '"upval_ref"'
---@field name string
---@field reference_def AstUpvalDef

---@class AstIndex : AstExpression
---@field node_type '"index"'
---@field ex AstExpression
---if this is an AstString with `src_is_ident == true`
---then it is representing a literal identifier
---@field suffix AstExpression
---Only used if it is a literal identifier
---@field dot_token AstTokenNode|nil
---`[` node_type if it is not a literal identifier
---@field suffix_open_token AstTokenNode|nil
---`]` node_type if it is not a literal identifier
---@field suffix_close_token AstTokenNode|nil
---if this is an index into `_ENV` where `_ENV.` did not exist in source
---@field scr_ex_did_not_exist boolean|nil

---uses line, column and leading
---@class AstString : AstExpression
---@field node_type '"string"'
---@field value string
---if it was just an identifier in source.\
---Used in record field keys for table constructors\
---And when indexing with literal identifiers\
---Always `true` for AstSelfCall `suffix`
---@field src_is_ident boolean|nil
---used when `src_is_ident` is falsy
---@field src_is_block_str boolean|nil
---@field src_quote string|nil @ for non block strings
---@field src_value string|nil @ for non block strings
---@field src_has_leading_newline boolean|nil @ for block strings
---@field src_pad string|nil @ the `=` chain for block strings

---uses line, column and leading
---@class AstIdent : AstExpression
---@field node_type '"ident"'
---@field value string

---@class AstUnOp : AstExpression
---@field node_type '"unop"'
---@field op '"not"'|'"-"'|'"#"'
---@field ex AstExpression
---@field op_token AstTokenNode

---@class AstBinOp : AstExpression
---@field node_type '"binop"'
---@field op '"^"'|'"*"'|'"/"'|'"%"'|'"+"'|'"-"'|'"=="'|'"<"'|'"<="'|'"~="'|'">"'|'">="'|'"and"'|'"or"'
---@field left AstExpression
---@field right AstExpression
---@field op_token AstTokenNode

---@class AstConcat : AstExpression
---@field node_type '"concat"'
---@field exp_list AstExpression[]
---@field op_tokens AstTokenNode[] @ max length is `#exp_list - 1`

---uses line, column and leading
---@class AstNumber : AstExpression
---@field node_type '"number"'
---@field value number
---@field src_value string

---uses line, column and leading
---@class AstNil : AstExpression
---@field node_type '"nil"'

---uses line, column and leading
---@class AstBoolean : AstExpression
---@field node_type '"boolean"'
---@field value boolean

---uses line, column and leading
---@class AstVarArg : AstExpression
---@field node_type '"vararg"'

---@class AstFuncProto : AstExpression, AstFuncBase
---@field node_type '"func_proto"'

---@class AstField
---@field type '"rec"'|'"list"'

---@class AstRecordField
---@field type '"rec"'
---to represent a literal identifier this is
---a string expression with `src_is_ident == true`
---@field key AstExpression
---@field value AstExpression
---@field key_open_token AstTokenNode|nil @ `[` node_type if the key is using it
---@field key_close_token AstTokenNode|nil @ `]` node_type if the key is using it
---@field eq_token AstTokenNode

---@class AstListField
---@field type '"list"'
---@field value AstExpression

---@class AstConstructor : AstExpression
---@field node_type '"constructor"'
---@field fields AstField[]
---@field open_token AstTokenNode
---@field comma_tokens AstTokenNode[] @ `,` or `;` tokens, max length is `#fields`
---@field close_token AstTokenNode



---@class AstInlineIIFE : AstExpression, AstBody, AstScope
---@field node_type '"inline_iife"'
---@field leave_block_label AstLabel
---@field linked_inline_iife_retstats AstInlineIIFERetstat[]



---@class AstUpvalDef
---@field def_type '"upval"'
---@field name string
---@field scope AstScope
---@field parent_def AstUpvalDef|AstLocalDef
---@field child_defs AstUpvalDef[]
---@field refs AstUpvalReference[] @ all upval references referring to this upval

---@class AstLocalDef
---@field def_type '"local"'
---@field name string
---i think this means it is defined at the start of
---the block and lasts for the entire block
---@field whole_block boolean|nil
---@field start_before AstStatement|nil
---@field start_after AstStatement|nil
---@field child_defs AstUpvalDef[]
---@field refs AstLocalReference[] @ all local references referring to this local
---when true this did not exist in source, but
---was added because methods implicitly have the `self` parameter
---@field src_is_method_self boolean|nil

---@class AstMain : AstFunctionDef
---@field parent_scope AstENVScope
---@field is_main 'true'
---@field is_method 'false'
---@field line '0'
---@field column '0'
---@field end_line '0'
---@field end_column '0'
---@field is_vararg 'true'
---@field n_params '0'
---@field locals AstLocalDef[]
---@field eof_token AstTokenNode @ to store trailing blank and comment tokens

---@class AstENVScope : AstBody, AstScope
---@field node_type '"env"'
---@field body AstStatement[] @ always empty
---@field locals AstLocalDef[] @ always 1 `whole_block = true` local with the name `_ENV`
---@field labels AstLabel[] @ always empty

--------------------------------------------------
-- generated/bytecode stuff:

---@class Instruction
---@field op integer
---@field a integer
---@field b integer
---@field c integer
---@field ax integer
---@field bx integer
---@field sbx integer
---@field line integer

---this is a table because `value` can be `nil`
---@class Constant
---@field value string|number|boolean|nil

---@class Register
---@field reg integer @ **zero based**
---@field name string
---@field level integer
---@field scope AstScope
---@field in_scope_at? integer @ pc **one based including** used to figure out how many upvals to close
---@field start_at? integer @ pc **one based including** when to consider `reg` to have this `name`
---@field stop_at? integer @ pc **one based including**

---@class GeneratedUpval : AstUpvalDef
---@field index integer @ **zero based**
---@field parent_def GeneratedUpval|GeneratedLocal
---@field child_defs GeneratedUpval[]
---@field in_stack boolean @ cached for dumping. To not duplicate logic
---@field upval_idx number|nil @ used when `in_stack` is `false`. index of the parent upval for dumping
---@field local_idx number|nil @ used when `in_stack` is `true`. register index of the local variable when creating a closure

---@class GeneratedLocal : AstLocalDef
---@field index integer @ **zero based**
---@field child_defs GeneratedUpval[]

---@class GeneratedStatement : AstStatement
---@field index integer @ **zero based**

---@class GeneratedLabel : AstLabel
---@field pc integer|nil @ process counter of the instruction before the label

---@class GeneratedGotoStat : AstGotoStat
---@field pc integer|nil @ process counter of `inst`, the jmp instruction
---@field inst Instruction|nil @ the jmp instruction of the goto

---@class GeneratedBreakStat : AstBreakStat
---@field pc integer|nil @ process counter of `inst`, the jmp instruction
---@field inst Instruction|nil @ the jmp instruction of the goto

---@class GeneratedFunc : AstFunctionDef
---@field live_regs Register[]
---@field next_reg integer @ **zero based** index of next register to use
---@field max_stack_size integer @ always at least two registers
---@field instructions Instruction[]
---@field constants Constant[]
---@field level integer? @ only available during generation process
---@field scope_levels? table<AstScope, integer> @ only available during generation process
---@field current_scope? AstScope @ only available during generation process
---@field locals GeneratedLocal[] @ overridden
---@field upvals GeneratedUpval[] @ overridden
---@field body GeneratedStatement[] @ overridden
