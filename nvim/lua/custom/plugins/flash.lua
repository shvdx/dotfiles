return {
  {
    'folke/flash.nvim',
    event = 'VeryLazy',
    ---@type Flash.Config
    opts = {
      modes = {
        -- f/t: label each match => type label to jump there
        char = { jump_labels = true },
      },
    },
    keys = {},
  },
}
