-- plugin/orbit.lua
--
-- This is the plugin's entrypoint. Any file that lives under a plugin's
-- top-level `plugin/` directory is automatically sourced ("run") by Neovim
-- at startup, without the user needing to `require` it themselves -- this
-- is a Neovim/Vim plugin convention, not something specific to Orbit. Its
-- only job is to guard against being loaded twice and then kick off the
-- real setup in lua/orbit/init.lua.
--
-- This module has no exports (it returns nothing) -- it's a script, not a
-- library.

-- vim.g is Neovim's table of global (g:) Vim variables. Plugins commonly
-- set a `loaded_<name>` flag here as a guard: if this file somehow gets
-- sourced more than once (e.g. via `:runtime` or a plugin manager quirk),
-- this check makes every run after the first a no-op instead of
-- re-registering commands/autocommands/highlights a second time.
if vim.g.loaded_orbit_nvim then
  return
end
vim.g.loaded_orbit_nvim = true

-- Calling setup() with no arguments here means Orbit starts up with its
-- built-in defaults (see M.config in lua/orbit/init.lua) even if the user
-- never calls `require("orbit").setup()` themselves in their own config.
-- If the user *does* call setup() later with their own options, that call
-- simply re-applies configuration on top of what's already been set up
-- (M.setup in init.lua is written to be safe to call more than once).
require("orbit").setup()
