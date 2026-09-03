-- orbit/workspace.lua
--
-- This module owns the "workspace" experience of Orbit: a dedicated Neovim
-- tabpage that pairs a sidebar tree (this file's UI) with a query-editing
-- split and a results split. Think of it as the glue layer that sits on
-- top of the lower-level pieces:
--   * orbit.profiles     -- loads/validates connection profiles from disk
--   * orbit.adapters     -- gives you a "connector" for a profile's database
--     kind (postgres/sqlite/trino/...), used to run schema-object actions
--   * orbit.schema_tree   -- pure data/rendering helpers for the "Profiles"
--     part of the tree (schemas -> tables/views -> columns/keys/indexes);
--     this module renders that tree but does not know how it is structured
--   * orbit.schema_cache  -- caches schema/metadata lookups so re-expanding
--     a node doesn't always re-hit the database
--   * orbit.runner        -- executes SQL and returns rows
--   * orbit.results       -- opens/manages the results grid split
--   * orbit.feedback      -- shows "loading..."/"done" style status messages
--
-- Responsibilities of THIS file specifically:
--   1. Window/buffer management: creating the workspace tabpage, the
--      sidebar buffer/window, and the query buffer/window; reopening an
--      existing workspace instead of creating duplicates.
--   2. Tree rendering: turning plugin state (which profiles exist, which
--      profile's schema is expanded, which saved-query directories are
--      expanded, the current filter text, etc.) into plain text lines
--      drawn into the sidebar buffer, plus highlight groups and a mapping
--      from buffer line number -> the "node" (profile/table/query/etc.)
--      that line represents.
--   3. Expand/collapse state and navigation: keeping track of which nodes
--      are open, and letting the cursor position in the sidebar resolve
--      back to a node via that line-number map.
--   4. Keymaps/actions bound to the sidebar buffer: opening queries,
--      binding a profile to a query buffer, running schema-object actions
--      (sample data, table actions), copying qualified object names,
--      previewing/opening saved .sql files, filtering the tree, and
--      showing a help popup.
--   5. Wiring results back to the right query split, and tracking a
--      generation counter so that async schema/metadata loads started by
--      a since-replaced request don't clobber newer state.
--
-- State shape: each open workspace tabpage gets one "state" table (see
-- M.open below for every field) stored in the module-local `workspaces`
-- table, keyed by tabpage handle. Nearly every local function in this file
-- takes that `state` table as its first argument and mutates it directly;
-- there is no other persistence layer.
--
-- What this module exports (see the `M.*` functions near the bottom):
--   M.open(config)                        -- open/reveal the workspace tab
--   M.open_results(rows, options)         -- open a results split for the
--                                             workspace's query window
--   M.close(tabpage)                      -- close a workspace tab
--   M.is_workspace(tabpage)               -- true if a tab is an Orbit workspace
--   M.focus_filter()                      -- jump cursor into the filter input
--   M.select_profile(config, buffer, on_select) -- open the workspace and
--                                             let the user pick a profile to
--                                             bind to `buffer` via <CR>
local profiles = require("orbit.profiles")
local schema_tree = require("orbit.schema_tree")
local cache = require("orbit.schema_cache")
local feedback = require("orbit.feedback")
local results = require("orbit.results")
local adapters = require("orbit.adapters")
local runner = require("orbit.runner")

local M = {}
-- One entry per open workspace tabpage: tabpage handle -> state table.
-- A workspace's full lifetime is tracked here; see M.open/M.close.
local workspaces = {}
local fallback_icons = {
  collapsed = ">",
  column = ":",
  expanded = "v",
  folder = "+",
  profile = "@",
  query = "+",
  result = "=",
  saved_query = "#",
  table = "#",
  view = "~",
  workspace = "*",
}

-- Replace everything in the sidebar buffer below the two fixed header lines
-- (the "press ? to toggle help" line and the "Filter: ..." line) with the
-- freshly rendered tree text.
--   state: the workspace state table.
--   lines: array of strings, one per remaining buffer line, to write.
-- Side effects: temporarily makes the (normally read-only/"not modifiable")
-- sidebar buffer editable so nvim_buf_set_lines is allowed to write to it,
-- then restores it back to non-modifiable (unless the user is actively
-- typing into the filter box, in which case it's left modifiable).
-- `state.rendering` is set around the write so the `on_lines` autocommand
-- registered in configure_sidebar can tell "this changed because we just
-- redrew the tree" apart from "the user actually typed/edited text",
-- otherwise a render would be mistaken for a filter edit and loop forever.
local function set_content(state, lines)
  -- on_lines must distinguish this redraw from an edit to the filter input.
  state.rendering = true
  vim.bo[state.sidebar].modifiable = true
  -- Lines are 0-indexed and end-exclusive: {2, -1} means "from line 3 to
  -- the end of the buffer", i.e. everything after the two header lines.
  vim.api.nvim_buf_set_lines(state.sidebar, 2, -1, false, lines)
  if not state.filtering then
    vim.bo[state.sidebar].modifiable = false
  end
  state.rendering = false
end

-- Read back whatever the user has typed into the "Filter: " line (the
-- second line of the sidebar buffer) and strip the "Filter: " prefix so
-- callers get just the raw filter text.
--   state: the workspace state table.
-- Returns: the filter string (may be "").
local function filter_text(state)
  -- nvim_buf_get_lines uses a [start, end) range; {1, 2} is "just line 2"
  -- (0-indexed start, so line index 1 is the 2nd line).
  local line = vim.api.nvim_buf_get_lines(state.sidebar, 1, 2, false)[1] or "Filter: "
  return line:sub(#"Filter: " + 1)
end

-- Convenience alias: schema_tree.object_name formats a table/view row's
-- catalog/schema/name into a single dotted string (e.g. "db.public.users").
local object_name = schema_tree.object_name

-- Recursively walk a directory on disk and build a tree of saved .sql
-- query files, used to populate the "Saved queries:" section of the
-- sidebar. This is plain filesystem scanning -- no schema/database
-- involved.
--   directory: the filesystem path to scan (recurses into subfolders).
--   root_path: the top-level saved-query-location path this scan started
--     from; passed through unchanged on recursive calls so every
--     "saved_directory" node remembers which configured location it
--     belongs to (see saved_directory_key below, and the "r" refresh
--     keymap in configure_sidebar which needs to find the right
--     location entry to re-scan).
-- Returns: an array of nodes, each either
--   { kind = "saved_directory", name, path, root_path, children = {...} }
--   { kind = "saved_query", name, path }
-- sorted so subdirectories come before files, and alphabetically
-- (case-insensitive) within each group.
-- Side effects: none (pure filesystem read); does not touch buffers.
local function discover_saved_queries(directory, root_path)
  root_path = root_path or directory
  local function scan(path)
    -- vim.uv is Neovim's bundled libuv bindings -- fs_scandir/fs_scandir_next
    -- give a low-level, non-blocking-capable directory listing API (used
    -- here synchronously) similar to opendir/readdir in C.
    local handle = vim.uv.fs_scandir(path)
    if not handle then
      return {}
    end

    local entries = {}
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local entry_path = path .. "/" .. name
      if kind == "directory" then
        local children = scan(entry_path)
        -- Empty directories add no actionable node, while directories sort before SQL files.
        if #children > 0 then
          table.insert(entries, { kind = "saved_directory", name = name, path = entry_path, root_path = root_path, children = children })
        end
      elseif kind == "file" and name:lower():sub(-4) == ".sql" then
        table.insert(entries, { kind = "saved_query", name = name, path = entry_path })
      end
    end
    table.sort(entries, function(left, right)
      if left.kind ~= right.kind then
        return left.kind == "saved_directory"
      end
      return left.name:lower() < right.name:lower()
    end)
    return entries
  end

  return scan(directory)
end

-- Decide whether a saved-query node (a file or a directory) should be
-- shown given the current sidebar filter text.
--   node: a "saved_directory" or "saved_query" node as produced by
--     discover_saved_queries.
--   filter: the lowercase-insensitive substring the user typed into the
--     "Filter: " box ("" means "show everything").
-- Returns: true if the node's own name matches, OR (for directories) any
-- descendant file/directory matches -- this is what makes a parent
-- directory stay visible while filtered, as long as something inside it
-- still matches, even if the directory's own name doesn't.
local function saved_query_matches(node, filter)
  if filter == "" or node.name:lower():find(filter:lower(), 1, true) then
    return true
  end
  for _, child in ipairs(node.children or {}) do
    if saved_query_matches(child, filter) then
      return true
    end
  end
  return false
end

-- Build a stable, unique key for a "saved_directory" node so its expanded
-- state can be tracked in state.expanded_saved_dirs across re-renders
-- (nodes are rebuilt fresh on every render(), so we can't just use the
-- node table itself as the key -- it wouldn't be the same object next
-- time). Combining root_path and path (with a NUL separator that can't
-- appear in a real path) keeps directories with the same relative path
-- under two different saved-query locations from colliding.
local function saved_directory_key(node)
  return node.root_path .. "\0" .. node.path
end

-- The heart of the sidebar UI: rebuild the entire tree of text lines from
-- scratch (state.profiles + state.tree + state.saved_query_locations +
-- state.filter) and write it into the sidebar buffer.
--
-- This is called after almost every state change (profile expanded, node
-- toggled, schema loaded, filter typed, etc.) rather than doing an
-- incremental diff -- the tree is small enough that a full re-render each
-- time is simpler and cheap.
--
--   state: the workspace state table. Reads: state.profiles, state.tree,
--     state.schema_profile (which profile's schema is currently expanded),
--     state.filter, state.loading, state.saved_query_locations,
--     state.expanded_saved_dirs, state.config.icons. Writes:
--     state.nodes (rebuilt every call).
--
-- Returns: nothing.
--
-- Side effects:
--   * Rewrites the sidebar buffer contents via set_content.
--   * Clears and re-applies all highlight groups on the sidebar buffer
--     (nvim_buf_clear_namespace with namespace -1 clears highlights added
--     under the "default"/global namespace since we didn't create one of
--     our own; nvim_buf_add_highlight paints one highlight group over a
--     full line).
--   * Fully replaces state.nodes, which is the buffer-line-number -> node
--     lookup table used everywhere else in this file to figure out "what
--     is the cursor currently sitting on".
local function render(state)
  -- Icons are user-configurable (state.config.icons); anything the user
  -- doesn't override falls back to the plain-ASCII fallback_icons table
  -- defined at the top of the file. vim.tbl_extend("force", a, b) merges
  -- b's keys over a's, so user icons win.
  local icons = vim.tbl_extend("force", fallback_icons, state.config.icons or {})
  local lines = {
    "press ? to toggle help",
    "Filter: " .. state.filter,
    icons.workspace .. " Orbit Workspace",
    "",
    "Profiles:",
  }
  -- Line 2 (0-indexed) is "n Orbit Workspace" -- see the `{ group = ...,
  -- line = 2 }` note below: highlight lines are recorded here using the
  -- SAME 1-indexed numbering as `lines`, then converted to 0-indexed just
  -- before nvim_buf_add_highlight is called, further down.
  local highlights = { { group = "OrbitHeader", line = 2 } }
  -- Nodes are keyed by rendered buffer line so mappings can resolve the cursor without parsing text.
  state.nodes = {}
  for _, profile in ipairs(state.profiles) do
    -- Only one profile's schema tree can be expanded at a time; that
    -- profile's name is remembered in state.schema_profile.
    local expanded = state.schema_profile == profile.name
    local profile_matches = state.filter == "" or profile.name:lower():find(state.filter:lower(), 1, true) or profile.kind:lower():find(state.filter:lower(), 1, true)
    local tree_lines, tree_nodes, tree_highlights, has_matches = {}, {}, {}, false
    if expanded then
      -- Delegate to schema_tree.lines for everything under this profile
      -- (schemas -> tables/views -> columns/keys/indexes). If the profile
      -- line itself already matched the filter, pass "" down so every
      -- child of a matching profile is shown unfiltered; otherwise pass
      -- the real filter through so schema_tree can narrow its own lines.
      tree_lines, tree_nodes, tree_highlights, has_matches = schema_tree.lines(state.tree, profile, profile_matches and "" or state.filter, { icons = icons, loading = state.loading })
    end
    -- Show the profile's own line if it matches the filter directly, OR
    -- if it's expanded and something inside its (filtered) tree matched --
    -- otherwise a profile whose name doesn't match the filter but which
    -- contains a matching table would wrongly disappear.
    if profile_matches or (expanded and has_matches) then
      table.insert(lines, string.format("  %s %s %s (%s)", expanded and icons.expanded or icons.collapsed, icons.profile, profile.name, profile.kind))
      state.nodes[#lines] = { kind = "profile", profile = profile }
      table.insert(highlights, { group = "OrbitProfile", line = #lines })
    end
    if expanded and (profile_matches or has_matches) then
      -- `base` is how many lines exist so far (right after the profile's
      -- own line was appended). schema_tree.lines() numbers its own lines
      -- and nodes starting at 1, relative to its own output -- so every
      -- line number and node key it returns has to be shifted by `base`
      -- to land at the right position in this file's `lines`/`state.nodes`.
      local base = #lines
      for _, line in ipairs(tree_lines) do
        -- Indent every line coming from schema_tree by one more level,
        -- since it's nested under "Profiles:" -> this profile.
        table.insert(lines, "    " .. line)
      end
      for line_number, node in pairs(tree_nodes) do
        state.nodes[base + line_number] = node
      end
      for _, highlight in ipairs(tree_highlights) do
        table.insert(highlights, { group = highlight.group, line = base + highlight.line })
      end
    end
  end
  if #state.saved_query_locations > 0 then
    table.insert(lines, "")
    table.insert(lines, "Saved queries:")
    -- Recursively render one saved-query node (directory or file) and its
    -- children, indented by `depth` levels (2 spaces each).
    local function render_saved(node, depth)
      -- Skip whole subtrees that don't match the current filter (and
      -- don't have a matching descendant) so filtering also hides empty
      -- branches, not just non-matching leaves.
      if not saved_query_matches(node, state.filter) then
        return
      end
      if node.kind == "saved_directory" then
        -- Directories auto-expand while filtering so matches inside them
        -- are visible without the user having to manually open them.
        local expanded = state.expanded_saved_dirs[saved_directory_key(node)] or state.filter ~= ""
        table.insert(lines, string.format("%s%s %s %s", string.rep("  ", depth), expanded and icons.expanded or icons.collapsed, icons.folder, node.name))
        state.nodes[#lines] = node
        if expanded then
          if #node.children == 0 then
            table.insert(lines, string.rep("  ", depth + 1) .. "No saved SQL files")
          else
            for _, child in ipairs(node.children) do
              render_saved(child, depth + 1)
            end
          end
        end
      else
        table.insert(lines, string.format("%s%s %s", string.rep("  ", depth), icons.saved_query, node.name))
        state.nodes[#lines] = node
      end
    end
    for _, location in ipairs(state.saved_query_locations) do
      -- Wrap each configured saved-query location as a synthetic
      -- top-level "saved_directory" node so it renders the same way as
      -- any nested directory, using the location's own path as both its
      -- own path and its root_path (see saved_directory_key).
      render_saved({
        children = location.children,
        kind = "saved_directory",
        name = location.name,
        path = location.path,
        root_path = location.path,
      }, 1)
    end
  end
  -- The first 2 entries of `lines` are the fixed header lines that
  -- set_content never touches (it only rewrites from buffer line 3
  -- onward) -- so drop them here to avoid rendering them twice.
  set_content(state, vim.list_slice(lines, 3, #lines))
  -- Wipe every previous highlight before repainting, since node
  -- positions shift around on every render.
  vim.api.nvim_buf_clear_namespace(state.sidebar, -1, 0, -1)
  for _, highlight in ipairs(highlights) do
    -- highlight.line is 1-indexed (matches `lines`/`state.nodes`), but
    -- nvim_buf_add_highlight wants a 0-indexed line, hence the -1.
    -- The two -1/-1 col arguments mean "highlight the whole line".
    vim.api.nvim_buf_add_highlight(state.sidebar, -1, highlight.group, highlight.line - 1, 0, -1)
  end
end

-- Find (or, as a last resort, create) the window that queries/results
-- should be opened into -- i.e. the main editing split next to the
-- sidebar.
--   state: workspace state table; reads/writes state.query_window and
--     reads state.sidebar_window/state.tabpage.
-- Returns: a valid window handle to use as the "query window".
-- Side effects: may create a new vertical split (and move focus into it)
-- if no suitable window can be found; always writes the resolved window
-- back into state.query_window so future calls are cheap.
local function ensure_query_window(state)
  if vim.api.nvim_win_is_valid(state.query_window) then
    return state.query_window
  end
  -- The remembered query_window got closed (e.g. user closed that
  -- split) -- look for any other window in this tabpage that isn't the
  -- sidebar and isn't showing an Orbit results buffer, and adopt it.
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(state.tabpage)) do
    local buffer = vim.api.nvim_win_get_buf(window)
    if window ~= state.sidebar_window and vim.bo[buffer].filetype ~= "orbit-results" then
      state.query_window = window
      return window
    end
  end
  -- A workspace can survive after its query split closes, so recreate it only as a fallback.
  vim.api.nvim_set_current_win(state.sidebar_window)
  vim.cmd("rightbelow vsplit")
  state.query_window = vim.api.nvim_get_current_win()
  return state.query_window
end

-- Kick off an (asynchronous) load of a profile's table/view list and
-- expand that profile's node in the sidebar. This both flips the UI into
-- "this profile's schema is expanded" mode immediately (showing a
-- loading state) and starts the actual cache lookup, updating the tree
-- again once results (or an error) come back.
--   state: workspace state table.
--   profile: the profile table (from orbit.profiles) whose schema to load.
--   force: if true, bypass the schema cache and force a fresh reload
--     (used by the "r" refresh keymap); if falsy, a cached result may be
--     used and no network/DB round trip may be necessary.
-- Returns: nothing.
-- Side effects:
--   * Cancels/finishes any previous in-flight "loading schema" status
--     notice for this workspace.
--   * Bumps state.generation and captures the new value locally so that
--     if ANOTHER load_schema/load_metadata call happens before this one's
--     callback fires, the stale callback can detect it's been superseded
--     and do nothing (see the generation check inside the callback).
--   * Mutates state.selected, state.schema_profile, state.loading, and
--     (via schema_tree.reset/set_tables) the contents of state.tree.
--   * Calls render(state) twice: once synchronously to show a "loading"
--     placeholder, and again from the async callback once data/errors
--     arrive.
--   * Shows a start/finish feedback notice, and vim.notify()s on error.
local function load_schema(state, profile, force)
  if state.schema_notice then
    feedback.finish(state.schema_notice, "Schema load replaced", vim.log.levels.DEBUG)
  end
  state.generation = state.generation + 1
  local generation = state.generation
  local changed_profile = state.schema_profile ~= profile.name
  state.selected = profile
  state.schema_profile = profile.name
  if changed_profile then
    -- Switching to a different profile means the old profile's expanded
    -- schema/tables/metadata state is meaningless here, so wipe it.
    schema_tree.reset(state.tree)
  end
  state.loading = true
  render(state)
  state.schema_notice = feedback.start("Loading schema for " .. profile.name .. "...")
  cache.load_tables(profile, { refresh = force }, function(rows, err)
    -- Ignore callbacks from replaced loads and from a workspace that has been closed.
    if state.generation ~= generation or not vim.api.nvim_buf_is_valid(state.sidebar) then
      return
    end
    feedback.finish(state.schema_notice, err and "Schema load failed: " .. profile.name or string.format("Schema loaded: %d objects", #rows), err and vim.log.levels.ERROR or vim.log.levels.INFO)
    state.schema_notice = nil
    state.loading = false
    if not err then
      if force then
        -- A forced refresh also clears any expanded table/metadata state,
        -- since the underlying rows may have changed shape entirely.
        schema_tree.reset(state.tree)
      end
      schema_tree.set_tables(state.tree, rows)
    end
    render(state)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
    end
  end)
end

-- Collapse whichever profile's schema tree is currently expanded (the "Z"
-- keymap). No-ops if nothing is expanded.
--   state: workspace state table.
-- Returns: nothing.
-- Side effects: clears state.schema_profile and the entire schema_tree
-- state (state.tree), then re-renders.
local function collapse_schema_tree(state)
  if not state.schema_profile then
    return
  end
  state.schema_profile = nil
  schema_tree.reset(state.tree)
  render(state)
end

-- Re-read the profiles file from disk and refresh state to match it (used
-- by the "r" refresh keymap on a profile node, and when opening the
-- workspace picker via M.select_profile, so profile edits made outside
-- Neovim are picked up).
--   state: workspace state table.
-- Returns: the loaded profiles "document" (see orbit.profiles) on
--   success, or nil if the file failed to load (an error is already
--   reported via vim.notify in that case).
-- Side effects: overwrites state.profiles; re-resolves state.selected to
-- the (possibly updated) profile with the same name if one still exists;
-- if the profile whose schema was expanded (state.schema_profile) no
-- longer exists in the reloaded document, clears the expanded schema
-- state entirely. Does NOT call render() itself -- callers do that.
local function reload_profiles(state)
  local document, load_err = profiles.load(state.config.profile_path)
  if not document then
    vim.notify(load_err, vim.log.levels.ERROR)
    return nil
  end
  state.profiles = document.profiles
  if state.selected then
    state.selected = profiles.find(document, state.selected.name)
  end
  if state.schema_profile and not profiles.find(document, state.schema_profile) then
    state.schema_profile = nil
    schema_tree.reset(state.tree)
  end
  return document
end

-- Load one "metadata category" (e.g. columns, primary keys, foreign keys,
-- indexes -- see connector.metadata_categories) for a single table/view
-- row, if it isn't already loaded or already in flight. This is what
-- populates the sub-nodes under an expanded table in the schema tree.
--   state: workspace state table.
--   profile: the profile the table belongs to.
--   row: the table/view row (as returned by the connector) metadata is
--     being fetched for.
--   category: one metadata category descriptor, with at least `id` and
--     `label` fields.
--   show_progress: if true, show a "Loading X for Y..." feedback notice
--     while this request is in flight (used when the user explicitly
--     expands a single metadata node); if false, load silently in the
--     background (used when a table is expanded and ALL its categories
--     are pre-fetched at once, to avoid a wall of notices).
-- Returns: nothing.
-- Side effects: marks the category as "loading" in state.tree (so a
-- second call for the same row/category while the first is still in
-- flight is skipped -- see the early-return below), then on completion
-- stores the results (or an empty list on error) into state.tree,
-- re-renders, and reports success/failure via feedback/vim.notify.
local function load_metadata(state, profile, row, category, show_progress)
  -- Loaded and loading are distinct: the latter coalesces requests, the former permits empty results.
  if schema_tree.is_metadata_loaded(state.tree, row, category.id) or schema_tree.is_metadata_loading(state.tree, row, category.id) then
    return
  end
  -- Snapshot the generation counter so a callback from a workspace-level
  -- reset/reload that happens before this request finishes can be
  -- detected and ignored (see load_schema for the same pattern).
  local generation = state.generation
  schema_tree.set_metadata_loading(state.tree, row, category.id, true)
  local notice = show_progress and feedback.start("Loading " .. category.label .. " for " .. object_name(row) .. "...")
  cache.load_metadata(profile, row, category.id, {}, function(entries, err)
    if state.generation ~= generation or not vim.api.nvim_buf_is_valid(state.sidebar) then
      return
    end
    schema_tree.set_metadata_loading(state.tree, row, category.id, nil)
    -- On error, still record an empty result so is_metadata_loaded()
    -- becomes true and we don't retry forever; the error itself is
    -- reported separately via vim.notify below.
    schema_tree.set_metadata(state.tree, row, category.id, err and {} or entries)
    if notice then
      feedback.finish(notice, err and category.label .. " load failed: " .. object_name(row) or string.format("%s loaded: %d", category.label, #entries), err and vim.log.levels.ERROR or vim.log.levels.INFO)
    end
    render(state)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
    end
  end)
end

-- Expand a single metadata category node under a table (e.g. clicking
-- into "columns") and trigger its load with progress feedback shown.
--   state: workspace state table.
--   profile: profile the table belongs to.
--   row: the table/view row.
--   category: the metadata category descriptor being expanded.
-- Returns: nothing.
-- Side effects: toggles the node's expanded flag in state.tree, renders
-- immediately (so the UI shows the node as open, with a "loading..."
-- line if nothing is cached yet), then calls load_metadata with
-- show_progress = true.
local function expand_metadata(state, profile, row, category)
  schema_tree.toggle(state.tree, { category = category, kind = "metadata", profile = profile, row = row })
  render(state)
  load_metadata(state, profile, row, category, true)
end

-- Create a brand-new, empty SQL query buffer in a vertical split, bound to
-- whatever profile is currently "selected" (bound as the active profile
-- for the workspace). Triggered by the "n" keymap in the sidebar.
--   state: workspace state table.
-- Returns: nothing.
-- Side effects: refuses (with a warning) if no profile is selected yet;
-- otherwise moves focus into the query window, opens a new vertical
-- split with :vnew (a fresh unnamed scratch buffer), sets its filetype to
-- "sql", binds the profile onto it via orbit.query.bind_profile, tags the
-- buffer with which workspace tabpage it belongs to, and maps "/" (in
-- that buffer) to jump back to the sidebar's filter box.
local function new_query(state)
  if not state.selected then
    vim.notify("Expand an Orbit profile before creating a query", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(ensure_query_window(state))
  vim.cmd("vnew")
  vim.bo.filetype = "sql"
  require("orbit.query").bind_profile(0, state.selected)
  vim.b.orbit_workspace_tab = state.tabpage
  vim.keymap.set("n", "/", function()
    M.focus_filter()
  end, { buffer = 0, silent = true, nowait = true, desc = "Filter Orbit workspace" })
end

-- Wire up a query buffer (any buffer meant to hold/run SQL inside this
-- workspace, whether newly created or opened from a saved file) so it
-- participates correctly in the workspace: results know which tabpage to
-- return to, completion is available, and "/" jumps to the filter box
-- instead of doing a normal Neovim search.
--   state: workspace state table.
--   buffer: the buffer number to configure.
-- Returns: nothing.
-- Side effects: sets the buffer-local variable orbit_workspace_tab
-- (vim.b[buffer] is how you get/set buffer-local vim variables from
-- Lua); calls orbit.completion.attach(buffer) to enable SQL completion;
-- adds a buffer-local normal-mode "/" keymap.
local function configure_query_buffer(state, buffer)
  -- Workspace tagging routes later results back here and makes / target the sidebar filter.
  vim.b[buffer].orbit_workspace_tab = state.tabpage
  require("orbit.completion").attach(buffer)
  vim.keymap.set("n", "/", function()
    M.focus_filter()
  end, { buffer = buffer, silent = true, nowait = true, desc = "Filter Orbit workspace" })
end

-- Open a brand-new split containing a SQL statement that was generated on
-- the user's behalf (e.g. from a schema-object action like "generate
-- SELECT statement"), so the user can review/edit it before running it.
--   state: workspace state table.
--   profile: the profile to bind the new buffer to.
--   statement: the SQL text to seed the buffer with.
--   table: (optional) the table/view row this statement was generated
--     for; when present and its `.type == "table"`, the row and
--     statement are stashed on the buffer (as orbit_table /
--     orbit_table_statement buffer-local vars) so other parts of the
--     plugin can later tell "this buffer's query came from generating a
--     statement for this specific table".
-- Returns: nothing.
-- Side effects: opens a new split (:new, a horizontal split this time,
-- unlike new_query's :vnew), sets filetype to sql, runs
-- configure_query_buffer + bind_profile, optionally sets the two
-- buffer-local vars above, and replaces the buffer's contents with the
-- generated statement (split into lines on "\n").
local function open_generated_query(state, profile, statement, table)
  vim.api.nvim_set_current_win(ensure_query_window(state))
  vim.cmd("new")
  local buffer = vim.api.nvim_get_current_buf()
  vim.bo[buffer].filetype = "sql"
  configure_query_buffer(state, buffer)
  require("orbit.query").bind_profile(buffer, profile)
  if table and table.type == "table" then
    vim.b[buffer].orbit_table = vim.deepcopy(table)
    vim.b[buffer].orbit_table_statement = statement
  end
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(statement, "\n", { plain = true }))
end

-- Carry out one schema-object "action" picked from the vim.ui.select
-- menu (see select_object_action) or run directly via the "s" (sample)
-- keymap -- e.g. "generate SELECT", "sample rows", "show DDL", etc.
--   state: workspace state table.
--   profile: the profile the row belongs to.
--   connector: the adapter connector for that profile's database kind
--     (from orbit.adapters), used to actually run the statement.
--   row: the table/view row the action applies to.
--   action: one action descriptor, with `.kind`, `.label`, `.statement`
--     (and possibly `.id`).
-- Returns: nothing.
-- Side effects: either opens an editable query buffer (for
-- kind == "query_buffer" actions) via open_generated_query, or runs the
-- statement immediately through orbit.runner and opens the results grid
-- (M.open_results) with the returned rows; shows loading/finished
-- feedback notices either way, and discards results silently (with a
-- debug-level notice) if the workspace tabpage has since been closed or
-- replaced, since there'd be nowhere sensible to show them.
local function run_object_action(state, profile, connector, row, action)
  if action.kind == "query_buffer" then
    -- Generated statements are editable; metadata actions execute immediately into the result grid.
    open_generated_query(state, profile, action.statement, row)
    return
  end
  local notice = feedback.start("Loading " .. action.label:lower() .. " for " .. object_name(row) .. "...")
	runner.run(profile, action.statement, function(rows, err)
    if workspaces[state.tabpage] ~= state or not vim.api.nvim_tabpage_is_valid(state.tabpage) then
      feedback.finish(notice, "Schema action discarded", vim.log.levels.DEBUG)
      return
    end
    if err then
      feedback.finish(notice, "Schema action failed: " .. action.label, vim.log.levels.ERROR)
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    feedback.finish(notice, string.format("Loaded %s: %d rows", action.label:lower(), #rows))
    M.open_results(rows, {
      limit = state.config.result_limit,
      max_cell_width = state.config.max_cell_width,
      profile_name = profile.name,
      source_name = action.label .. " / " .. object_name(row),
      source_window = state.query_window,
      tabpage = state.tabpage,
    })
	end, connector)
end

-- Handle the "a" (actions) keymap on a table/view node: ask the
-- connector what actions are available for this kind of object (sample
-- data, generate DDL, etc.), then let the user pick one via vim.ui.select
-- (a floating/quickpick-style chooser -- its exact UI depends on any
-- ui-select plugin the user has installed) and run it.
--   state: workspace state table.
--   profile: the profile the row belongs to.
--   row: the table/view row the actions apply to.
-- Returns: nothing.
-- Side effects: notifies on error (no connector for this profile kind, or
-- connector doesn't support object actions); otherwise opens a
-- vim.ui.select prompt, and on selection defers to run_object_action.
local function select_object_action(state, profile, row)
	local connector, err = adapters.connector(profile)
	if not connector then
		vim.notify(err, vim.log.levels.ERROR)
		return
	end
	local actions
	if connector.object_actions then
		actions, err = connector.object_actions(profile.options, row, state.config.result_limit)
	else
		err = "schema object actions are not supported for profile kind: " .. tostring(profile.kind)
	end
  if not actions then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  vim.ui.select(actions, {
    prompt = "Orbit action for " .. object_name(row),
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if action then
			run_object_action(state, profile, connector, row, action)
    end
  end)
end

-- Handle the "y" (yank/copy) keymap on a table/view node: ask the
-- connector for that object's fully-qualified, SQL-safe identifier (e.g.
-- `"my_schema"."my_table"` for postgres) and put it in the unnamed
-- register so the user can paste it into a query.
--   profile: the profile the row belongs to (note: unlike most functions
--     here, this one does NOT take `state` -- it has no need to touch
--     workspace UI state, just the connector and the system clipboard
--     register).
--   row: the table/view row to name.
-- Returns: nothing.
-- Side effects: notifies on error if no connector is available;
-- otherwise writes the qualified name into register `"` (vim.fn.setreg)
-- and shows a confirmation notification.
local function copy_object_name(profile, row)
  -- Connector-specific qualification produces an identifier that can be pasted back into SQL.
	local connector, err = adapters.connector(profile)
	if not connector then
		vim.notify(err, vim.log.levels.ERROR)
		return
	end
	local name = connector.qualified_name(profile.options, row)
  vim.fn.setreg('"', name)
  vim.notify("Orbit name copied")
end

-- Handle activating (<CR>) a "saved_query" node: open the underlying
-- .sql file for editing in the query window, wired up like any other
-- query buffer.
--   state: workspace state table.
--   node: the "saved_query" node (has `.path`, `.name`).
-- Returns: nothing.
-- Side effects: refuses (with a warning) if no profile is currently
-- selected/bound; otherwise focuses the query window, opens the file
-- with :edit (vim.fn.fnameescape guards against the path containing
-- characters Vimscript would otherwise interpret specially), sets
-- filetype to sql, configures the buffer (completion, "/" mapping,
-- workspace tag), and binds the currently selected profile to it.
local function open_saved_query(state, node)
  if not state.selected then
    vim.notify("Expand an Orbit profile before opening a saved query", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(ensure_query_window(state))
  vim.cmd.edit(vim.fn.fnameescape(node.path))
  local buffer = vim.api.nvim_get_current_buf()
  vim.bo[buffer].filetype = "sql"
  configure_query_buffer(state, buffer)
  require("orbit.query").bind_profile(buffer, state.selected)
end

-- Handle the "P" (preview) keymap on a saved query file: show its
-- contents in a small read-only floating window without actually opening
-- it as an editable buffer or touching the query window.
--   node: the "saved_query" node to preview (`.path`, `.name`).
-- Returns: nothing.
-- Side effects: creates a new scratch buffer (nvim_create_buf(false,
-- true): not listed in :ls, and a "scratch" buffer that Neovim won't
-- prompt to save/won't back with a swapfile) filled with the file's
-- lines, sets it read-only, then opens it in a centered floating window
-- (nvim_open_win with relative = "editor" positions it relative to the
-- whole editor rather than a specific window; style = "minimal" strips
-- normal UI chrome like line numbers/statuscolumn). Maps "q" and <Esc>
-- in that buffer to close the floating window.
local function preview_saved_query(node)
  local lines = vim.fn.readfile(node.path)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].filetype = "sql"
  vim.bo[buffer].modifiable = false
  -- Size the floating window to fit the file (up to a reasonable cap),
  -- but never let it be so small it's unreadable, and never let it
  -- exceed the available editor space.
  local width = math.min(math.max(40, vim.o.columns - 8), 100)
  local height = math.min(math.max(3, #lines), math.max(3, vim.o.lines - 6))
  local window = vim.api.nvim_open_win(buffer, true, {
    border = "rounded",
    col = math.floor((vim.o.columns - width) / 2),
    height = height,
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    title = " " .. node.name .. " ",
    title_pos = "center",
    width = width,
  })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(window, true)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit saved query preview" })
  end
end

-- Move the cursor into the sidebar's "Filter: " line and drop into insert
-- mode positioned right after whatever's already typed, ready for the
-- user to keep typing a filter. Bound to "/" in the sidebar (see
-- configure_sidebar) and exposed publicly as M.focus_filter for other
-- modules (e.g. query buffers) to jump here too.
--   state: workspace state table.
-- Returns: nothing.
-- Side effects: switches focus to the sidebar window; sets
-- state.filtering = true (this suppresses re-locking the buffer to
-- read-only while the user is mid-edit -- see set_content); temporarily
-- makes the sidebar buffer modifiable; moves the cursor to line 2 (the
-- filter line), column = right after "Filter: " + existing filter text
-- (nvim_win_set_cursor rows are 1-indexed, columns are 0-indexed byte
-- offsets); and simulates pressing "a" (append after cursor) via
-- nvim_feedkeys to actually enter insert mode there.
local function focus_filter(state)
  vim.api.nvim_set_current_win(state.sidebar_window)
  state.filtering = true
  vim.bo[state.sidebar].modifiable = true
  vim.api.nvim_win_set_cursor(state.sidebar_window, { 2, #"Filter: " + #state.filter })
  vim.api.nvim_feedkeys("a", "n", false)
end

-- Handle the "?" keymap: show a small floating cheat-sheet listing the
-- sidebar/table/results keymaps.
--   state: workspace state table (currently unused by the body, but kept
--     for a consistent call signature with the other keymap handlers).
-- Returns: nothing.
-- Side effects: creates a read-only scratch buffer with the help text,
-- opens it in a centered floating window (same technique as
-- preview_saved_query), and maps "q"/"?"/<Esc> in it to close the window.
local function show_help(state)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
    "Orbit Workspace",
    "",
    "Sidebar: <CR> bind/open, h/l collapse/expand, Z collapse schema, n new query, r refresh",
    "Table: s sample, a actions, y copy name. Saved query: P preview. / filter, q close",
    "Results: h/j/k/l cells, y copy, <CR> inspect, <C-d>/<C-u> page",
    "Use your normal Neovim window mappings to move between panels.",
  })
  vim.bo[buffer].modifiable = false
  local window = vim.api.nvim_open_win(buffer, true, {
    border = "rounded",
    col = math.floor((vim.o.columns - 72) / 2),
    height = 5,
    relative = "editor",
    row = math.floor((vim.o.lines - 7) / 2),
    style = "minimal",
    title = " Orbit Help ",
    title_pos = "center",
    width = 72,
  })
  for _, key in ipairs({ "q", "?", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(window, true)
    end, { buffer = buffer, silent = true, nowait = true, desc = "Close Orbit help" })
  end
end

-- Wire up all the buffer-local behavior for the sidebar buffer: the
-- "live filter box" mechanism, and every normal-mode keymap that makes
-- the tree interactive (h/l collapse/expand, <CR> activate, double
-- click, r refresh, n new query, Z collapse schema, s/a/y table actions,
-- P preview saved query, ? help, q close). Called exactly once per
-- workspace, from M.open.
--   state: workspace state table; this function captures it in closures
--     for all the nested helper functions and keymap callbacks below, so
--     none of them need extra arguments for state.
-- Returns: nothing.
-- Side effects: attaches a buffer-change listener and many buffer-local
-- keymaps to state.sidebar / state.sidebar_window. This is the biggest
-- source of interactive behavior in the whole module.
local function configure_sidebar(state)
  -- nvim_buf_attach lets us run Lua code whenever the buffer's text
  -- changes, similar to a "TextChanged" autocommand but lower-level and
  -- fired more precisely/more often. on_lines fires on ANY edit to the
  -- buffer, including the ones WE make when redrawing the tree in
  -- render()/set_content() -- so this callback has to be careful to only
  -- react to genuine user edits.
  vim.api.nvim_buf_attach(state.sidebar, false, {
    on_lines = function()
      -- Only user edits to the first two lines update the filter and schedule a redraw.
      -- `modifiable` is true only while the user is actively editing the
      -- filter box (see focus_filter/set_content); `state.rendering` is
      -- true only while OUR OWN render() call is writing lines. Skipping
      -- both cases means this only fires for real keystrokes typed by
      -- the user into "Filter: ...".
      if vim.bo[state.sidebar].modifiable and not state.rendering then
        state.filter = filter_text(state)
        -- Deferred with vim.schedule because on_lines callbacks run in a
        -- restricted "fast event" context where many API calls (like the
        -- ones render() makes) aren't safe to call directly; scheduling
        -- defers the actual render to the next safe main-loop tick.
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(state.sidebar) then
            render(state)
          end
        end)
      end
    end,
  })
  vim.keymap.set("n", "/", function()
    focus_filter(state)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Filter Orbit workspace" })
  -- Leaving insert mode (finishing typing the filter) should lock the
  -- sidebar buffer back down to read-only. This is an "expr" mapping:
  -- the function's return value ("<Esc>") is what actually gets typed,
  -- so <Esc> still behaves normally -- this just piggybacks extra logic
  -- onto it.
  vim.keymap.set("i", "<Esc>", function()
    state.filtering = false
    vim.bo[state.sidebar].modifiable = false
    return "<Esc>"
  end, { buffer = state.sidebar, expr = true, silent = true, desc = "Finish Orbit filter" })
  -- Look up which tree node (if any) the cursor is currently sitting on,
  -- using the buffer-line -> node map that render() built. Row 1 of
  -- nvim_win_get_cursor's {row, col} pair is 1-indexed, matching how
  -- state.nodes is keyed.
  local function current_node()
    return state.nodes[vim.api.nvim_win_get_cursor(state.sidebar_window)[1]]
  end
  -- Is the node under the cursor currently "open"? Each node kind tracks
  -- its expanded state differently (profiles via state.schema_profile,
  -- saved directories via state.expanded_saved_dirs, everything else via
  -- schema_tree's own bookkeeping) so this normalizes all three into one
  -- boolean for the generic h/l and double-click handlers below.
  local function current_expanded()
    local node = current_node()
    if not node then
      return false
    end
    if node.kind == "profile" then
      return state.schema_profile == node.profile.name
    end
    if node.kind == "saved_directory" then
      return state.expanded_saved_dirs[saved_directory_key(node)]
    end
    return schema_tree.is_expanded(state.tree, node)
  end
  -- "h" keymap: collapse whatever node the cursor is on, if it's
  -- currently expanded. No-ops for node kinds that can't be
  -- collapsed (tables/queries that are already closed, leaf nodes, etc.).
  local function collapse_current()
    local node = current_node()
    if not node then
      return
    end
    if node.kind == "profile" and state.schema_profile == node.profile.name then
      state.schema_profile = nil
      schema_tree.reset(state.tree)
      render(state)
    elseif node.kind == "saved_directory" and state.expanded_saved_dirs[saved_directory_key(node)] then
      state.expanded_saved_dirs[saved_directory_key(node)] = nil
      render(state)
    elseif schema_tree.is_expanded(state.tree, node) then
      schema_tree.toggle(state.tree, node)
      render(state)
    end
  end
  -- "l" keymap: expand whatever node the cursor is on, if it isn't
  -- already expanded. Each node kind has different expand behavior:
  --   profile          -> start loading its schema (load_schema)
  --   saved_directory  -> just flip the expanded flag and re-render
  --   table            -> mark expanded AND kick off background loads
  --                       for every metadata category it has (columns,
  --                       keys, indexes, ...) so they start fetching
  --                       right away instead of waiting for the user to
  --                       expand each one individually
  --   metadata         -> defer to expand_metadata (loads that one
  --                       category with progress feedback)
  --   schema / group   -> just a plain expand + re-render, no loading
  --                       needed since schema_tree already has this data
  local function expand_current()
    local node = current_node()
    if not node then
      return
    end
    if node.kind == "profile" and state.schema_profile ~= node.profile.name then
      load_schema(state, node.profile)
    elseif node.kind == "saved_directory" and not state.expanded_saved_dirs[saved_directory_key(node)] then
      state.expanded_saved_dirs[saved_directory_key(node)] = true
      render(state)
    elseif node.kind == "table" and not schema_tree.is_expanded(state.tree, node) then
      schema_tree.toggle(state.tree, node)
      render(state)
			local connector = adapters.connector(node.profile)
			for _, category in ipairs(connector and connector.metadata_categories and connector.metadata_categories(node.profile.options, node.row) or {}) do
        load_metadata(state, node.profile, node.row, category, false)
      end
    elseif node.kind == "metadata" and not schema_tree.is_expanded(state.tree, node) then
      expand_metadata(state, node.profile, node.row, node.category)
    elseif (node.kind == "schema" or node.kind == "group") and not schema_tree.is_expanded(state.tree, node) then
      schema_tree.toggle(state.tree, node)
      render(state)
    end
  end
  -- "<CR>" keymap: "activate" whatever node the cursor is on.
  --   profile     -> select this profile as the workspace's active
  --                  profile and bind it onto the "target" buffer. The
  --                  target is normally the query window's buffer, but
  --                  if M.select_profile set up a pending
  --                  binding_target/binding_callback (the "pick a
  --                  profile for this specific buffer" flow), that
  --                  buffer/callback is used instead and then cleared.
  --   saved_query -> open the underlying .sql file (open_saved_query)
  -- Other node kinds do nothing on <CR> (use h/l to expand/collapse them
  -- instead).
  local function activate_current()
    local node = current_node()
    if node and node.kind == "profile" then
      state.selected = node.profile
      local target = state.binding_target or vim.api.nvim_win_get_buf(ensure_query_window(state))
      require("orbit.query").bind_profile(target, node.profile)
      local callback = state.binding_callback
      state.binding_target = nil
      state.binding_callback = nil
      if callback then
        callback(node.profile)
      end
    elseif node and node.kind == "saved_query" then
      open_saved_query(state, node)
    end
  end
  vim.keymap.set("n", "h", collapse_current, { buffer = state.sidebar, silent = true, nowait = true, desc = "Collapse Orbit node" })
  vim.keymap.set("n", "l", expand_current, { buffer = state.sidebar, silent = true, nowait = true, desc = "Expand Orbit node" })
  vim.keymap.set("n", "<CR>", activate_current, { buffer = state.sidebar, silent = true, nowait = true, desc = "Bind Orbit profile" })
  -- Double-click: move the cursor to the clicked line first (mouse
  -- clicks don't automatically move the cursor before a mapped
  -- callback runs), then activate + toggle expand/collapse on that node.
  -- vim.fn.getmousepos() reports the click position, including which
  -- window (`winid`) and 1-indexed buffer `line` it landed on; a
  -- `position.line` of 0 means the click wasn't on any actual text line
  -- (e.g. below the last line), so that's ignored.
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local position = vim.fn.getmousepos()
    if position.winid == state.sidebar_window and position.line > 0 then
      vim.api.nvim_win_set_cursor(state.sidebar_window, { position.line, 0 })
      local node = current_node()
      if node and node.kind == "profile" then
        -- Profile double-click both binds the profile and toggles its schema tree.
        activate_current()
      end
      if current_expanded() then
        collapse_current()
      else
        expand_current()
      end
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Activate Orbit node" })
  -- "r" keymap: refresh whatever's under the cursor.
  --   profile         -> reload the profiles file from disk, re-resolve
  --                      this profile by name (it may have changed), and
  --                      force a fresh (non-cached) schema load for it.
  --   saved_directory -> re-scan that saved-query location's directory
  --                      tree from disk (picks up files added/removed/
  --                      renamed outside Neovim) and re-render.
  vim.keymap.set("n", "r", function()
    local node = current_node()
    if node and node.kind == "profile" then
      local document = reload_profiles(state)
      local profile = document and profiles.find(document, node.profile.name)
      if profile then
        load_schema(state, profile, true)
      elseif document then
        render(state)
      end
    elseif node and node.kind == "saved_directory" then
      for _, location in ipairs(state.saved_query_locations) do
        if location.path == node.root_path then
          location.children = discover_saved_queries(location.path)
          break
        end
      end
      render(state)
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Refresh Orbit profile" })
  -- "n" keymap: create a new empty query buffer bound to the currently
  -- selected profile.
  vim.keymap.set("n", "n", function()
    new_query(state)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "New Orbit query" })
  -- "Z" keymap: collapse whichever profile's schema tree is expanded,
  -- regardless of where the cursor currently is (unlike "h", which only
  -- collapses the node under the cursor).
  vim.keymap.set("n", "Z", function()
    collapse_schema_tree(state)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Collapse Orbit schema tree" })
  -- "s" keymap: on a table/view node, find its "sample" action (by
  -- action.id == "sample") among the connector's object actions and run
  -- it directly -- a shortcut for the most common entry in the "a" menu
  -- below, without having to pick it from a list.
  vim.keymap.set("n", "s", function()
    local node = current_node()
    if node and node.kind == "table" then
			local connector, err = adapters.connector(node.profile)
			if not connector then
				vim.notify(err, vim.log.levels.ERROR)
				return
			end
			local actions
			if connector.object_actions then
				actions, err = connector.object_actions(node.profile.options, node.row, state.config.result_limit)
			else
				err = "schema object actions are not supported for profile kind: " .. tostring(node.profile.kind)
			end
			if not actions then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end
      for _, action in ipairs(actions) do
        if action.id == "sample" then
				run_object_action(state, node.profile, connector, node.row, action)
          return
        end
      end
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Open Orbit sample statement" })
  -- "a" keymap: on a table/view node, open the full action picker
  -- (vim.ui.select) so the user can choose from every available action,
  -- not just "sample".
  vim.keymap.set("n", "a", function()
    local node = current_node()
    if node and node.kind == "table" then
      select_object_action(state, node.profile, node.row)
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Select Orbit schema object action" })
  -- "y" keymap: on a table/view node, copy its fully-qualified name to
  -- the clipboard/unnamed register.
  vim.keymap.set("n", "y", function()
    local node = current_node()
    if node and node.kind == "table" then
      copy_object_name(node.profile, node.row)
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Copy Orbit object name" })
  -- "P" keymap: on a saved_query node, show a read-only floating preview
  -- of the file without opening it as an editable buffer.
  vim.keymap.set("n", "P", function()
    local node = current_node()
    if node and node.kind == "saved_query" then
      preview_saved_query(node)
    end
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Preview Orbit saved query" })
  -- "?" keymap: show the help popup, from anywhere in the sidebar.
  vim.keymap.set("n", "?", function()
    show_help(state)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Show Orbit help" })
  -- "q" keymap: close the whole workspace tabpage.
  vim.keymap.set("n", "q", function()
    M.close(state.tabpage)
  end, { buffer = state.sidebar, silent = true, nowait = true, desc = "Close Orbit workspace" })
end

-- Show or hide the sidebar window for a workspace whose tabpage is
-- already open, without touching the query window's contents. Used when
-- M.open() is called again while a workspace tab already exists.
--   state: workspace state table.
-- Returns: nothing.
-- Side effects: if the sidebar window is currently open/valid, closes it
-- (nvim_win_close with the second argument `false` meaning "don't force
-- -- refuse if it has unsaved changes", which is moot here since it's a
-- scratch buffer). Otherwise recreates the sidebar split: focuses the
-- query window, opens a new vertical split pinned to the far left
-- ("topleft vsplit"), points that window at the existing sidebar buffer,
-- and resizes it to the configured width.
local function toggle_sidebar(state)
  if vim.api.nvim_win_is_valid(state.sidebar_window) then
    vim.api.nvim_win_close(state.sidebar_window, false)
    return
  end

  vim.api.nvim_set_current_win(ensure_query_window(state))
  vim.cmd("topleft vsplit")
  state.sidebar_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.sidebar_window, state.sidebar)
  vim.api.nvim_win_set_width(state.sidebar_window, state.config.workspace_sidebar_width or 32)
end

-- Find the one workspace tabpage that's still valid, if any, and switch
-- to it. Orbit only ever keeps a single workspace tab open at a time
-- (opening the workspace again just reveals the existing tab rather than
-- creating a second one).
-- Returns: the existing workspace's state table, or nil if none is open.
-- Side effects: switches the current tabpage to the found workspace, if
-- one exists. Also incidentally prunes nothing itself, but note that
-- entries for since-closed tabpages are cleaned up elsewhere (M.close);
-- this just skips over any that nvim_tabpage_is_valid reports as gone.
local function existing_workspace()
  -- Orbit intentionally keeps one workspace tabpage, reopening it instead of creating duplicates.
  for tabpage, state in pairs(workspaces) do
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      vim.api.nvim_set_current_tabpage(tabpage)
      return state
    end
  end
end

-- Public entry point: open the Orbit workspace, creating it if it
-- doesn't exist yet or revealing/toggling the sidebar of the existing one.
--   config: the plugin's resolved configuration table (see orbit/init.lua
--     or wherever config is built) -- fields used here include
--     .profile_path, .workspace_sidebar_width, .saved_query_dirs,
--     .icons (read later during render), .result_limit,
--     .max_cell_width, .workspace_result_ratio (read later).
-- Returns: the workspace state table (either the existing one, or the
-- newly created one).
-- Side effects (new workspace only): opens a new tabpage (:tabnew),
-- creates the sidebar scratch buffer and its vertical split, sets the
-- query buffer's filetype to sql, loads profiles from disk, builds the
-- full state table (see the field-by-field literal below -- this is the
-- authoritative list of what a workspace's state contains), scans every
-- configured saved-query directory, registers the workspace in the
-- module-local `workspaces` table, configures the query buffer and the
-- sidebar's keymaps/behavior, and does the first render(). Warns via
-- vim.notify if no profiles could be loaded.
function M.open(config)
  local state = existing_workspace()
  if state then
    toggle_sidebar(state)
    return state
  end

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local query_window = vim.api.nvim_get_current_win()
  vim.bo.filetype = "sql"
  local sidebar = vim.api.nvim_create_buf(false, true)
  vim.cmd("topleft vsplit")
  local sidebar_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(sidebar_window, sidebar)
  vim.api.nvim_win_set_width(sidebar_window, config.workspace_sidebar_width or 32)
  vim.bo[sidebar].filetype = "orbit-workspace"
  vim.api.nvim_set_current_win(query_window)

  local document = profiles.load(config.profile_path)
  -- This literal is the full shape of a workspace's state table. Fields
  -- not otherwise obvious:
  --   expanded_saved_dirs -- set of saved_directory_key(node) -> true,
  --     tracks which saved-query folders are open (separate from
  --     schema_tree's own expand tracking, since saved queries aren't
  --     part of schema_tree at all).
  --   filter        -- current text typed into "Filter: ".
  --   filtering     -- true only while the user is actively editing the
  --     filter box (keeps the buffer modifiable and stops on_lines from
  --     mistaking our own render for a user edit).
  --   generation    -- incremented whenever a schema/metadata load is
  --     (re)started; async callbacks compare against this to detect
  --     they've been superseded and should do nothing.
  --   loading       -- true while a profile's table list is being
  --     fetched, used by schema_tree.lines to show a "loading..." line.
  --   nodes         -- buffer line number -> node table, rebuilt by
  --     every render() call; this is how keymaps resolve "what is the
  --     cursor on" without parsing the rendered text back into data.
  --   profiles      -- the list of profile tables loaded from disk.
  --   query_window  -- the window used for opening/editing queries.
  --   saved_query_locations -- one entry per configured saved-query
  --     directory: { children, name, path } (children from
  --     discover_saved_queries).
  --   schema_profile -- name of the profile whose schema tree is
  --     currently expanded (nil if none), since only one can be open.
  --   selected      -- the profile currently "bound"/active for this
  --     workspace (used by "n new query", "P"/saved query open, etc).
  --   sidebar / sidebar_window -- the sidebar's buffer and window
  --     handles.
  --   tabpage       -- this workspace's tabpage handle; also the key
  --     used in the module-local `workspaces` table.
  --   tree          -- the schema_tree state (expanded nodes, cached
  --     tables/metadata) for the CURRENTLY expanded profile only; reset
  --     whenever the expanded profile changes.
  -- (binding_target / binding_callback are added later, only when
  -- M.select_profile is used, and removed again once consumed by
  -- activate_current.)
  local state = {
    config = config,
    expanded_saved_dirs = {},
    filter = "",
    filtering = false,
    generation = 0,
    loading = false,
    nodes = {},
    profiles = document and document.profiles or {},
    query_window = query_window,
    saved_query_locations = {},
    schema_profile = nil,
    selected = nil,
    sidebar = sidebar,
    sidebar_window = sidebar_window,
    tabpage = tabpage,
    tree = schema_tree.new(),
  }
  for _, location in ipairs(config.saved_query_dirs or {}) do
    table.insert(state.saved_query_locations, {
      children = discover_saved_queries(location.path),
      name = location.name,
      path = location.path,
    })
  end
  workspaces[tabpage] = state
  configure_query_buffer(state, vim.api.nvim_win_get_buf(query_window))
  vim.bo[sidebar].modifiable = true
  vim.api.nvim_buf_set_lines(sidebar, 0, -1, false, { "press ? to toggle help", "Filter: " })
  vim.bo[sidebar].modifiable = false
  configure_sidebar(state)
  render(state)
  if not document then
    vim.notify("Orbit workspace opened without profiles", vim.log.levels.WARN)
  end
  return state
end

-- Public entry point used by other modules (e.g. schema-object actions,
-- or a plain ":OrbitRun" command) to display query results in a split
-- sized/managed by the workspace, rather than each caller reinventing
-- result-window geometry.
--   rows: the result rows to display (passed straight through to
--     orbit.results.open).
--   options: options for orbit.results.open; must include `tabpage` (used
--     to look up this workspace's config) and is expected to include
--     `source_window` (read by the on_quit handler installed below).
--     `height` and `on_quit` are set/overwritten by this function.
-- Returns: whatever orbit.results.open returns.
-- Side effects: computes a result-window height as a fraction of the
-- total editor height (state.config.workspace_result_ratio, default
-- 30%, floored and never below 6 rows), and installs an on_quit callback
-- that returns focus to the query window the results came from when the
-- results window is closed. Delegates the actual window creation to
-- orbit.results.open.
function M.open_results(rows, options)
  local state = workspaces[options.tabpage]
  options.height = math.max(6, math.floor(vim.o.lines * ((state and state.config.workspace_result_ratio) or 0.30)))
  options.on_quit = function(_, source_window)
    -- The workspace owns result geometry and returns focus to the originating query split.
    if vim.api.nvim_win_is_valid(source_window) then
      vim.api.nvim_set_current_win(source_window)
    end
  end
  return results.open(rows, options)
end

-- Public entry point: close a workspace tabpage entirely (bound to the
-- "q" sidebar keymap, and usable by other callers too).
--   tabpage: the tabpage to close; defaults to the current tabpage if
--     omitted.
-- Returns: nothing.
-- Side effects: removes the workspace's entry from the module-local
-- `workspaces` table (so it's no longer tracked even if the tabclose
-- below fails or the tabpage is already gone) and, if the tabpage is
-- still valid, switches to it and runs :tabclose to actually close it.
function M.close(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local state = workspaces[tabpage]
  if not state then
    return
  end
  workspaces[tabpage] = nil
  if vim.api.nvim_tabpage_is_valid(tabpage) then
    vim.api.nvim_set_current_tabpage(tabpage)
    vim.cmd("tabclose")
  end
end

-- Public helper: is the given (or current) tabpage an Orbit workspace?
-- Used by other modules that behave differently inside a workspace tab
-- (e.g. deciding whether "/" should filter the sidebar or search
-- normally).
--   tabpage: tabpage handle to check; defaults to the current tabpage.
-- Returns: boolean.
function M.is_workspace(tabpage)
  return workspaces[tabpage or vim.api.nvim_get_current_tabpage()] ~= nil
end

-- Public helper: if the current tabpage is an Orbit workspace, focus its
-- filter box (same as pressing "/" in the sidebar). Used by query
-- buffers' own "/" mapping (see configure_query_buffer/new_query) so
-- typing "/" from a query split still reaches the workspace filter.
-- Returns: true if the current tabpage was a workspace (and focus was
-- moved), false otherwise.
function M.focus_filter()
  local state = workspaces[vim.api.nvim_get_current_tabpage()]
  if state then
    focus_filter(state)
    return true
  end
  return false
end

-- Public entry point for "pick a profile and bind it to this buffer" --
-- used by commands/mappings elsewhere in the plugin (e.g. binding a
-- profile to an ad-hoc SQL buffer that isn't part of a workspace query
-- split). Opens/reveals the shared workspace, refreshes its profile
-- list, and arranges for the NEXT profile the user activates (<CR>) in
-- the sidebar to be bound to `buffer` and reported to `on_select`,
-- instead of the usual "bind to the query window" behavior.
--   config: plugin config, forwarded to M.open if a workspace needs to
--     be created.
--   buffer: the buffer number that should receive the chosen profile's
--     binding.
--   on_select: callback invoked with the chosen profile once the user
--     activates a profile node (or never, if they don't).
-- Returns: nothing.
-- Side effects: may create the workspace tabpage (M.open); reloads
-- profiles from disk and re-renders if that succeeds; sets
-- state.binding_target/state.binding_callback (consumed and cleared by
-- activate_current once the user picks a profile); focuses the filter
-- box so the user can immediately narrow down the profile list.
function M.select_profile(config, buffer, on_select)
  local state = existing_workspace() or M.open(config)
  local document = reload_profiles(state)
  if document then
    render(state)
  end
  state.binding_target = buffer
  -- Binding is deferred until the profile node is activated in the shared workspace picker.
  state.binding_callback = on_select
  focus_filter(state)
end

return M
