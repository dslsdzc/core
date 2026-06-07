" Core compiler integration for Vim/Neovim
" Usage:
"   :make          -> runs corec on current file, populates quickfix
"   :make check    -> type-check only (fast)
"   :make ir       -> generate .cir (dataflow graph)
"   :make run      -> compile and run via interpreter (-c mode)
"
" Error format (self-hosted compiler):
"   error CODE: MESSAGE
"     --> LINE:COL
"
" Error format (Python bootstrap):
"   FILE:LINE:COL:error: MESSAGE

if exists("current_compiler")
  finish
endif
let current_compiler = "core"

if exists(":CompilerSet") != 2
  command -nargs=* CompilerSet setlocal <args>
endif

" Multi-line error format
CompilerSet errorformat=
    \%Eerror\ %n:\ %m,
    \%C\ \ -->\ %l:%c,
    \%Z%.%#,
    \%f:%l:%c:%trror:\ %m,
    \%f:%l:%c:%tarning:\ %m

" Find the project root (build/ is always at repo root)
let s:root = fnamemodify(finddir("build", ".;"), ":p:h:h")
if empty(s:root)
  let s:root = getcwd()
endif

let s:corec = s:root . '/build/corec'
let s:tools = s:root . '/tools/corec'
let s:python = exists('g:core_python') ? g:core_python : 'python3'

" Main makeprg: detect available compiler
if filereadable(s:corec)
  CompilerSet makeprg=" . s:corec . "\ \"%:p\""
elseif filereadable(s:tools)
  CompilerSet makeprg=" . s:python . "\ " . s:tools . "\ build\ \"%:p\"\ -o\ /dev/null"
else
  CompilerSet makeprg=corec\ \"%:p\"
endif

" Variant: --check mode (type-check only)
function! s:set_make_check()
  if filereadable(s:corec)
    let &l:makeprg = s:corec . ' --check "%:p"'
  elseif filereadable(s:tools)
    let &l:makeprg = s:python . ' ' . s:tools . ' build "%:p" -o /dev/null'
  endif
endfunction

command! -buffer MakeCheck call s:set_make_check() | make

" Statusline indicator
let b:core_compiler = filereadable(s:corec) ? 'corec' : 'bootstrap'
