
# syntax

```
chunk ::= block

block ::= {stat} [retstat]

stat ::=  ‘;’ | 
    var_list ‘=’ exp_list | 
    func_call | 
    label | 
    break | 
    goto Name | 
    do block end | 
    while exp do block end | 
    repeat block until exp | 
    if exp then block {elseif exp then block} [else block] end | 
    for Name ‘=’ exp ‘,’ exp [‘,’ exp] do block end | 
    for name_list in exp_list do block end | 
    function func_name func_body | 
    local function Name func_body | 
    local name_list [‘=’ exp_list] 

retstat ::= return [exp_list] [‘;’]

label ::= ‘::’ Name ‘::’

func_name ::= Name {‘.’ Name} [‘:’ Name]

var_list ::= var {‘,’ var}

var ::=  Name | prefix_exp ‘[’ exp ‘]’ | prefix_exp ‘.’ Name 

name_list ::= Name {‘,’ Name}

exp_list ::= exp {‘,’ exp}

exp ::=  nil | false | true | Number | String | ‘...’ | functiondef | 
    prefix_exp | table_constructor | exp binop exp | unop exp 

prefix_exp ::= var | func_call | ‘(’ exp ‘)’

func_call ::=  prefix_exp args | prefix_exp ‘:’ Name args 

args ::=  ‘(’ [exp_list] ‘)’ | table_constructor | String 

functiondef ::= function func_body

func_body ::= ‘(’ [param_list] ‘)’ block end

param_list ::= name_list [‘,’ ‘...’] | ‘...’

table_constructor ::= ‘{’ [field_list] ‘}’

field_list ::= field {field_sep field} [field_sep]

field ::= ‘[’ exp ‘]’ ‘=’ exp | Name ‘=’ exp | exp

field_sep ::= ‘,’ | ‘;’

binop ::= ‘+’ | ‘-’ | ‘*’ | ‘/’ | ‘^’ | ‘%’ | ‘..’ | 
    ‘<’ | ‘<=’ | ‘>’ | ‘>=’ | ‘==’ | ‘~=’ | 
    and | or

unop ::= ‘-’ | not | ‘#’
```

# uh, some info

```
from AST:
  bind labels and gotos
    error if unmatched gotos
    warn if unmatched labels
  fold constants in expressions
  collapse constant ifs??
  replace control structures with bound goto/label sets
```

```
binop => left op right
unop => ex op
concat => exp_list
number|string|true|false|nil => value
constructor => fields
functiondef => index
call => ex args
selfcall => ex suffix args
index => ex suffix
```

# To Add

- `continue` keyword
- `!=` for `~=`
- `+=` `-=` `*=` `/=` `%=` `^=` composite assignment ops
  no multiple-assignment with these?
  parse to tree equivalent of LHS = LHS op ( RHS )
  `..=` can compose with a line of `..`
- `i++`
- `:[]()` operator for self-call by non-ident index
- `expr?.ident` `expr?[expr]` `expr?()` for safe-chaining
  `expr?:ident?(exp_list)` for SELF
- `^.` for `getmetatable()?.`
- `@` `@[]` for rawget()/rawset()
- `condition ?? exp_list :: exp_list` ternary op
  single `?` causes parsing difficulty with safe chaining ops
  single `:` causes parsing difficulty with self-call op
  foo?(bar):baz():baz()
- `local {foo, bar} = exp` table unpack as name in local statement
  declare extra local (unpack) for the table after all names with scope only until it's been used
  unpack the named fields into locals, discard intermediate table
  `foo as foo_bar` to rename?
- `(name_list)=>exp_list` for `function(name_list) return exp_list end`
- `if name_list = exp_list then` use first var as condition
    `if name_list = exp_list; condition then` explicit condition
    `while name_list = exp_list; condition do` while too?
switch/case?
    implement as `(({})[case] or default)()` ?
    allow `return switch`?
- `const name_list ‘=’ exp_list`, compile-time constant folding? prevent re-assignment, allow reuse of common sub_expressions
- `inline function` or `macro` at file or smaller scope
  not assignable
  no upvals?
- `static foo` vars for upvals only in scope for closure
  LOADNIL statics, then CLOSURE, then JMP to close them
- string interpolation?
  evaluate it all then do one big concat
  $"" or $[[]] like a function call of $
  turn into concat series, expressions in {} break out as code
  or `` and ${} like TS?
  tostring() sub expressions? or just let it error on non-string?
- branch annotations for coverage testing?
- compile time regex? builds to a function that uses patterns?
- numbers with `_`

type annotations, somehow? steal a bunch from TypeScript?
  compile time warning on assignment of incompatible types
  `expr!` to override deduction with assertion that T is not-nil
  `<T>expr` to override deduction with assertion that `expr` is `T`
  `Name:T` - this works fine in `local`, and in/after param lists.
  some way to declare type of a global? `global name:T`?
  or generally to declare a typed field into an existing table?
  `_ENV = <T>_ENV` with an interface?
  `T?`, `T|T`, `T&T`, `any`
  `interface T [extends U] { }`

# Maybe Add

`break :label:` and `continue :label:` where is somehow identifying a loop
  potentially by a label being the first thing in a loop
  or by there being a special way to "name" a block/loop

`--- @param field=1 number` would be a great way to show default optional values - Nexela
`--- @todo` look pretty and doesn't show up in hovers, the separation just irks me - Nexela
`---@usage` adds blank line above, indents following lines until empty comment line - Nexela
`---@deprecated` more support for table fields (strikethrough when using) - Nexela
