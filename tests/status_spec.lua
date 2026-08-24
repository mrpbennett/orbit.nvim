local orbit = require("orbit")

return {
  ["orbit.status identifies the active query profile"] = function()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.b[buffer].orbit_profile = "analytics"

    assert(orbit.status(buffer) == "Orbit: analytics")
  end,
}
