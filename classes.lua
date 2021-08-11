
--------------------------------------------------
-- ast stuff:

---@alias AstNodeToken
---special:
---| '"main"'
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
---| '"localfunc"'
---| '"label"'
---| '"retstat"'
---| '"breakstat"'
---| '"gotostat"'
---| '"selfcall"' @ expression or statement
---| '"call"' @ expression or statement
---| '"assignment"'
---expressions:
---| '"local"' @ --TODO: change/clean up variables and references
---| '"upval"' @ --TODO: change/clean up variables and references
---| '"index"'
---| '"ident"' @ -- TODO: same as '"string"'? --TODO: change/clean up variables and references
---| '"_ENV"' @ potentially also special --TODO: change/clean up variables and references
---| '"unop"'
---| '"binop"'
---| '"concat"'
---| '"number"'
---| '"string"'
---| '"nil"'
---| '"true"' @ -- TODO: combine these to be boolean with value
---| '"false"' @ -- TODO: combine these to be boolean with value
---| '"..."'
---| '"funcproto"'
---| '"constructor"'

---@class AstNode
---@field token AstNodeToken
---@field line integer
---@field column integer
---@field leading Token[] @ `"blank"` and `"comment"` tokens

---@class AstStatement : AstNode

---@class AstParenWrapper
---@field open_paren_token AstTokenNode
---@field close_paren_token AstTokenNode

---@class AstExpression : AstNode
---@field src_paren_wrappers AstParenWrapper[]|nil

-- since every scope inherits AstBody, AstScope now does as well

---@class AstScope : AstBody
---@field parent AstParent


---@class AstBody
---@field body AstStatement[]
---@field locals AstLocalDef[]
---@field labels AstLabel[]

---@class AstFunctionDef : AstBody, AstScope
---@field token '"functiondef"'
---@field source string
---@field ismethod boolean @ is it `function foo:bar() end`?
---@field funcprotos AstFunctionDef[]
---@field upvals AstUpValueDef[]
---@field constants AstConstantDef[]
---@field endline integer
---@field endcolumn integer
---@field isvararg boolean
---@field nparams integer
---@field parent AstUpValParent
---all parameters are `wholeblock = true` locals, except vararg
---@field param_comma_tokens AstTokenNode[] @ max length is `nparams - 1`, min `0`
---@field open_paren_token AstTokenNode
---@field close_paren_token AstTokenNode
---@field end_token AstTokenNode



---@class AstEmpty : AstStatement
---@field token '"empty"'
---@field semi_colon_token AstTokenNode

---Like an empty node, no-op, purely describing the syntax
---@class AstTokenNode : AstNode
---@field token '"token"'
---@field value string

---@class AstIfStat : AstStatement
---@field token '"ifstat"'
---@field ifs AstTestBlock[]
---@field elseblock AstElseBlock|nil
---@field end_token AstTokenNode

---@class AstTestBlock : AstStatement, AstBody, AstScope
---@field token '"testblock"'
---@field cond AstExpression
---@field parent AstLocalParent
---@field if_token AstTokenNode @ for the first test block this is an `if` token, otherwise `elseif`
---@field then_token AstTokenNode

---@class AstElseBlock : AstStatement, AstBody, AstScope
---@field token '"elseblock"'
---@field parent AstLocalParent
---@field else_token AstTokenNode

---@class AstWhileStat : AstStatement, AstBody, AstScope
---@field token '"whilestat"'
---@field cond AstExpression
---@field parent AstLocalParent
---@field while_token AstTokenNode
---@field do_token AstTokenNode
---@field end_token AstTokenNode

---@class AstDoStat : AstStatement, AstBody, AstScope
---@field token '"dostat"'
---@field parent AstLocalParent
---@field do_token AstTokenNode
---@field end_token AstTokenNode

---@class AstForNum : AstStatement, AstBody, AstScope
---@field token '"fornum"'
---@field var AstLocal
---@field start AstExpression
---@field stop AstExpression
---@field step AstExpression|nil
---@field parent AstLocalParent
---`var` is used for a `whileblock = true` local
---@field locals AstLocalDef[]
---@field for_token AstTokenNode
---@field eq_token AstTokenNode
---@field first_comma_token AstTokenNode
---@field second_comma_token AstTokenNode|nil @ only used when `step` is not `nil`
---@field do_token AstTokenNode
---@field end_token AstTokenNode

