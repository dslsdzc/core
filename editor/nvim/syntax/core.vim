" Core language syntax highlighting for Vim/Neovim
" Rust-style keyword grouping and highlight links
" Based on rust.vim structure
" Install: copy to ~/.config/nvim/syntax/core.vim (or use :setfiletype core)

if exists("b:current_syntax")
  finish
endif

" Syntax definitions {{{1
" Conditional keywords {{{2
syn keyword coreConditional if else match

" Repeat keywords {{{2
syn keyword coreRepeat for while loop in

" Structure keywords {{{2
syn keyword coreStructure struct enum impl interface

" General keywords {{{2
syn keyword coreKeyword fn return break continue pub type mod fileid
syn keyword coreKeyword go await flow auto requires ensures

" Import keywords {{{2
syn keyword coreInclude import as

" Storage keywords {{{2
syn keyword coreStorage mut move

" Unsafe {{{2
syn keyword coreUnsafeKeyword unsafe

" Self {{{2
syn keyword coreSelf self

" Built-in types {{{2
syn keyword coreType Self int float bool string char unit never

" Enum variants {{{2
syn keyword coreEnumVariant None Some

" Spec language identifiers (requires/ensures) {{{2
syn keyword coreSpecial old result

" Boolean literals {{{2
syn keyword coreBoolean true false

" Wildcard pattern {{{2
syn keyword coreWildcard _

" Comments {{{2
syn keyword coreTodo TODO FIXME XXX NB NOTE HACK contained
syn match coreComment "//.*$" contains=coreTodo,@Spell
syn region coreComment start="/\*" end="\*/" contains=coreTodo,@Spell

" Strings (double-quoted) {{{2
syn region coreString start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=coreEscape,@Spell
syn match coreEscape '\\[nrt0\\'"]' contained
syn match coreEscape "\\x[0-9a-fA-F]\{2}" contained

" Characters (single-quoted) {{{2
syn match coreChar "'\(\\[^']\|[^'\\]\)'"

" Numbers {{{2
syn match coreInteger "\<[0-9_]\+\%([iIuU]\?[0-9]*\)\=\>"
syn match coreInteger "\<[0-9_]\+\%(i8\|i16\|i32\|i64\|u8\|u16\|u32\|u64\)\>"
syn match coreInteger "\<0x[0-9a-fA-F_]\+\%([iIuU]\?[0-9]*\)\=\>"
syn match coreFloat  "\<[0-9_]\+\.[0-9_]\+\%(f32\|f64\)\=\>"

" Module path access (@acme and ::) {{{2
syn match coreModPath "@[a-zA-Z_][a-zA-Z0-9_]*"
syn match coreModPathSep "::"

" Operators {{{2
syn match coreOperator "->"
syn match coreOperator "=>"
syn match coreOperator "\.\."
syn match coreOperator "&&"
syn match coreOperator "||"
syn match coreOperator "=="
syn match coreOperator "!="
syn match coreOperator "<="
syn match coreOperator ">="
syn match coreOperator ":="
syn match coreOperator "\%(+=\|-=\|*=\|/=\)"
syn match coreOperator "[+\-*%=<>!&|?]"
" / not followed by // or /* (avoids clashing with comments)
syn match coreOperator "/\%(/\|\*\)\@!"

" Function calls: identifier followed by ( {{{2
syn match coreFuncCall "\k\+\%((\)\@="
syn match coreFuncCall "\k\+::<"

" Identifiers (catch-all, must be after keywords) {{{2
syn match coreIdentifier "\<[a-zA-Z_][a-zA-Z0-9_]*\>"

" Default highlighting {{{1
hi def link coreConditional   Conditional
hi def link coreRepeat        Conditional
hi def link coreStructure     Keyword
hi def link coreKeyword       Keyword
hi def link coreInclude       Include
hi def link coreStorage       StorageClass
hi def link coreUnsafeKeyword Exception
hi def link coreSelf          Constant
hi def link coreType          Type
hi def link coreEnumVariant   Constant
hi def link coreSpecial       Special
hi def link coreBoolean       Boolean
hi def link coreWildcard      Constant
hi def link coreTodo          Todo
hi def link coreComment       Comment
hi def link coreString        String
hi def link coreEscape        Special
hi def link coreChar          Character
hi def link coreInteger       Number
hi def link coreFloat         Float
hi def link coreModPath       Include
hi def link coreModPathSep    Delimiter
hi def link coreOperator      Operator
hi def link coreFuncCall      Function
hi def link coreIdentifier    Identifier

let b:current_syntax = "core"
