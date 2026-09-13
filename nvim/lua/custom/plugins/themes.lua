vim.keymap.set('n', '<leader>tc', function()
  require('telescope.builtin').colorscheme {
    enable_preview = true,
    layout_config = { preview_cutoff = 512 },
  }
end, { desc = 'Telescope colorschemes' })

return {
  'rebelot/kanagawa.nvim',
  'EdenEast/nightfox.nvim',
  'catppuccin/nvim',
  'AlexvZyl/nordic.nvim',
  'felipeagc/fleet-theme-nvim',

  {
    'thesimonho/kanagawa-paper.nvim',
    config = function()
      require('kanagawa-paper').setup {
        terminal_colors = true,
      }
    end,
  },

  {
    'scottmckendry/cyberdream.nvim',
    lazy = false,
    priority = 1000,
    config = function()
      require('cyberdream').setup {
        transparent = false,
        borderless_pickers = true,
        cache = false,
        italic_comments = true,
        terminal_colors = true,
        saturation = 1,

        overrides = function(colors)
          return {
            -- default CursorLine = bg_highlight, too heavy; step down to bg_alt
            CursorLine = { bg = colors.bg_alt },
          }
        end,

        extensions = {
          default = true,
        },
      }
      -- vim.cmd 'colorscheme cyberdream'
    end,
  },

  {
    'shvdx/vesper.nvim',
    lazy = false,
    priority = 1000,
    -- config = function()
    --   require('vesper').setup { style = 'auto' }
    --   vim.cmd 'colorscheme vesper'
    -- end,
  },

  {
    'f-person/auto-dark-mode.nvim',
    config = true,
    opts = {
      update_interval = 1000,
      set_dark_mode = function()
        vim.api.nvim_set_option_value('background', 'dark', {})
        vim.cmd 'colorscheme kanagawa-paper'
      end,
      set_light_mode = function()
        vim.api.nvim_set_option_value('background', 'light', {})
        vim.cmd 'colorscheme dawnfox'
      end,
    },
  },
}