---@class AstForList : AstStatement, AstBody, AstScope
---@field token '"forlist"'
---@field namelist AstLocal[]
---@field explist AstExpression[]
---@field explist_comma_tokens AstTokenNode[]
---@field parent AstLocalParent
---all `namelist` names are used for a `wholeblock = true` local
---@field locals AstLocalDef[]
---@field for_token AstTokenNode
---@field comma_tokens AstTokenNode[] @ max length is `#namelist - 1`
---@field in_token AstTokenNode
---@field do_token AstTokenNode
---@field end_token AstTokenNode

---@class AstRepeatStat : AstStatement, AstBody, AstScope
---@field token '"repeatstat"'
---@field cond AstExpression
---@field parent AstLocalParent
---@field repeat_token AstTokenNode
---@field until_token AstTokenNode

---@class AstFuncStat : AstStatement, AstFuncBase
---@field token '"funcstat"'
---@field names AstExpression[] @ first is anything from checkref, the rest AstIdent
---@field dot_tokens AstTokenNode[] @ max length is `#names - 1`

---@class AstLocalFunc : AstStatement, AstFuncBase
---@field token '"localfunc"'
---@field name AstLocal
---@field local_token AstTokenNode

---@class AstLocalStat : AstStatement
---@field token '"localstat"'
---@field lhs AstLocal[]
---@field rhs AstExpression[]|nil @ `nil` = no assignment
---@field local_token AstTokenNode
---@field lhs_comma_tokens AstTokenNode[] @ max length is `#lhs - 1`
---@field rhs_comma_tokens AstTokenNode[]|nil @ `nil` when `rhs` is `nil`. max length is `#rhs - 1`
---@field eq_token AstTokenNode|nil @ only used if `rhs` is not `nil`

---@class AstLabel : AstStatement
---@field token '"label"'
---@field value string
---@field open_token AstTokenNode @ opening `::`
---@field close_token AstTokenNode @ closing `::`

---@class AstRetStat : AstStatement
---@field token '"retstat"'
---@field return_token AstTokenNode
---@field explist AstExpression[]|nil @ `nil` = no return values
---@field explist_comma_tokens AstTokenNode[]
---@field semi_colon_token AstTokenNode|nil @ trailing `;`. `nil` = no semi colon

---@class AstBreakStat : AstStatement
---@field token '"breakstat"'
---@field break_token AstTokenNode

---@class AstGotoStat : AstStatement
---@field token '"gotostat"'
---@field target AstIdent
---@field goto_token AstTokenNode

---@class AstSelfCall : AstStatement, AstExpression
---@field token '"selfcall"'
---@field ex AstExpression
---@field suffix AstString @ function name. `src_is_ident` is always `true`
---@field args AstExpression[]
---@field colon_token AstTokenNode
---@field open_paren_token AstTokenNode|nil
---@field close_paren_token AstTokenNode|nil

---@class AstCall : AstStatement, AstExpression
---@field token '"call"'
---@field ex AstExpression
---@field args AstExpression[]
---@field open_paren_token AstTokenNode|nil
---@field close_paren_token AstTokenNode|nil

---@class AstAssignment : AstStatement
---@field token '"assignment"'
---@field lhs AstExpression[]
---@field lhs_comma_tokens AstTokenNode[]
---@field eq_token AstTokenNode
---@field rhs AstExpression[]
---@field rhs_comma_tokens AstTokenNode[]



---@class AstLocal : AstExpression
---@field token '"local"'
---@field value string

---@class AstUpVal : AstExpression
---@field token '"upval"'
---@field value string

---@class AstIndex : AstExpression
---@field token '"index"'
---@field ex AstExpression
---if this is an AstString with `src_is_ident == true`
---then it is representing a literal identifier
---@field suffix AstExpression
---Only used if it is a literal identifier
---@field dot_token AstTokenNode|nil
---`[` token if it is not a literal identifier
---@field suffix_open_token AstTokenNode|nil
---`]` token if it is not a literal identifier
---@field suffix_close_token AstTokenNode|nil

---i think this is basically a string constant expression
---@class AstString : AstExpression
---@field token '"string"'
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

