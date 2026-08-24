if vim.g.loaded_quarry_nvim then
  return
end
vim.g.loaded_quarry_nvim = true

require("quarry").setup()
