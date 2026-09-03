-- orbit/diagnostics.lua
--
-- Responsible for showing longer, read-only diagnostic/error text to the user
-- in a small scratch window, rather than as a one-line vim.notify() popup.
-- Other Orbit modules (e.g. the query runner) call M.open(message) when they
-- have a multi-line error or explanation that wouldn't fit nicely in a
-- notification. This module doesn't know anything about SQL, connections, or
-- profiles -- it's purely a small UI helper.
--
-- Exports:
--   M.open(message) -- opens a bottom split showing `message`, closable with "q"
local M = {}

-- Opens a small, read-only "scratch" window at the bottom of the screen and
-- fills it with `message` so the user can read a longer diagnostic (for
-- example a full error from a database driver) without it disappearing like
-- a notification would.
--
-- Parameters:
--   message (string) - the text to display. Lines are split on "\n".
--
-- Returns: nothing.
--
-- Side effects:
--   - Creates a new unlisted, scratch Neovim buffer (nvim_create_buf).
--   - Opens a new bottom split window (":botright new") and puts the buffer
--     into it.
--   - Sets the buffer's filetype to "orbit-diagnostic" and marks it
--     non-modifiable so the user can't accidentally edit the diagnostic text.
--   - Registers a buffer-local normal-mode keymap on "q" that closes the
--     window when pressed.
function M.open(message)
  -- vim.api.nvim_create_buf(listed, scratch):
  --   listed = false  -> buffer won't show up in :ls / buffer lists
  --   scratch = true  -> buffer isn't tied to a file, safe throwaway buffer
  local buffer = vim.api.nvim_create_buf(false, true)

  -- vim.split breaks the message into a table of lines on "\n" (plain-text
  -- split, not a Lua pattern, because `plain = true`). nvim_buf_set_lines
  -- then replaces the *entire* buffer (0 to -1 means "from the first line to
  -- the last line") with those lines.
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(message, "\n", { plain = true }))

  -- vim.bo[buffer] lets us set buffer-local options by buffer handle rather
  -- than by having the buffer be the "current" one. filetype is set to a
  -- custom value in case a user wants to add their own syntax highlighting;
  -- modifiable = false prevents accidental edits to what is just a message.
  vim.bo[buffer].filetype = "orbit-diagnostic"
  vim.bo[buffer].modifiable = false

  -- ":botright new" opens a brand new empty window split at the very bottom
  -- of the current tab, and makes it the current window.
  vim.cmd("botright new")
  local window = vim.api.nvim_get_current_win()
  -- Attach our scratch buffer to that new window instead of the default
  -- empty buffer Vim would have created for it.
  vim.api.nvim_win_set_buf(window, buffer)

  -- Size the window to fit the content: at least 3 lines tall so it's never
  -- too cramped, but never more than 10 lines tall so a huge error message
  -- doesn't take over the whole screen.
  vim.api.nvim_win_set_height(window, math.min(10, math.max(3, #vim.api.nvim_buf_get_lines(buffer, 0, -1, false))))

  -- Give the user an easy, familiar way to dismiss the window: pressing "q"
  -- in normal mode while this buffer is focused closes just this window.
  -- `buffer = buffer` scopes the mapping to this buffer only (it won't leak
  -- into other buffers), and the second `true` to nvim_win_close forces the
  -- close even if it's the last window in the tab.
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(window, true)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit diagnostic" })
end

return M
