-- fff: file search + grep; replaces telescope's <leader>sf/sg/sw/sn
return {
  'dmtrKovalenko/fff',
  build = function()
    -- downloads a prebuilt binary or falls back to cargo build
    require('fff.download').download_or_build_binary()
  end,
  opts = {},
  lazy = false, -- the plugin lazy-initialises itself
  keys = {
    {
      '<leader>sf',
      function()
        require('fff').find_files()
      end,
      desc = '[S]earch [F]iles',
    },
    {
      '<leader>sg',
      function()
        require('fff').live_grep()
      end,
      desc = '[S]earch by [G]rep',
    },
    {
      '<leader>sw',
      function()
        require('fff').live_grep_under_cursor()
      end,
      mode = { 'n', 'x' }, -- n => <cword>, x => selection
      desc = '[S]earch current [W]ord',
    },
    {
      '<leader>sn',
      function()
        require('fff').find_files_in_dir(vim.fn.stdpath 'config')
      end,
      desc = '[S]earch [N]eovim files',
    },
  },
}
