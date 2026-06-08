vim.opt.compatible = false

vim.opt.ttimeout = true
vim.opt.ttimeoutlen = 50
vim.opt.winaltkeys = 'no'
vim.opt.backspace = { 'eol', 'start', 'indent' }

vim.opt.guifont = 'Cascadia Code SemiLight:h14'
if vim.fn.has('multi_byte') == 1 then
  vim.opt.encoding = 'utf-8'
  vim.opt.fileencoding = 'utf-8'
  vim.opt.fileencodings = { 'ucs-bom', 'utf-8', 'gbk', 'gb18030' }
end

vim.opt.autoindent = true
vim.opt.cindent = true
vim.opt.expandtab = true
vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.shiftwidth = 2
vim.opt.textwidth = 100

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.wrap = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.showmatch = true
vim.opt.matchtime = 2
vim.opt.matchpairs:append({ '(:)', '{:}', '[:]', '<:>' })

vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'c', 'cpp', 'cs' },
  callback = function()
    vim.opt_local.matchpairs:append('=:;')
  end,
})

vim.opt.lazyredraw = true
vim.opt.cursorline = true
vim.opt.ruler = true
if vim.fn.has('folding') == 1 then
  vim.opt.foldenable = true
  vim.opt.foldmethod = 'indent'
  vim.opt.foldlevel = 99
end

vim.opt.backup = true
vim.opt.writebackup = true
vim.opt.backupext = '.bak'
vim.opt.swapfile = true
vim.opt.undofile = true
vim.opt.backupdir = vim.fn.expand('~/.vim/.backup//')
vim.opt.directory = vim.fn.expand('~/.vim/.swp//')
vim.opt.undodir = vim.fn.expand('~/.vim/.undo//')

vim.opt.suffixes = { '.bak', '~', '.o', '.h', '.info', '.swp', '.obj', '.pyc', '.pyo', '.egg-info', '.class' }
vim.opt.wildignore = {
  '*.o',
  '*.obj',
  '*~',
  '*.exe',
  '*.a',
  '*.pdb',
  '*.lib',
  '*.so',
  '*.dll',
  '*.swp',
  '*.egg',
  '*.jar',
  '*.class',
  '*.pyc',
  '*.pyo',
  '*.bin',
  '*.dex',
  '*.zip',
  '*.7z',
  '*.rar',
  '*.gz',
  '*.tar',
  '*.gzip',
  '*.bz2',
  '*.tgz',
  '*.xz',
  '*DS_Store*',
  '*.ipch',
  '*.gem',
  '*.png',
  '*.jpg',
  '*.gif',
  '*.bmp',
  '*.tga',
  '*.pcx',
  '*.ppm',
  '*.img',
  '*.iso',
  '*/.Trash/**',
  '*.pdf',
  '*.dmg',
  '*/.rbenv/**',
  '*/.nx/**',
  '*.app',
  '*.git',
  '.git',
  '*.wav',
  '*.mp3',
  '*.ogg',
  '*.pcm',
  '*.mht',
  '*.suo',
  '*.sdf',
  '*.jnlp',
  '*.chm',
  '*.epub',
  '*.mobi',
  '*.ttf',
  '*.mp4',
  '*.avi',
  '*.flv',
  '*.mov',
  '*.mkv',
  '*.swf',
  '*.swc',
  '*.ppt',
  '*.pptx',
  '*.docx',
  '*.xlt',
  '*.xls',
  '*.xlsx',
  '*.odt',
  '*.wps',
  '*.msi',
  '*.crx',
  '*.deb',
  '*.vfd',
  '*.apk',
  '*.ipa',
  '*.msu',
  '*.gba',
  '*.sfc',
  '*.078',
  '*.nds',
  '*.smd',
  '*.smc',
  '*.linux2',
  '*.win32',
  '*.darwin',
  '*.freebsd',
  '*.linux',
  '*.android',
}

vim.g.mapleader = ' '

local function map(mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, vim.tbl_extend('force', { remap = true }, opts or {}))
end

local function nmap(lhs, rhs, opts)
  map('n', lhs, rhs, opts)
end

nmap('<leader>w', ':w!<CR>')
nmap('<leader>/', ':noh<CR>')
nmap('<leader>qq', ':q!<CR>')

nmap('<C-h>', '<Home>')
nmap('<C-l>', '<End>')
nmap('<C-j>', '5j')
nmap('<C-k>', '5k')

map('i', '<C-h>', '<Left>')
map('i', '<C-l>', '<Right>')
map('i', '<C-j>', '<Down>')
map('i', '<C-k>', '<Up>')

nmap('<Tab>h', '<C-w>h')
nmap('<Tab>j', '<C-w>j')
nmap('<Tab>k', '<C-w>k')
nmap('<Tab>l', '<C-w>l')
nmap('<Tab>-', '<C-w>-')
nmap('<Tab>+', '<C-w>+')
nmap('<Tab>,', '<C-w><')
nmap('<Tab>.', '<C-w>>')
nmap('<Tab>=', '<C-w>=')
nmap('<Tab><Tab>', '<C-w>p')

nmap('\\=', ':tabnew<CR>', { silent = true })
nmap('\\-', ':tabclose<CR>', { silent = true })
nmap('\\[', ':tabprev<CR>', { silent = true })
nmap('\\]', ':tabnext<CR>', { silent = true })
nmap('\\\\', ':tabnext<CR>', { silent = true })
map('t', '<Esc>', '<C-\\><C-n>', { remap = false })

nmap('<leader>fw', '*')

map('i', '<C-u>', '<Esc>viwUwa')
nmap('<C-u>', 'viwUw')
