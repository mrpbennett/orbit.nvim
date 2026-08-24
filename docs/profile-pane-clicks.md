# Clickable Workspace Sidebar Research

## Finding

Snacks Explorer does not attach callbacks to individual rendered items. It maps
`<2-LeftMouse>` in its result-list buffer, resolves the item at the cursor, and
runs the Explorer confirm action. Orbit's Workspace sidebar has the same
essential shape: `render()` records an actionable node in `state.nodes` at the
node's rendered buffer line, and its existing sidebar mappings resolve actions
from the cursor line.

Sources:

- Snacks picker default `<2-LeftMouse>` mapping: `/home/pb/.local/share/nvim/lazy/snacks.nvim/lua/snacks/picker/config/defaults.lua:282-329`
- Snacks Explorer `confirm` action override: `/home/pb/.local/share/nvim/lazy/snacks.nvim/lua/snacks/picker/source/explorer.lua:154-180`
- Snacks cursor-to-current-item resolution: `/home/pb/.local/share/nvim/lazy/snacks.nvim/lua/snacks/picker/core/picker.lua:580-589` and `/home/pb/.local/share/nvim/lazy/snacks.nvim/lua/snacks/picker/core/list.lua:343-355`
- Orbit node rendering: `lua/orbit/workspace.lua:93-188`
- Orbit cursor-line sidebar actions: `lua/orbit/workspace.lua:384-455`

## Recommended Design

Use double left click to activate the cursor-line action. A normal left click
keeps Neovim's ordinary cursor placement and window focus behavior; the second
click then binds and expands a profile, or opens a saved query. This matches
the Snacks interaction without custom hit testing.

First extract the existing `h`, `l`, and `<CR>` callback bodies into local
`collapse_current()`, `expand_current()`, and `activate_current()` functions.
Both keyboard mappings and mouse mappings should call those functions.

Suggested mouse binding in `configure_sidebar(state)`:

```lua
vim.keymap.set("n", "<2-LeftMouse>", function()
  local pos = vim.fn.getmousepos()
  if pos.winid == state.sidebar_window and pos.line > 0 then
    vim.api.nvim_win_set_cursor(state.sidebar_window, { pos.line, 0 })
    activate_current()
  end
end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Activate Orbit node" })
```

Setting the cursor explicitly makes the action robust even if mapping behavior
or UI input timing differs from the default mouse action. The window check
prevents clicks elsewhere from activating a stale sidebar cursor. `getmousepos`
returns a one-based line and reports line zero for the statusline or a window
separator.

Sources:

- Neovim mouse mappings and the `'mouse'` option: `/usr/share/nvim/runtime/doc/options.txt:4505-4537`
- Normal mouse cursor placement: `/usr/share/nvim/runtime/doc/gui.txt:208-213`
- Double-click mapping notation and `'mousetime'`: `/usr/share/nvim/runtime/doc/gui.txt:233-250`
- `getmousepos()` result semantics: `/usr/share/nvim/runtime/doc/vimfn.txt:3855-3884`

## Action Semantics To Decide

The existing keyboard model distinguishes expansion from activation:

- `l` expands profiles, schemas, object groups, tables, and saved-query directories.
- `h` collapses those nodes.
- `<CR>` binds a profile or opens a saved query; it does nothing for tree nodes.

Double-clicking a profile binds it and expands its schema. This keeps opening a
profile useful from the mouse while preserving `h` and `l` as the explicit
tree-collapse and tree-expansion controls for all node types. Double-clicking
a saved query opens it.

If the intended UX is one-click Explorer-style directory toggling, bind
`<LeftMouse>` instead and dispatch by node kind: toggle expandable nodes;
activate profiles and saved queries. This replaces native left-click behavior,
so it must explicitly set the clicked window cursor and should be backed by
tests for clicks on headers, the filter, and outside the sidebar.

## Test Seam

Mouse input is awkward to synthesize portably in the current headless suite.
Keep the behavior testable by extracting cursor-independent node action
functions, then test them through existing key mappings or direct calls. Add
one mapping-presence assertion for `<2-LeftMouse>` and regression coverage that
a node action reads `state.nodes` at the selected rendered line. Existing
Workspace tests establish this seam at `tests/workspace_spec.lua:35-51` and
`tests/workspace_spec.lua:156-201`.
