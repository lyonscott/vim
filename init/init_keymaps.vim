" keymaps
let mapleader=" "
nmap <leader>w :w!<CR>
nmap <leader>/ :noh<CR>
nmap <leader>qq :q!<CR>
nmap <c-h> <home>
nmap <c-l> <end>
nmap <c-j> 5j
nmap <c-k> 5k

imap <c-h> <left>
imap <c-l> <right>
imap <c-j> <down>
imap <c-k> <up>

" window
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

" tab
nmap <silent>\= :tabnew<cr>
nmap <silent>\- :tabclose<cr>
nmap <silent>\[ :tabprev<cr>
nmap <silent>\] :tabnext<cr>
nmap <silent>\\ :tabnext<cr>

nmap <leader>r :AsyncRun -mode=term 
nmap <leader>p :Files<CR>
nmap <leader>o :Buffers<CR>
nmap <leader>f :Ag<CR>
nmap <leader>g :BLines<CR>
nmap <leader>v :BCommits<CR>