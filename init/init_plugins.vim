call plug#begin('~/.vim/plugged')
Plug 'skywind3000/vim-auto-popmenu'
Plug 'skywind3000/vim-dict'
Plug 'skywind3000/asyncrun.vim'

Plug 'morhetz/gruvbox'

Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'

Plug 'OmniSharp/omnisharp-vim'
Plug 'prabirshrestha/asyncomplete.vim'
call plug#end()

colorscheme gruvbox
set background=dark

let g:apc_enable_ft = {'text':1, 'lua':1, 'word':1, 'cs':1}
set cpt=.,k,w,b
set completeopt=menu,menuone,noselect
set shortmess+=c


" asyncomplete {{{
let g:asyncomplete_auto_popup=1
let g:asyncomplete_auto_completeopt=0
" }}}

" omnisharp {{{
let g:OmniSharp_start_server=1
let g:OmniSharp_server_stdio=1
let g:OmniSharp_selector_findusages='fzf'
let g:OmniSharp_selector_ui='fzf'
let g:OmniSharp_server_use_mono=1

augroup omnisharp_cmd
    autocmd FileType cs nmap <silent> <buffer> gd <Plug>(omnisharp_go_to_definition)
augroup END
" }}}

