-- You can add your own plugins here or in other files in this directory!
--  I promise not to create any merge conflicts in this directory :)
--
-- See the kickstart.nvim README for more information

vim.o.winborder = 'rounded'
vim.go.pumborder = 'rounded'
vim.opt.cmdheight = 0

return {
  'ThePrimeagen/vim-be-good',
  'williamboman/mason.nvim',
  'mg979/vim-visual-multi',

  -- {
  --   'cordx56/rustowl',
  --   version = '*',
  --   build = 'cargo install --locked rustowl',
  --   lazy = false,
  --   opts = {},
  -- },
}
