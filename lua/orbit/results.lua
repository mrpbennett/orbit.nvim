-- orbit/results.lua
--
-- This module owns the "results" scratch buffer/window: the split at the
-- bottom of a tabpage that shows the rows returned by a SQL query (or a
-- sampled table from the workspace sidebar), formatted as a plain-text grid.
--
-- It does NOT know how to talk to a database, and it does NOT know how to
-- format a table of rows into aligned text columns -- both of those jobs are
-- delegated to other modules:
--   * orbit/grid.lua           - turns Lua row tables into an aligned,
--                                 truncated text grid (columns/widths/lines)
--                                 and maps buffer cursor positions <-> cell
--                                 (row, column) coordinates.
--   * orbit/editable_result.lua - an in-memory "spreadsheet" model that
--                                 tracks inserted/modified/deleted rows and
--                                 undo history, used only when results are
--                                 opened in *editable* mode.
--   * orbit/adapters.lua        - given a connection profile, produces a
--                                 database-specific connector (e.g. it can
--                                 turn pending edits into an UPDATE/INSERT/
--                                 DELETE statement).
--   * orbit/runner.lua          - actually executes a SQL statement against
--                                 a profile/connection.
--
-- This module's job is the glue between those pieces and Neovim's UI: it
-- creates/reuses the results buffer and window, renders the grid into
-- buffer lines, wires up normal-mode keymaps for navigating/editing cells,
-- and (in editable mode) hooks up autocmds so that Neovim's normal `:w`
-- (write) / `:e!` (reload) commands save pending edits back to the database
-- or discard them and re-fetch fresh rows.
--
-- Each Neovim tabpage gets at most one results window (tracked in the
-- module-local `tab_results` table below), which is reused across queries
-- instead of piling up more and more split windows.
--
-- Public API (what this module exports on `M`):
--   M.render(rows, options) -> grid
--     Thin pass-through to grid_model.render; lets callers build a grid
--     without opening any UI (e.g. for tests or previews).
--   M.open(rows, options) -> { buffer, window, grid }
--     The main entry point: opens (or reuses) the results split for the
--     current tabpage, renders `rows` into it, and wires up all keymaps.
--     See its own comment below for the full list of supported `options`.

local grid_model = require("orbit.grid")
local editable_result = require("orbit.editable_result")
local adapters = require("orbit.adapters")
local runner = require("orbit.runner")

local M = {}
-- Maps tabpage handle -> { buffer = <bufnr>, window = <winid> } so each
-- tabpage reuses a single results split instead of creating a new one per
-- query. See M.open below for how this is populated/invalidated.
local tab_results = {}
-- Incrementing counter used to give each *editable* results buffer a unique
-- name (see M.open: "orbit://results/<n>"). Editable buffers need a real,
-- unique name because Neovim requires buffers with buftype "acwrite" to have
-- a name before they can be written (`:w`).
local result_sequence = 0

-- Renders `rows` (a list of row tables, e.g. { {id=1, name="a"}, ... }) into
-- a "grid" data structure (columns, formatted+truncated cell text, raw
-- values, and whether the result was truncated by a row limit). This is a
-- pure function with no buffer/window side effects -- it just delegates to
-- grid_model.render. `options` is forwarded as-is; see orbit/grid.lua for
-- the supported keys (e.g. `limit`, `max_cell_width`, `columns`).
function M.render(rows, options)
  return grid_model.render(rows, options)
end

