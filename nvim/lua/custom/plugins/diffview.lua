return {
  {
    'sindrets/diffview.nvim',
    cmd = { 'DiffviewOpen', 'DiffviewFileHistory' },
    keys = {
      { '<leader>gv', '<cmd>DiffviewOpen<cr>', desc = 'git diff[v]iew' },
      { '<leader>gh', '<cmd>DiffviewFileHistory %<cr>', desc = 'git file [h]istory' },
    },
    opts = {
      keymaps = {
        view = {
          { 'n', 'q', '<cmd>DiffviewClose<cr>', { desc = 'close diffview' } },
          { 'n', 'X', '<cmd>DiffviewClose<cr>', { desc = 'close diffview' } }, -- global X => Snacks.bufdelete
        },
        file_panel = {
          { 'n', 'q', '<cmd>DiffviewClose<cr>', { desc = 'close diffview' } },
          { 'n', 'X', '<cmd>DiffviewClose<cr>', { desc = 'close diffview' } }, -- replaces restore_entry
        },
        file_history_panel = {
          { 'n', 'q', '<cmd>DiffviewClose<cr>', { desc = 'close diffview' } },
          { 'n', 'X', '<cmd>DiffviewClose<cr>', { desc = 'close diffview' } }, -- replaces restore_entry
        },
      },
    },
  },
}
