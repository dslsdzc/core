" Core IR (.cir / .ccr) syntax highlighting for Vim/Neovim
if exists("b:current_syntax")
  finish
endif

" Comments (; style for IR)
syn match irComment ";.*$"

" Keywords
syn keyword irKeyword Function Block contained

" IR Instructions
syn keyword irInstruction ConstInstr BinaryInstr UnaryInstr CallInstr
syn keyword irInstruction ReturnInstr BranchInstr JumpInstr AllocInstr
syn keyword irInstruction StoreInstr LoadInstr LoadFieldInstr StoreFieldInstr
syn keyword irInstruction MakeEnumInstr AllocStructInstr AllocArrayInstr
syn keyword irInstruction LoadIndexInstr StoreIndexInstr
syn keyword irInstruction LoadIndexVarInstr StoreIndexVarInstr
syn keyword irInstruction PhiInstr LabelInstr RefInstr DerefInstr
syn keyword irInstruction StorePtrInstr LoadEnumTagInstr SliceInstr
syn keyword irInstruction MoveInstr

" Labels (identifier at start of line followed by colon)
syn match irLabel "^[ \t]*[a-zA-Z_][a-zA-Z0-9_]*:"

" Numbers
syn match irNumber "\<[0-9]\+\>"

" Strings (double-quoted)
syn region irString start=+"+ skip=+\\\\\|\\"+ end=+"+

" Operators
syn match irOperator "->\|=>\|::\|&&\|||\|==\|!=\|<=\|>=\|[+\-*/%=<>!&|?]"

hi def link irComment     Comment
hi def link irKeyword     Keyword
hi def link irInstruction Function
hi def link irLabel       Label
hi def link irNumber      Number
hi def link irString      String
hi def link irOperator    Operator

let b:current_syntax = "coreir"
