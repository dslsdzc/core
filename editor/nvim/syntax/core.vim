" Core language syntax highlighting for Vim/Neovim
" Based on the VS Code TextMate grammar (src/editor/vscode-core/)
" Install: copy to ~/.config/nvim/syntax/core.vim (or use :setfiletype core)

if exists("b:current_syntax")
  finish
endif

" Keywords (control flow)
syn keyword coreKeyword fn struct enum interface impl type mut move
syn keyword coreKeyword go await if else match for while loop
syn keyword coreKeyword return break continue pub mod import as unsafe
syn keyword coreKeyword fileid auto in
syn keyword coreKeyword requires ensures

" Other keywords / special identifiers
syn keyword coreSpecial self old result None Some

" Types
syn keyword coreType Self int float bool string char unit never

" Boolean & unit literals
syn keyword coreBoolean true false
syn keyword coreUnit _

" Comments
syn match coreComment "//.*$" contains=@Spell
syn region coreComment start="/\*" end="\*/" contains=@Spell

" Strings (double-quoted)
syn region coreString start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=coreEscape
syn match coreEscape '\\[0nrt"\\]' contained
syn match coreEscape "\\x[0-9a-fA-F]\{2}" contained

" Characters (single-quoted)
syn match coreChar "'\(\\[^']\|[^'\\]\)'"

" Numbers
syn match coreInteger "\<[0-9_]\+\%([iIuU]\?[0-9]*\)\=\>"
syn match coreInteger "\<[0-9_]\+\%(i8\|i16\|i32\|i64\|u8\|u16\|u32\|u64\)\>"
syn match coreFloat "\<[0-9_]\+\.[0-9_]\+\%(f32\|f64\)\=\>"

" Project access (@acme)
syn match coreProject "@[a-zA-Z_][a-zA-Z0-9_]*"

" Operators
syn match coreOperator "->"
syn match coreOperator "=>"
syn match coreOperator "::"
syn match coreOperator "&&"
syn match coreOperator "||"
syn match coreOperator "=="
syn match coreOperator "!="
syn match coreOperator "<="
syn match coreOperator ">="
syn match coreOperator ":="
syn match coreOperator "\%(+=\|-=\|*=\|/=\)"
syn match coreOperator "[+\-*/%=<>!&|?]"

" Identifiers (catch-all, must be after keywords)
syn match coreIdentifier "\<[a-zA-Z_][a-zA-Z0-9_]*\>"

" Function calls: identifier followed by (
syn match coreFuncCall "\k\+\%((\)\@="

" Standard highlight links
hi def link coreKeyword      Keyword
hi def link coreSpecial      Special
hi def link coreType          Type
hi def link coreBoolean       Boolean
hi def link coreUnit          Constant
hi def link coreComment       Comment
hi def link coreString        String
hi def link coreEscape        SpecialChar
hi def link coreChar          Character
hi def link coreInteger       Number
hi def link coreFloat         Float
hi def link coreProject       PreProc
hi def link coreOperator      Operator
hi def link coreIdentifier    Normal
hi def link coreFuncCall      Function

let b:current_syntax = "core"