-- Figures out which grid cell (row/column, in grid-data terms, not buffer
-- line/column terms) the cursor is currently sitting on inside a results
-- window.
--   window: the window id whose cursor position we should read.
--   grid:   the grid data returned by grid_model.render (has .raw_rows etc).
--   widths: the per-column character widths returned by grid_model.layout;
--           needed because the grid's header/rows occupy a fixed offset of
--           buffer lines and the column boundaries depend on each column's
--           rendered width.
-- Returns a `{ row = <n>, column = <n> }` table (1-based, in grid terms) or
-- nil if the cursor is not over a data cell (e.g. it's on the title line).
-- `vim.api.nvim_win_get_cursor` returns { line, column } where line is
-- 1-based and column is 0-based byte offset within that line -- that's the
-- raw buffer position grid_model.cell_at then has to translate into a cell.
local function selected_cell(window, grid, widths)
  local cursor = vim.api.nvim_win_get_cursor(window)
  return grid_model.cell_at(grid, widths, cursor[1], cursor[2])
end

-- Moves the cursor from whatever cell it's currently on by `row_delta` rows
-- and `column_delta` columns (e.g. move_cell(win, grid, widths, 0, -1) moves
-- one column left). Used by the h/j/k/l keymaps below instead of letting
-- Neovim's normal cursor movement run free, so that the cursor always lands
-- exactly at the start of a cell's text rather than anywhere inside padding
-- or separator characters.
-- Side effect: moves the real cursor in `window` via nvim_win_set_cursor.
-- Does nothing if the cursor isn't currently over a valid cell.
local function move_cell(window, grid, widths, row_delta, column_delta)
  local cell = selected_cell(window, grid, widths)
  if not cell then
    return
  end
  local target = grid_model.move(grid, widths, cell, row_delta, column_delta)
  vim.api.nvim_win_set_cursor(window, grid_model.cursor_for(widths, target))
end

-- Opens a small floating window ("popup") showing the full, untruncated
-- value of a single cell -- used for values that got cut off in the grid
-- (long strings, JSON blobs, etc). This is what runs when you press <CR> on
-- a read-only result, or `y`/inspect on any cell.
--   value: the raw Lua value to display (can be nil, vim.NIL for SQL NULL,
--          a string, number, or a table for JSON-like values).
-- Returns nothing; if `value` is nil this is a silent no-op (nothing to
-- show).
-- Side effects: creates a new scratch buffer and a floating window
-- (nvim_open_win with relative = "editor", i.e. positioned relative to the
-- whole Neovim UI rather than another window), and adds two buffer-local
-- keymaps (`q` to close, `y` to yank/copy) scoped to that popup buffer only.
local function inspect(value)
  if value == nil then
    return
  end
  -- grid_model.serialize gives us the "raw" text form (e.g. "NULL" for SQL
  -- NULL, JSON-encoded text for tables) rather than the truncated display
  -- text used in the grid.
  local contents = grid_model.serialize(value)
  -- nvim_create_buf(listed=false, scratch=true): an unlisted, throwaway
  -- buffer that won't show up in :ls and isn't tied to any file on disk.
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(contents, "\n", { plain = true }))
  -- If the value happens to parse as JSON, turn on JSON syntax highlighting
  -- as a nice-to-have; pcall just means "try this and don't error out if it
  -- fails" since most values won't be JSON.
  if pcall(vim.json.decode, contents) then
    vim.bo[buffer].filetype = "json"
  end
  vim.bo[buffer].modifiable = false

  -- Size the popup to fit its content, but clamp it so it never gets
  -- ridiculously wide/tall or exceeds the actual editor's screen size.
  local width = math.min(math.max(40, vim.o.columns - 8), 100)
  local height = math.min(math.max(3, #vim.api.nvim_buf_get_lines(buffer, 0, -1, false)), math.max(3, vim.o.lines - 6))
  local window = vim.api.nvim_open_win(buffer, true, {
    border = "rounded",
    -- Centering math: place the top-left corner so the popup's box sits in
    -- the middle of the screen.
    col = math.floor((vim.o.columns - width) / 2),
    height = height,
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    title = " Orbit Value ",
    title_pos = "center",
    width = width,
  })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(window, true)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit value" })
  vim.keymap.set("n", "y", function()
    -- setreg('"', ...) writes to the unnamed register, i.e. what a plain
    -- `p` paste would insert afterwards.
    vim.fn.setreg('"', contents)
    vim.notify("Orbit value copied")
  end, { buffer = buffer, silent = true, nowait = true, desc = "Copy Orbit value" })
end

-- The main entry point of this module: opens (or reuses) the results split
-- window for the current tabpage, fills it with `rows`, and wires up every
-- keymap/autocmd needed to browse (and, in editable mode, edit) the result.
--
-- Parameters:
--   rows: a list of row tables, e.g. { { id = 1, name = "a" }, ... }. Each
--         row table maps column name -> value. This is the actual query
--         result data to display.
--   options: a table of optional settings, notably:
--     tabpage         - which tabpage's results split to use/create
--                        (defaults to the current tabpage).
--     source_window    - the window that triggered opening results (used to
--                        restore focus there afterwards).
--     editable         - if truthy, opens the results in *editable* mode:
--                        backed by an editable_result "model" that tracks
--                        row inserts/edits/deletes and supports :w to save,
--                        :e! to reload, undo, etc. If falsy, the results are
--                        read-only (just for browsing/copying/inspecting).
--     columns          - explicit list of column names/order to render.
--     profile / profile_name / source_name / elapsed / read_only_reason -
--                        used only for the descriptive header/footer text.
--     confirm_mutations - if not explicitly false, prompts the user with a
--                        confirm() dialog before writing edits to the DB.
--     reload(callback)  - a function this module calls to re-fetch fresh
--                        rows (used by `:e!` reload and after a successful
--                        save).
--     on_quit(window, source_window) - if provided, called instead of just
--                        closing the window when the user presses `q`.
--     height, focus     - window height, and whether to keep keyboard focus
--                        in the results window after opening.
--
-- Returns: { buffer = <bufnr>, window = <winid>, grid = <grid> } describing
-- what was created/reused.
--
-- Side effects (this function does a LOT of UI wiring, since it's the heart
-- of the results view):
--   * May create a new scratch buffer + a new window (`:botright new` split)
--     the first time a tabpage shows results, or reuse the existing ones on
--     subsequent calls (see `tab_results` above).
--   * Sets buffer options (buftype, filetype, bufhidden, modifiable).
--   * Writes the rendered grid text into the buffer.
--   * Adds syntax highlights (extmark-based, via nvim_buf_add_highlight)
--     for the header rows and selected/inserted rows.
--   * Registers a whole set of buffer-local normal-mode keymaps (q, <CR>,
--     y, h/j/k/l, and in editable mode also i, o, O, dd, d, V, <Esc>, u, gg,
--     G) and, in editable mode, autocmds for InsertLeave/BufWriteCmd/
--     BufReadCmd.
function M.open(rows, options)
  options = options or {}
  -- Remember where the user currently is so we can jump back there once
  -- the results window has been populated (unless options.focus asks us to
  -- stay in the results window instead).
  local original_window = vim.api.nvim_get_current_win()
  local original_tabpage = vim.api.nvim_get_current_tabpage()
  local tabpage = options.tabpage or original_tabpage
  if vim.api.nvim_tabpage_is_valid(tabpage) then
    vim.api.nvim_set_current_tabpage(tabpage)
  else
    -- The requested tabpage no longer exists (e.g. it was closed); fall
    -- back to whatever tabpage we're actually on now.
    tabpage = vim.api.nvim_get_current_tabpage()
  end
  local source_window = options.source_window
  if not source_window or not vim.api.nvim_win_is_valid(source_window) then
    source_window = vim.api.nvim_get_current_win()
  end
  -- Look up whether this tabpage already has a results window/buffer from
  -- a previous query, so we can reuse it (see comment below).
  local state = tab_results[tabpage]
  local buffer
  local window
  local placeholder
  if state and vim.api.nvim_win_is_valid(state.window) and vim.api.nvim_buf_is_valid(state.buffer) then
    -- Each tabpage keeps one reusable result grid rather than accumulating result splits.
    buffer = state.buffer
    window = state.window
  else
    -- No usable existing results window for this tabpage: create a fresh
    -- scratch buffer, then open a new horizontal split at the bottom of the
    -- tabpage ("botright new") to host it. `placeholder` is the throwaway
    -- buffer that `:new` puts in the split by default -- we'll swap our own
    -- `buffer` into the window and delete this one later.
    buffer = vim.api.nvim_create_buf(false, true)
    vim.cmd("botright new")
    window = vim.api.nvim_get_current_win()
    placeholder = vim.api.nvim_win_get_buf(window)
    tab_results[tabpage] = { buffer = buffer, window = window }
  end
  -- If this buffer is being reused from a previous call, wipe out any
  -- editable-mode keymaps/autocmds that a *previous* render might have set
  -- up (e.g. if the previous result was editable but this one is read-only,
  -- or the model instance changed) so stale closures don't linger.
  -- pcall guards against these simply not existing yet (first time through).
  for _, lhs in ipairs({ "i", "o", "O", "dd", "d", "V", "<Esc>", "u", "gg", "G" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buffer })
  end
  pcall(vim.api.nvim_clear_autocmds, { group = "OrbitResults" .. buffer, buffer = buffer })
  -- In editable mode, wrap the raw rows in an editable_result "model" that
  -- tracks per-row state (unchanged/inserted/modified/deleted) and undo
  -- history. In read-only mode there's no model at all -- `model` stays nil
  -- and is used throughout this function as the read-only/editable switch.
  local model = options.editable and editable_result.new(rows) or nil
  -- These are populated by render() below and read by the keymap callbacks
  -- defined further down; they're declared here (as upvalues) so every
  -- closure in this function shares and sees the latest values.
  local grid    -- the current grid_model.render() result
  local widths  -- per-column character widths from grid_model.layout()
  local source  -- the "profile / source | N rows" header text
  local selection_anchor -- grid row index where a `V` (visual row select) started
  local visual = false   -- whether row-selection mode is currently active
  local saving = false   -- true while a save (:w) is in flight, to prevent double-saves
  local inline_edit      -- details of an in-progress inline cell edit (see edit_cell)
  -- Convenience wrapper: look up the grid cell under the cursor right now.
  local function current_cell()
    return selected_cell(window, grid, widths)
  end
  -- Computes the list of row ids that are currently "selected" for a
  -- destructive/bulk operation (currently just delete, `dd`). If visual
  -- row-selection mode isn't active, this is just the single row the
  -- cursor is on; otherwise it's every row between the selection anchor
  -- and the current cursor row (inclusive), regardless of which one is
  -- above the other.
  local function selected_ids()
    local cell = current_cell()
    if not cell then
      return {}
    end
    local visible = editable_result.visible_rows(model)
    if not visual or not selection_anchor then
      return { visible[cell.row].id }
    end
    local first = math.min(selection_anchor, cell.row)
    local last = math.max(selection_anchor, cell.row)
    local ids = {}
    for index = first, last do
      ids[#ids + 1] = visible[index].id
    end
    return ids
  end
  -- The central "repaint" function: rebuilds the grid from the current
  -- data (model or plain rows) and rewrites the whole buffer with it. This
  -- is called once up front, and again after every edit/insert/delete/
  -- undo/reload so the buffer always reflects the latest state.
  --   cursor: optional `{ row, column }` (grid coordinates) to move the
  --           cursor to after repainting, e.g. to keep the cursor on the
  --           same logical row after a row above it was deleted.
  -- Side effects: rewrites the entire buffer's lines, toggles `modifiable`
  -- off/on around the write (the buffer is normally read-only so users
  -- can't free-type into it -- see edit_cell for the one place that's
  -- temporarily lifted), sets the buffer's `modified` flag, clears and
  -- re-applies highlights, and optionally moves the window cursor.
  local function render(cursor)
    -- In editable mode we render from the model's *visible* rows (i.e.
    -- excluding rows marked "deleted", which are kept around only so undo
    -- can bring them back); in read-only mode we just use the original
    -- `rows` list as given.
    local visible = model and editable_result.visible_rows(model) or rows
    grid = M.render(vim.tbl_map(function(row)
      -- editable_result rows are wrapped as { id, values, state, ... };
      -- unwrap down to the plain column->value table grid_model.render
      -- expects. Plain (read-only) rows are already in that shape.
      return model and row.values or row
    end, visible), vim.tbl_extend("force", options, { columns = options.columns }))
    local row_count = #grid.rows
    -- "+" suffix signals the grid hit orbit/grid.lua's row `limit` and is
    -- not showing every row that matched the query.
    local truncation = grid.limited and "+" or ""
    local elapsed = options.elapsed and string.format(" | %ds", options.elapsed) or ""
    local modified = model and editable_result.changed(model)
    source = string.format("%s / %s%s | %d%s rows%s", options.profile_name or "unknown profile", options.source_name or "[No Name]", modified and " [+]" or "", row_count, truncation, elapsed)
    -- The footer line shown at the bottom of the grid differs depending on
    -- whether editing is available at all, and if not, why not.
    local footer = model
        and "[Add Row] [Delete] [Save] [Rollback]  o/O add  dd delete  V select  :w save  :e! reload"
      or options.read_only_reason
      or "Read-only: open a Workspace table sample to edit.  q close  y copy  <CR> inspect"
    local lines
    -- grid_model.layout turns the grid + header/footer text into the final
    -- list of buffer lines, and also returns `widths` (per-column
    -- rendered width) which every cursor<->cell calculation in this file
    -- depends on.
    lines, widths = grid_model.layout(grid, source, footer)
    -- The buffer is kept non-modifiable outside of these two lines so that
    -- normal typing can't corrupt the grid; we only ever write to it
    -- programmatically.
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    -- Drive Neovim's own "unsaved changes" indicator (used by :w prompts,
    -- statusline plugins, etc.) off whether the model has pending edits.
    vim.bo[buffer].modified = modified or false
    -- Wipe every highlight in this buffer (namespace -1 means "the
    -- anonymous, buffer-wide default namespace") and reapply from scratch,
    -- since row positions/content just changed entirely.
    vim.api.nvim_buf_clear_namespace(buffer, -1, 0, -1)
    -- Line 0 is the "Orbit Results: ..." title, line 2 is the column
    -- header row (line 1 is the blank spacer between them) -- see
    -- grid_model.layout's fixed layout. Highlight both as "header" style.
    vim.api.nvim_buf_add_highlight(buffer, -1, "OrbitHeader", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buffer, -1, "OrbitHeader", 2, 0, -1)
    -- The last line is always the footer/hint text.
    vim.api.nvim_buf_add_highlight(buffer, -1, "OrbitHint", #lines - 1, 0, -1)
    if model then
      -- Build a quick lookup set of which row ids are currently selected
      -- (for the `V` visual-row-select highlight) ...
      local selected = {}
      for _, id in ipairs(selected_ids()) do
        selected[id] = true
      end
      -- ... then highlight each visible row: newly inserted rows always
      -- get a "DiffAdd" (green-ish, added-line) highlight, and otherwise a
      -- row that's part of the current selection gets "Visual" highlight.
      -- `index + 4` converts a 1-based grid row index into a 0-based
      -- buffer line index, accounting for the 4 lines of title/blank/
      -- header/separator that always precede the data rows (matches the
      -- offset used in grid_model.cell_at).
      for index, row in ipairs(editable_result.visible_rows(model)) do
        local group = row.state == "inserted" and "DiffAdd" or selected[row.id] and "Visual" or nil
        if group then
          vim.api.nvim_buf_add_highlight(buffer, -1, group, index + 4, 0, -1)
        end
      end
    end
    -- Only move the cursor if the caller asked us to AND there's at least
    -- one row to land on (otherwise grid_model.cursor_for would compute a
    -- position that doesn't exist, e.g. after deleting every row).
    if cursor and #grid.rows > 0 then
      vim.api.nvim_win_set_cursor(window, grid_model.cursor_for(widths, cursor))
    end
  end
  -- Initial paint with no explicit cursor target (buffer isn't attached to
  -- the window yet at this point, so moving the cursor wouldn't matter
  -- anyway -- the real "first paint into the window" happens further down
  -- after nvim_win_set_buf).
  render()
  if model then
    -- Editable results need buftype "acwrite": this tells Neovim "there's
    -- no file on disk, but :w should still be allowed -- fire a
    -- BufWriteCmd autocmd instead of trying to write a real file." A
    -- unique name is required for that to work, hence result_sequence.
    result_sequence = result_sequence + 1
    vim.bo[buffer].buftype = "acwrite"
    vim.api.nvim_buf_set_name(buffer, "orbit://results/" .. result_sequence)
  else
    -- Read-only results just need an ordinary throwaway buffer that isn't
    -- backed by any file and can never be written.
    vim.bo[buffer].buftype = "nofile"
  end
  -- "wipe" means: once this buffer is no longer displayed in any window,
  -- delete it outright rather than leaving it as a hidden buffer.
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "orbit-results"
  vim.api.nvim_win_set_buf(window, buffer)
  -- Now that the buffer is actually showing in `window`, repaint and put
  -- the cursor on the first cell (row 1, column 1).
  render({ row = 1, column = 1 })
  -- Only delete the split's listed placeholder, never an arbitrary user buffer.
  if placeholder and vim.api.nvim_buf_is_valid(placeholder) and vim.bo[placeholder].buflisted then
    vim.api.nvim_buf_delete(placeholder, { force = true })
  end
  vim.api.nvim_win_set_height(window, options.height or 15)
  -- Results windows don't want a winbar (breadcrumb-style bar some
  -- configs add above every window); force it blank here.
  vim.wo[window].winbar = ""
  vim.keymap.set("n", "q", function()
    if model and editable_result.changed(model) then
      -- There are unsaved edits: use `:quit` instead of force-closing so
      -- Neovim's normal "no write since last change" safeguard kicks in
      -- and the user gets a chance to save or explicitly discard.
      vim.cmd("quit")
      return
    end
    if options.on_quit then
      -- Caller wants custom close behavior (e.g. restoring some other UI
      -- state) instead of the default close-and-forget.
      options.on_quit(window, source_window)
      return
    end
    vim.api.nvim_win_close(window, true)
    -- Only clear this tabpage's cached state if the window we just closed
    -- is still the one it's pointing at (it could already have been
    -- replaced by a newer M.open call in a race, though unlikely).
    if tab_results[tabpage] and tab_results[tabpage].window == window then
      tab_results[tabpage] = nil
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit results" })
  -- Starts editing the cell currently under the cursor. In read-only mode
  -- this just opens the inspect() popup instead (there's nothing to edit).
  -- In editable mode, this "reveals" the single target cell as real,
  -- editable text (temporarily making the whole buffer modifiable) and
  -- drops the user into Insert mode positioned right after the existing
  -- value, so they can adjust/retype it. When they leave Insert mode, the
  -- InsertLeave autocmd (registered further down) reads back whatever text
  -- ended up between two tracked extmarks and commits it into the model.
  -- Side effects: makes the buffer briefly modifiable, replaces the cell's
  -- rendered (possibly truncated) display text with its raw serialized
  -- value, creates two extmarks (see below) to track the edit region even
  -- as text is typed/deleted around it, moves the cursor, and starts
  -- Insert mode.
  local function edit_cell()
    local cell = selected_cell(window, grid, widths)
    if not model then
      inspect(cell and grid.raw_rows[cell.row][cell.column])
      return
    end
    if not cell then
      return
    end
    local row = editable_result.visible_rows(model)[cell.row]
    local column = grid.columns[cell.column]
    -- Convert the cell's (row, column) grid coordinates into an actual
    -- 1-based buffer line + 0-based start byte column, then compute the
    -- byte column where the cell's text ends using its known width.
    local line, start = unpack(grid_model.cursor_for(widths, cell))
    local finish = start + widths[cell.column]

    -- The formatted grid remains model-owned; expose only this cell while inserting.
    -- Swap the display text (which may have been truncated with "...")
    -- for the raw, full-fidelity serialized value so the user edits the
    -- real underlying data, not a lossy rendering of it.
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_text(buffer, line - 1, start, line - 1, finish, { grid_model.serialize(row.values[column]) })
    -- Extmarks are Neovim's way of "pinning" a position in a buffer that
    -- automatically shifts as the user types/deletes text around it (a
    -- plain line/column number would go stale the moment the user typed a
    -- single character). We create one at the start of the cell's text
    -- (right_gravity = false: stays put if text is inserted exactly at
    -- that position) and one at its current end (right_gravity = true:
    -- moves right as more text is typed there), so after editing we can
    -- ask Neovim "where do these two marks currently sit?" and read
    -- exactly the text the user left between them.
    local namespace = vim.api.nvim_create_namespace("OrbitInlineResultEdit")
    inline_edit = {
      cell = cell,
      column = column,
      finish = vim.api.nvim_buf_set_extmark(buffer, namespace, line - 1, start + #grid_model.serialize(row.values[column]), {
        right_gravity = true,
      }),
      namespace = namespace,
      row_id = row.id,
      start = vim.api.nvim_buf_set_extmark(buffer, namespace, line - 1, start, { right_gravity = false }),
    }
    vim.api.nvim_win_set_cursor(window, { line, start })
    vim.cmd("startinsert")
  end
  -- <CR> (Enter) either opens the inline cell editor (editable mode) or
  -- the read-only inspect() popup, via edit_cell defined above.
  vim.keymap.set("n", "<CR>", edit_cell, { buffer = buffer, silent = true, nowait = true, desc = "Edit Orbit cell" })
  -- `y` copies the raw (untruncated) value of the cell under the cursor
  -- into the unnamed register, so it can be pasted elsewhere.
  vim.keymap.set("n", "y", function()
    local cell = selected_cell(window, grid, widths)
    local value = cell and grid.raw_rows[cell.row][cell.column]
    if value ~= nil then
      vim.fn.setreg('"', grid_model.serialize(value))
      vim.notify("Orbit value copied")
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Copy Orbit value" })
  -- h/j/k/l are remapped from plain cursor movement to cell-to-cell
  -- movement (see move_cell above), so the cursor always lands exactly on
  -- a cell's first character rather than drifting into padding spaces or
  -- the "|" column separators.
  vim.keymap.set("n", "h", function()
    move_cell(window, grid, widths, 0, -1)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Orbit cell left" })
  vim.keymap.set("n", "j", function()
    move_cell(window, grid, widths, 1, 0)
    -- While a row-visual-selection is active, moving the cursor changes
    -- which rows are selected, so we must repaint to update the
    -- highlighted range.
    if model and visual then
      render(current_cell())
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Orbit cell down" })
  vim.keymap.set("n", "k", function()
    move_cell(window, grid, widths, -1, 0)
    if model and visual then
      render(current_cell())
    end
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Orbit cell up" })
  vim.keymap.set("n", "l", function()
    move_cell(window, grid, widths, 0, 1)
  end, { buffer = buffer, silent = true, nowait = true, desc = "Move Orbit cell right" })
  -- Everything below this point is only relevant when the results are
  -- editable (there's a `model` to mutate) -- read-only results have no
  -- add/delete/save/undo/reload affordances.
  if model then
    -- `i` is a synonym for <CR>/edit_cell, matching Vim's "insert" mnemonic.
    vim.keymap.set("n", "i", function()
      edit_cell()
    end, { buffer = buffer, silent = true, nowait = true, desc = "Edit Orbit cell" })
    -- `o` inserts a new blank row *after* the current row (like Vim's `o`
    -- opens a line below). editable_result.insert returns the new row
    -- (with a fresh id); we then have to re-find that row's new *visible*
    -- index (its position may not simply be current+1, e.g. if some rows
    -- above it are marked deleted) so the cursor can be placed on it.
    vim.keymap.set("n", "o", function()
      local cell = current_cell()
      local row = editable_result.insert(model, cell and cell.row)
      local visible = editable_result.visible_rows(model)
      for index, candidate in ipairs(visible) do
        if candidate.id == row.id then
          render({ row = index, column = cell and cell.column or 1 })
          return
        end
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Insert Orbit row below" })
    -- `O` is the same idea but inserts *before* the current row (Vim's
    -- `O` opens a line above).
    vim.keymap.set("n", "O", function()
      local cell = current_cell()
      local row = editable_result.insert_before(model, cell and cell.row)
      local visible = editable_result.visible_rows(model)
      for index, candidate in ipairs(visible) do
        if candidate.id == row.id then
          render({ row = index, column = cell and cell.column or 1 })
          return
        end
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Insert Orbit row above" })
    -- `dd` deletes either just the current row, or every row in the
    -- current visual selection (see selected_ids above), then clears the
    -- selection state and repaints. After deleting, the cursor tries to
    -- stay near where it was: math.min(cell.row, #remaining) clamps the
    -- target row so we don't try to land past the end of the now-shorter
    -- list (e.g. deleting the last row). If there are no rows left at
    -- all, `render(nil)` is called instead, since there's nothing to put
    -- the cursor on.
    vim.keymap.set("n", "dd", function()
      local cell = current_cell()
      local ids = selected_ids()
      editable_result.delete(model, ids)
      visual = false
      selection_anchor = nil
      local remaining = editable_result.visible_rows(model)
      render(#remaining > 0 and { row = math.min(cell.row, #remaining), column = cell.column } or nil)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Delete Orbit row" })
    -- `d` on its own only makes sense here as the first half of `dd` while
    -- a visual row-selection is active; nvim_feedkeys re-injects a
    -- synthetic "dd" so the `dd` mapping above actually runs (the "m"
    -- flags mean "treat these keys as if mapped", i.e. remapping applies).
    vim.keymap.set("n", "d", function()
      if visual then
        vim.api.nvim_feedkeys("dd", "m", false)
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Delete selected Orbit rows" })
    -- `V` starts (or restarts) a row-range selection anchored at the
    -- current row; moving up/down afterwards grows/shrinks the selected
    -- range (handled by the visual-mode checks in the h/j/k/l mappings).
    vim.keymap.set("n", "V", function()
      local cell = current_cell()
      if cell then
        visual = true
        selection_anchor = cell.row
        render(cell)
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Select Orbit rows" })
    -- <Esc> cancels any active row selection.
    vim.keymap.set("n", "<Esc>", function()
      visual = false
      selection_anchor = nil
      local cell = current_cell()
      render(cell)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Clear Orbit row selection" })
    -- `u` undoes the last model-level change (insert/delete/edit) by
    -- popping a snapshot off editable_result's history stack. Note this is
    -- independent of Neovim's own built-in undo, since the buffer text
    -- itself isn't directly edited except through render().
    vim.keymap.set("n", "u", function()
      local cell = current_cell()
      if editable_result.undo(model) then
        render(cell)
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Undo Orbit edit" })
    -- `gg`/`G` jump to the first/last data row while keeping the current
    -- column, mirroring Vim's usual "go to top/bottom of file" but scoped
    -- to the grid's data rows rather than the whole buffer (which also
    -- has title/header/footer lines you don't want to land on).
    vim.keymap.set("n", "gg", function()
      local cell = current_cell()
      if cell then
        vim.api.nvim_win_set_cursor(window, grid_model.cursor_for(widths, { row = 1, column = cell.column }))
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Go to first Orbit row" })
    vim.keymap.set("n", "G", function()
      local cell = current_cell()
      if cell and #grid.rows > 0 then
        vim.api.nvim_win_set_cursor(window, grid_model.cursor_for(widths, { row = #grid.rows, column = cell.column }))
      end
    end, { buffer = buffer, silent = true, nowait = true, desc = "Go to last Orbit row" })
    -- Re-fetches fresh rows from the database (via options.reload, which
    -- the caller supplies -- this module has no idea how to run a query
    -- itself) and rebuilds the model from scratch, discarding all pending
    -- local edits. Used both by `:e!` (BufReadCmd below) and after a
    -- successful save (to pick up server-side defaults/triggers).
    --   callback(err): called when the reload finishes (or immediately, if
    --                  there's no options.reload configured at all).
    -- On a reload error, this still rebuilds the model (from whatever rows
    -- were visible before) rather than leaving stale UI, and surfaces the
    -- error via vim.notify.
    local function reload(callback)
      callback = type(callback) == "function" and callback or function() end
      if not options.reload then
        callback()
        return
      end
      options.reload(function(reloaded, reload_err)
        if reload_err then
          vim.notify(reload_err, vim.log.levels.ERROR)
          -- Reload failed: don't lose the user's pending local edits.
          -- Rebuild a *fresh* model from the current visible rows' values
          -- (stripping out per-row state/history), which effectively just
          -- resets undo history/row ids while keeping the data as-is.
          model = editable_result.new(vim.tbl_map(function(row)
            return row.values
          end, editable_result.visible_rows(model)))
          render({ row = 1, column = 1 })
          callback(reload_err)
          return
        end
        -- Reload succeeded: throw away the old model entirely (and with it
        -- any pending edits/history) and start a brand new one from the
        -- freshly fetched rows.
        model = editable_result.new(reloaded)
        visual = false
        selection_anchor = nil
        render({ row = 1, column = 1 })
        callback()
      end)
    end
    -- Persists pending model changes (inserts/updates/deletes) to the
    -- database. Triggered by `:w` via the BufWriteCmd autocmd below.
    -- Side effects: may show a vim.fn.confirm() blocking dialog, runs a
    -- SQL statement through orbit/runner.lua, blocks (via vim.wait) for up
    -- to 30 seconds waiting for that statement to finish, and on success
    -- triggers a reload() to refresh the grid with the DB's own view of
    -- the data (e.g. server-generated ids/defaults/triggers).
    local function save()
      if saving or not editable_result.changed(model) then
        -- Either a save is already in progress, or there's nothing to
        -- save -- either way, do nothing.
        return
      end
			-- Ask orbit/adapters.lua for a database-specific "connector" for
			-- this profile, then ask that connector to turn the model's pending
			-- changes into a single SQL statement it knows how to build
			-- (INSERT/UPDATE/DELETE, dialect-specific). Not every connector
			-- supports mutations, hence the connector.mutation_statement check.
			local connector, connector_err = adapters.connector(options.profile)
			local statement, statement_err
			if connector and connector.mutation_statement then
				statement, statement_err = connector.mutation_statement(options.profile.options, options.editable, editable_result.changes(model))
			else
				statement_err = connector_err or "Result is read-only: editing is not supported by this connection profile."
			end
      if not statement then
        vim.notify(statement_err, vim.log.levels.ERROR)
        return
      end
      -- Give the user a last chance to back out before writing to the
      -- real database, unless they've explicitly disabled the prompt
      -- either per-call (options.confirm_mutations) or per-profile
      -- (options.profile.options.confirm_mutations).
      if options.confirm_mutations ~= false and options.profile.options.confirm_mutations ~= false then
        if vim.fn.confirm("Write pending Orbit database changes?", "&Write\n&Cancel", 2) ~= 1 then
          return
        end
      end
      saving = true
      local completed = false
		-- runner.run executes the statement asynchronously and calls back
		-- with (result, error). On success we kick off a reload to replace
		-- local pending state with the database's authoritative rows.
		runner.run(options.profile, statement, function(_, save_err)
        saving = false
        if save_err then
          vim.notify(save_err, vim.log.levels.ERROR)
          completed = true
          return
        end
        reload(function()
          completed = true
		end, connector)
      end)
      -- Neovim's :w needs to appear synchronous to the user (and to
      -- whatever invoked it, e.g. a script doing `:wq`), but the actual
      -- database write above is asynchronous. vim.wait blocks the UI here
      -- (processing events, so the async callback above can still fire)
      -- for up to 30 seconds waiting for `completed` to flip true; if it
      -- times out first, we just warn and let the write keep running in
      -- the background rather than hanging forever.
      if not vim.wait(30000, function()
        return completed
      end, 10) then
        vim.notify("Orbit write is still running; local changes remain pending", vim.log.levels.WARN)
      end
    end
    -- A dedicated autocmd group per buffer (named by buffer number) so
    -- clearing/re-registering these autocmds for one results buffer never
    -- touches another. `clear = true` wipes any previous autocmds in this
    -- exact group before adding the new ones below (relevant when a
    -- buffer is being reused for a new M.open call).
    local group = vim.api.nvim_create_augroup("OrbitResults" .. buffer, { clear = true })
    -- Fires whenever Insert mode ends anywhere in this buffer. This is
    -- where an in-progress inline cell edit (started by edit_cell) is
    -- actually committed back into the model.
    vim.api.nvim_create_autocmd("InsertLeave", {
      buffer = buffer,
      group = group,
      callback = function()
        if not inline_edit then
          -- Insert mode ended for some unrelated reason (nothing being
          -- inline-edited right now) -- nothing to commit.
          return
        end
        local edit = inline_edit
        inline_edit = nil
        -- Ask Neovim where the two tracking extmarks ended up after
        -- whatever typing/deleting the user did.
        local start = vim.api.nvim_buf_get_extmark_by_id(buffer, edit.namespace, edit.start, {})
        local finish = vim.api.nvim_buf_get_extmark_by_id(buffer, edit.namespace, edit.finish, {})
        vim.api.nvim_buf_clear_namespace(buffer, edit.namespace, 0, -1)
        -- If either extmark vanished, or they ended up on different lines
        -- (e.g. the user pressed Enter and split the cell's text across
        -- lines), we can't reliably extract "the new value" -- bail out
        -- and just repaint from the model's last-known-good state,
        -- discarding whatever partial edit was in the buffer.
        if #start == 0 or #finish == 0 or start[1] ~= finish[1] then
          render(edit.cell)
          return
        end
        local value = vim.api.nvim_buf_get_text(buffer, start[1], start[2], finish[1], finish[2], {})[1]
        -- Typing the literal text "NULL" is how a user sets a SQL NULL
        -- value, mirroring how grid_model.serialize displays NULL values
        -- for inspection/copy.
        if value == "NULL" then
          value = vim.NIL
        end
        editable_result.set_value(model, edit.row_id, edit.column, value)
        render(edit.cell)
      end,
    })
    -- BufWriteCmd fires instead of an actual file write whenever the user
    -- runs `:w` on this buffer (this is what buftype = "acwrite" enables).
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buffer,
      group = group,
      callback = save,
    })
    -- BufReadCmd fires instead of an actual file read whenever the user
    -- runs `:e!`/`:e` (reload/re-read) on this buffer, letting us re-fetch
    -- from the database instead of Neovim trying to read a real file.
    vim.api.nvim_create_autocmd("BufReadCmd", {
      buffer = buffer,
      group = group,
      callback = reload,
    })
  end

  -- Decide where keyboard focus should end up after opening the results
  -- window: stay in it if explicitly requested; otherwise try to restore
  -- focus to wherever the user was before calling M.open (their tabpage +
  -- window), falling back to whatever `source_window` was passed in if the
  -- original window/tabpage no longer exists.
  if options.focus then
    vim.api.nvim_set_current_win(window)
  elseif vim.api.nvim_win_is_valid(original_window) and vim.api.nvim_tabpage_is_valid(original_tabpage) then
    -- Prefer the caller's context, falling back to the source window after tab changes.
    vim.api.nvim_set_current_tabpage(original_tabpage)
    vim.api.nvim_set_current_win(original_window)
  elseif vim.api.nvim_win_is_valid(source_window) then
    vim.api.nvim_set_current_win(source_window)
  end
  return { buffer = buffer, window = window, grid = grid }
end

return M
