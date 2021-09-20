if get(s:, 'loaded', 0) != 0
    finish
else
    let s:loaded = 1
endif

let s:home = fnamemodify(resolve(expand('<sfile>:p')), ':h')
command! -nargs=1 LoadScript exec 'so '.s:home.'/'.'<args>'
exec 'set rtp+='.s:home
set rtp+=~/.vim

LoadScript init/init_base.vim
LoadScript init/init_ignores.vim
LoadScript init/init_keymaps.vim
LoadScript init/init_plugins.vim