---the same as AstStringName, maybe a bug
---@class AstIdent : AstExpression
---@field token '"ident"'
---@field value string

---@class Ast_ENV : AstExpression
---@field token '"_ENV"'
---@field value '"_ENV"'

---@class AstUnOp : AstExpression
---@field token '"unop"'
---@field op '"not"'|'"-"'|'"#"'
---@field ex AstExpression
---@field op_token AstTokenNode

---@class AstBinOp : AstExpression
---@field token '"binop"'
---@field op '"^"'|'"*"'|'"/"'|'"%"'|'"+"'|'"-"'|'"=="'|'"<"'|'"<="'|'"~="'|'">"'|'">="'|'"and"'|'"or"'
---@field left AstExpression
---@field right AstExpression
---@field op_token AstTokenNode

---@class AstConcat : AstExpression
---@field token '"concat"'
---@field explist AstExpression[]
---@field op_tokens AstTokenNode[] @ max length is `#explist - 1`

---@class AstNumber : AstExpression
---@field token '"number"'
---@field value number
---@field src_value string

---@class AstNil : AstExpression
---@field token '"nil"'

---@class AstTrue : AstExpression
---@field token '"true"'
---@field value 'true'

---@class AstFalse : AstExpression
---@field token '"false"'
---@field value 'false'

---@class AstVarArg : AstExpression
---@field token '"..."'

---@class AstFuncBase : AstNode
---@field ref AstFunctionDef
---@field function_token AstTokenNode

---@class AstFuncProto : AstExpression, AstFuncBase
---@field token '"funcproto"'

---@class AstField
---@field type '"rec"'|'"list"'

---@class AstRecordField
---@field type '"rec"'
---to represent a literal identifier this is
---a string expression with `src_is_ident == true`
---@field key AstExpression
---@field value AstExpression
---@field key_open_token AstTokenNode|nil @ `[` token if the key is using it
---@field key_close_token AstTokenNode|nil @ `]` token if the key is using it
---@field eq_token AstTokenNode

---@class AstListField
---@field type '"list"'
---@field value AstExpression

---@class AstConstructor : AstExpression
---@field token '"constructor"'
---@field fields AstField[]
---@field open_paren_token AstTokenNode
---@field comma_tokens AstTokenNode[] @ `,` or `;` tokens, max length is `#fields`
---@field close_paren_token AstTokenNode



---@class AstUpValueDef
---@field name string
---@field updepth integer @ -- TODO: what does this mean
---@field ref any @ -- TODO



---@class AstLocalDef
---@field name AstLocal|Ast_ENV
---i think this means it is defined at the start of
---the block and lasts for the entire block
---@field wholeblock boolean|nil
---@field startbefore AstStatement|nil
---@field startafter AstStatement|nil

---@class AstEnv : AstNode
---@field token '"env"'
---@field locals AstLocalDef[] @ 1 `wholeblock = true` local with AstEnvName

---@class AstParent
---@field type '"upval"'|'"local"'
---@field scope AstNode

---@class AstLocalParent : AstParent
---@field type '"local"'

---@class AstUpValParent : AstParent
---@field type '"upval"'

---@class AstConstantDef

---@class AstMain : AstFunctionDef
---@field token '"main"'
---@field ismethod 'false'
---@field line '0'
---@field column '0'
---@field endline '0'
---@field endcolumn '0'
---@field isvararg 'true'
---@field nparams '0'
---@field locals AstLocalDef[]
---@field eof_token AstTokenNode @ to store trailing blank and comment tokens

--------------------------------------------------
-- generated/bytecode stuff:

---@class Instruction
---@field op integer
---@field a integer
---@field b integer
---@field c integer
---@field ck integer @ used instead of c if it is a constant
---@field ax integer
---@field bx integer
---@field sbx integer

---@class GeneratedUpValue : AstUpValueDef
---@field index integer @ **zero based**

---@class GeneratedStatement : AstStatement
---@field index integer @ **zero based**

---@class GeneratedFunc : AstFunctionDef
---@field liveregs any[]
---@field nextreg integer @ **zero based** index of next register to use
---@field maxstacksize integer @ always at least two registers
---@field instructions Instruction[]
---@field upvals GeneratedUpValue[] @ overridden
---@field body GeneratedStatement[] @ overridden
