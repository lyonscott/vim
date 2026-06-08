vim.pack.add({
  'https://codeberg.org/andyg/leap.nvim',
}, { confirm = false })

vim.keymap.set({ 'n', 'x', 'o' }, 's', '<Plug>(leap-forward)')
vim.keymap.set({ 'n', 'x', 'o' }, 'S', '<Plug>(leap-backward)')
vim.keymap.set({ 'x', 'o' }, 'x', '<Plug>(leap-forward-till)')
vim.keymap.set({ 'x', 'o' }, 'X', '<Plug>(leap-backward-till)')
vim.keymap.set({ 'n', 'x', 'o' }, 'gs', '<Plug>(leap-from-window)')
