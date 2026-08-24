local quarry = require("quarry")

return {
  ["quarry.status identifies the active query profile"] = function()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.b[buffer].quarry_profile = "analytics"

    assert(quarry.status(buffer) == "Quarry: analytics")
  end,
}
