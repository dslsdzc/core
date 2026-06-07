" Core language filetype plugin for Vim/Neovim
" Extended IDE features: diagnostics, keymaps, tab settings

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

" --- Editor settings ---
setlocal tabstop=4
setlocal shiftwidth=4
setlocal expandtab
setlocal softtabstop=4
setlocal textwidth=100

" Comments
setlocal commentstring=//\ %s
setlocal comments=://

" Format with 'gq'
setlocal formatoptions-=t
setlocal formatoptions+=croqj

" Include matchit for % navigation
if exists("loaded_matchit")
  let b:match_words = '\<if\>:\<else\>'
  let b:match_skip = 's:comment\|string'
endif

" --- Compiler integration ---
if exists(":CompilerSet") != 2
  compiler core
endif

" Keymaps for IDE features (buffer-local)
nnoremap <buffer> <silent> K    :call CoreHover()<CR>
nnoremap <buffer> <silent> gd   :call CoreDef()<CR>
nnoremap <buffer> <silent> ]e   :lnext<CR>
nnoremap <buffer> <silent> [e   :lprev<CR>

" Helper: show hover info (fallback when Lua plugin not loaded)
function! CoreHover()
  if exists("*luaeval")
    call luaeval("require('core').show_hover_info()")
  else
    echohl Title | echo "Core: " . expand("<cword>") | echohl None
  endif
endfunction

function! CoreDef()
  if exists("*luaeval")
    call luaeval("require('core').goto_definition()")
  else
    execute "normal! /\\<" . expand("<cword>") . "\\>\<CR>zz"
  endif
endfunction

" Auto-open quickfix after :make
augroup core_qf
  au!
  au QuickFixCmdPost make botright copen 6
augroup END
