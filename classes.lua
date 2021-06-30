
---@alias AstNoteToken
---special:
---| '"main"'
---| '"env"'
---| '"functiondef"'
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
---| '"local"'
---| '"upval"'
---| '"index"'
---| '"ident"' @ -- TODO: same as '"string"'?
---| '"_ENV"' @ potentially also special
---| '"unop"'
---| '"binop"'
---| '"concat"'
---| '"number"'
---| '"string"'
---| '"nil"'
---| '"true"'
---| '"false"'
---| '"..."'
---| '"funcproto"'
---| '"constructor"'

---@class AstNode
---@field token AstNoteToken
---@field line integer
---@field column integer

---@class AstStatement : AstNode

---@class AstExpression : AstNode

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
---@field locals AstLocalDef[]



---@class AstEmpty : AstStatement
---@field token '"empty"'

---@class AstIfStat : AstStatement
---@field token '"ifstat"'
---@field ifs AstTestBlock[]
---@field elseblock AstElseBlock|nil

---@class AstTestBlock : AstStatement, AstBody, AstScope
---@field token '"testblock"'
---@field cond AstExpression
---@field parent AstLocalParent

---@class AstElseBlock : AstStatement, AstBody, AstScope
---@field token '"elseblock"'
---@field parent AstLocalParent

---@class AstWhileStat : AstStatement, AstBody, AstScope
---@field token '"whilestat"'
---@field parent AstLocalParent

---@class AstDoStat : AstStatement, AstBody, AstScope
---@field token '"dostat"'
---@field parent AstLocalParent

---@class AstForNum : AstStatement, AstBody, AstScope
---@field token '"fornum"'
---@field var AstLocal
---@field start AstExpression
---@field stop AstExpression
---@field step AstExpression
---@field parent AstLocalParent
---`var` is used for a `whileblock = true` local
---@field locals AstLocalDef[]

---@class AstForList : AstStatement, AstBody, AstScope
---@field token '"forlist"'
---@field namelist AstLocal[]
---@field explist AstExpression[]
---@field parent AstLocalParent
---all `namelist` names are used for a `wholeblock = true` local
---@field locals AstLocalDef[]

---@class AstRepeatStat : AstStatement, AstBody, AstScope
---@field token '"repeatstat"'
---@field cond AstExpression
---@field parent AstLocalParent

---@class AstFuncStat : AstStatement
---@field token '"funcstat"'
---@field ref AstFunctionDef
---@field names AstExpression[] @ first is anything from checkref, the rest AstIdent

---@class AstLocalFunc : AstStatement
---@field token '"localfunc"'
---@field ref AstFunctionDef
---@field name AstLocal

---@class AstLocalStat : AstStatement
---@field token '"localstat"'
---@field lhs AstLocal[]
---@field rhs AstExpression[]|nil

---@class AstLabel : AstStatement
---@field token '"label"'
---@field value string

---@class AstRetStat : AstStatement
---@field token '"retstat"'
---@field explist AstExpression[]|nil @ `nil` = no return values

---@class AstBreakStat : AstStatement
---@field token '"breakstat"'

---@class AstGotoStat : AstStatement
---@field token '"gotostat"'
---@field target AstIdent

---@class AstSelfCall : AstStatement, AstExpression
---@field token '"selfcall"'
---@field ex AstExpression
---@field suffix AstString @ function name
---@field args AstExpression[]

---@class AstCall : AstStatement, AstExpression
---@field token '"call"'
---@field ex AstExpression
---@field args AstExpression[]

---@class AstAssignment : AstStatement
---@field token '"assignment"'
---@field lhs AstExpression[]
---@field rhs AstExpression[]


---@class AstLocal : AstExpression
---@field token '"local"'
---@field value string

---@class AstUpVal : AstExpression
---@field token '"upval"'
---@field value string

---@class AstIndex : AstExpression
---@field token '"index"'
---@field ex AstExpression
---@field suffix AstExpression

---i think this is basically a string constant expression
---@class AstString : AstExpression
---@field token '"string"'
---@field value string

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

---@class AstBinOp : AstExpression
---@field token '"binop"'
---@field op '"^"'|'"*"'|'"/"'|'"%"'|'"+"'|'"-"'|'"=="'|'"<"'|'"<="'|'"~="'|'">"'|'">="'|'"and"'|'"or"'
---@field left AstExpression
---@field right AstExpression

---@class AstConcat : AstExpression
---@field token '"concat"'
---@field explist AstExpression[]

---@class AstNumber : AstExpression
---@field token '"number"'
---@field value number

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

---@class AstFuncProto : AstExpression
---@field token '"funcproto"'
---@field ref AstFunctionDef

---@class AstField
---@field type '"rec"'|'"list"'

---@class AstRecordField
---@field type '"rec"'
---@field key AstExpression
---@field value AstExpression

---@class AstListField
---@field type '"list"'
---@field value AstExpression

---@class AstConstructor : AstExpression
---@field token '"constructor"'
---@field fields AstField[]



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
