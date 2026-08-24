if vim.g.loaded_orbit_nvim then
  return
end
vim.g.loaded_orbit_nvim = true

require("orbit").setup()
