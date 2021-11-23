" setting
set nocompatible
set bs=eol,start,indent
set winaltkeys=no
set nowrap
set autoindent
set ttimeout
set ttimeoutlen=50
set ruler
if has('multi_byte')
    set encoding=utf-8
    set fileencoding=utf-8
    set fileencodings=ucs-bom,utf-8,gbk,gb18030
    scriptencoding utf-8
endif

set number
set ignorecase
set smartcase
set hlsearch
set incsearch
set expandtab
set tabstop=4
set softtabstop=4
set shiftwidth=4
set textwidth=80
set wrap
set relativenumber
set showcmd
set showmatch
set matchtime=2
set guifont=Cascadia\ Code:h10
set lazyredraw
set cursorline

if has('folding')
    set foldenable
    set fdm=indent
    set foldlevel=99
endif

set matchpairs=(:),{:},[:],<:>
nmap <c-;> %

" backup
set backup
set writebackup
set backupext=.bak
set swapfile
set undofile
set backupdir=~/.vim/.backup//
set directory=~/.vim/.swp//
set undodir=~/.vim/.undo// 

highlight ColorColumn ctermbg=magenta
call matchadd('ColorColumn', '\%81v', 100)
