call plug#begin('~/.vim/plugged')
Plug 'skywind3000/vim-auto-popmenu'
Plug 'skywind3000/vim-dict'
Plug 'skywind3000/asyncrun.vim'
Plug 'morhetz/gruvbox'
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'
call plug#end()


colorscheme gruvbox
set background=dark

let g:apc_enable_ft = {'text':1, 'lua':1, 'word':1, 'cs':1}
set cpt=.,k,w,b
set completeopt=menu,menuone,noselect
set shortmess+=c
