"#BASIC
set nocompatible

"##KEY BEHAVIOUR
set ttimeout
set ttimeoutlen=50
set winaltkeys=no
set bs=eol,start,indent

"##ENCODE
set guifont=Cascadia\ Code:h10
if has('multi_byte')
    set encoding=utf-8
    set fileencoding=utf-8
    set fileencodings=ucs-bom,utf-8,gbk,gb18030
    scriptencoding utf-8
endif

"##INDENT
set autoindent
set cindent
set expandtab
set tabstop=2
set softtabstop=2
set shiftwidth=2
set textwidth=92

"##LOCATE
set number
set relativenumber
set wrap
set ignorecase
set smartcase
set hlsearch
set incsearch
set showmatch
set matchtime=2
set matchpairs+=(:),{:},[:],<:>
au FileType c,cpp,cs set mps+==:;

"##DRAW
set lazyredraw
set cursorline
set ruler
if has('folding')
  set foldenable
  set fdm=indent
  set foldlevel=99
endif

"##BACKUP
set backup
set writebackup
set backupext=.bak
set swapfile
set undofile
set backupdir=~/.vim/.backup//
set directory=~/.vim/.swp//
set undodir=~/.vim/.undo// 

"##PERFORMANCE
set suffixes=.bak,~,.o,.h,.info,.swp,.obj,.pyc,.pyo,.egg-info,.class
set wildignore=*.o,*.obj,*~,*.exe,*.a,*.pdb,*.lib "stuff to ignore when tab completing
set wildignore+=*.so,*.dll,*.swp,*.egg,*.jar,*.class,*.pyc,*.pyo,*.bin,*.dex
set wildignore+=*.zip,*.7z,*.rar,*.gz,*.tar,*.gzip,*.bz2,*.tgz,*.xz    " MacOSX/Linux
set wildignore+=*DS_Store*,*.ipch
set wildignore+=*.gem
set wildignore+=*.png,*.jpg,*.gif,*.bmp,*.tga,*.pcx,*.ppm,*.img,*.iso
set wildignore+=*.so,*.swp,*.zip,*/.Trash/**,*.pdf,*.dmg,*/.rbenv/**
set wildignore+=*/.nx/**,*.app,*.git,.git
set wildignore+=*.wav,*.mp3,*.ogg,*.pcm
set wildignore+=*.mht,*.suo,*.sdf,*.jnlp
set wildignore+=*.chm,*.epub,*.pdf,*.mobi,*.ttf
set wildignore+=*.mp4,*.avi,*.flv,*.mov,*.mkv,*.swf,*.swc
set wildignore+=*.ppt,*.pptx,*.docx,*.xlt,*.xls,*.xlsx,*.odt,*.wps
set wildignore+=*.msi,*.crx,*.deb,*.vfd,*.apk,*.ipa,*.bin,*.msu
set wildignore+=*.gba,*.sfc,*.078,*.nds,*.smd,*.smc
set wildignore+=*.linux2,*.win32,*.darwin,*.freebsd,*.linux,*.android

"#KEYMAPS
let mapleader=" "
nmap <leader>w :w!<CR>
nmap <leader>/ :noh<CR>
nmap <leader>qq :q!<CR>

"##WORD NAVIGATION
nmap <c-h> <home>
nmap <c-l> <end>
nmap <c-j> 5j
nmap <c-k> 5k

imap <c-h> <left>
imap <c-l> <right>
imap <c-j> <down>
imap <c-k> <up>

"##WINDOW
nmap <tab>h <c-w>h
nmap <tab>j <c-w>j
nmap <tab>k <c-w>k
nmap <tab>l <c-w>l
nmap <tab>- <c-w>-
nmap <tab>+ <c-w>+
nmap <tab>, <c-w><
nmap <tab>. <c-w>>
nmap <tab>= <c-w>=
nmap <tab><tab> <c-w>p

"##BUFFER NAVIGATION
nmap <silent>\= :tabnew<cr>
nmap <silent>\- :tabclose<cr>
nmap <silent>\[ :tabprev<cr>
nmap <silent>\] :tabnext<cr>
nmap <silent>\\ :tabnext<cr>
tnoremap <Esc> <c-\><c-n>

nmap <leader>p :Files<cr>
nmap <leader>o :Buffers<cr>
nmap <leader>ff :Rg<cr>
nmap <leader>g :BLines<cr>
nmap <leader>v :BCommits<cr>
nmap <leader>fw *
nmap <leader>l :source<cr>

"#PLUGINS
call plug#begin('~/.vim/plugged')
Plug 'neovim/nvim-lspconfig'
Plug 'ggandor/leap.nvim'
Plug 'morhetz/gruvbox'
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'
Plug 'skywind3000/vim-auto-popmenu'
Plug 'skywind3000/vim-dict'
call plug#end()

"##SCHEME
colorscheme gruvbox
set background=dark

"##LEAP
lua require('leap').add_default_mappings()

"##FZF
let g:fzf_layout = { 'down': '~40%' }
let g:fzf_history_dir = '~/.local/share/fzf-histroy'
let g:fzf_action={
  \ 'ctrl-t': 'tab split',
  \ 'ctrl-x': 'split',
  \ 'ctrl-v': 'vsplit' }

"##DICT
let g:apc_enable_ft = {'h':1, 'text':1, 'cpp':1, 'c':1, 'lua':1, 'word':1, 'cs':1}
set cpt=.,k,w,b
set completeopt=menu,menuone,noselect
set shortmess+=c

"#BETTER CODING FUNCTIONS
"##QUICKFIX LIST
function! s:qflist__mark_line()
  let l:file = expand('%')
  let l:line = line(".")
  let l:info = getline(".")
  call setqflist([{'filename':l:file, 'lnum':l:line, 'text':l:info}], 'a')
  copen
  wincmd p 
endfunction
nmap <silent> <leader>m :call <SID>qflist__mark_line()<cr>

"##CONVERT A WORD TO UPPERCASE
imap <c-u> <esc>viwUwa
nmap <c-u> viwUw
imap <c-n> <esc>viwuwa
nmap <c-n> viwuw

"##LSP
lua require 'lspconfig'.clangd.setup{}
nmap <silent> ? :lua vim.diagnostic.open_float()<cr>
