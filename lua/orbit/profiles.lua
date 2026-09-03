-- orbit/profiles.lua
--
-- This module owns Orbit's "connection profiles" -- the saved database
-- connection configs the user sets up once and then picks from when running
-- queries. A profile is a small table like:
--   { name = "local-pg", kind = "postgres", options = { database = "app", ... } }
-- (kind is one of "postgres", "sqlite", "trino"; options holds whatever
-- connection details that database adapter needs, validated below via
-- require("orbit.adapters").validate_options).
--
-- All profiles for a user live together in a single JSON file on disk (by
-- default at M.default_path(), but overridable via M.config.profile_path in
-- lua/orbit/init.lua). That file's shape (the "document") is:
--   { version = 1, profiles = { <profile>, <profile>, ... } }
-- This module is the only place that reads or writes that file: M.load reads
-- and validates it, M.write validates and atomically saves it, M.ensure makes
-- sure the file exists (creating an empty one if not) and has safe
-- permissions, and M.find looks up one profile by name within an
-- already-loaded document.
--
-- Because profile options can contain database credentials, this module is
-- deliberately strict about file permissions: it refuses to read a profiles
-- file that isn't owner-only (mode 0600), and after writing it always chmods
-- the result back to 0600.
--
-- Other Orbit modules don't read/write the profiles file directly -- e.g.
-- lua/orbit/query.lua's M.profile_for_buffer calls M.load + M.find to resolve
-- which profile is bound to a buffer (the binding itself, i.e. "buffer X uses
-- profile Y", is just a buffer-local vim variable, not stored in this file).
-- The workspace/profile-picker UI is expected to call M.load, M.write, and
-- M.ensure when the user creates, edits, or browses profiles.
--
-- This module exports a table `M` with the functions documented below. It
-- does not keep any state of its own between calls (no caching) -- every
-- M.load re-reads and re-parses the file from disk.
local uv = vim.uv
local bit = bit
local adapters = require("orbit.adapters")

local M = {}

-- Reads the entire contents of the profiles file at `path`, but only if it
-- looks safe to do so.
--
-- Parameters:
--   path (string): filesystem path to the profiles JSON file.
--
-- Returns:
--   On success: the raw file contents as a string (still JSON-encoded; not
--     parsed by this function).
--   On failure: nil, plus a string describing what went wrong (couldn't
--     open/stat/read the file, or the file's permissions are too permissive).
--
-- Side effects: performs synchronous file I/O using libuv's low-level fs_*
-- functions (uv.fs_open/fs_fstat/fs_read/fs_close) rather than Lua's built-in
-- io library -- this gives access to the file's permission bits via fs_fstat,
-- which Lua's io.open does not expose.
local function read(path)
  local fd, open_err = uv.fs_open(path, "r", 0)
  if not fd then
    return nil, "cannot open profile file: " .. open_err
  end

  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, "cannot stat profile file: " .. stat_err
  end
  -- Profile files may contain credentials, so reject them before parsing unless owner-only.
  -- stat.mode includes file-type bits along with the permission bits, so
  -- bit.band(stat.mode, 511) masks it down to just the low 9 permission bits
  -- (511 == 0o777). 384 is 0o600 (owner read/write, nothing for group/other).
  -- If the permission bits are anything other than exactly 0600, refuse to
  -- read the file at all -- better to fail loudly than silently read a file
  -- that other users/processes on the machine could also read.
  if bit.band(stat.mode, 511) ~= 384 then
    uv.fs_close(fd)
    return nil, "profile file must use owner-only mode 0600"
  end

  local contents, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not contents then
    return nil, "cannot read profile file: " .. read_err
  end

  return contents
end

-- Small validation helper: checks that `value` is a non-empty string,
-- producing a friendly error message referencing which profile and field
-- failed if not.
--
-- Parameters:
--   value (any): the value being validated (expected to be a string).
--   field (string): human-readable name of the field being checked, used in
--     the error message (e.g. "name" or "options.database").
--   profile_name (string): the name of the profile this field belongs to,
--     used in the error message so the user knows which profile is broken.
--
-- Returns:
--   On success: true.
--   On failure: nil, plus an error message like `profile "foo" requires
--   options.database`.
local function require_string(value, field, profile_name)
  if type(value) ~= "string" or value == "" then
    return nil, string.format("profile %q requires %s", profile_name, field)
  end
  return true
end

-- Validates a single profile table's own shape and required fields (but not
-- adapter-specific option validation -- see validate_document, which also
-- calls adapters.validate_options).
--
-- Parameters:
--   profile (any): one entry from the document's `profiles` array. Expected
--     shape: { name = string, kind = "trino"|"sqlite"|"postgres", options =
--     table }.
--
-- Returns:
--   On success: true.
--   On failure: nil, plus a string describing the first problem found (not
--     an object, missing/empty name, unsupported kind, missing options
--     table, or a required option field missing for that kind).
--
-- No side effects (pure validation).
local function validate_profile(profile)
  if type(profile) ~= "table" then
    return nil, "each profile must be an object"
  end

  local valid, err = require_string(profile.name, "name", "<unnamed>")
  if not valid then
    return nil, err
  end
	-- Only these three database kinds are supported; anything else (typo,
	-- unsupported future kind, missing field entirely) is rejected up front.
	if profile.kind ~= "trino" and profile.kind ~= "sqlite" and profile.kind ~= "postgres" and profile.kind ~= "vertica" then
    return nil, string.format("profile %q has unsupported kind %q", profile.name, tostring(profile.kind))
  end
  if type(profile.options) ~= "table" then
    return nil, string.format("profile %q requires options", profile.name)
  end

	-- Each connector kind has its own minimum set of required connection
	-- fields: Trino needs a server/user/catalog to know where and how to
	-- connect; Postgres needs at least a database name (host/user/etc are
	-- presumably optional/defaulted); anything else (sqlite) just needs a
	-- file `path`.
	local required = profile.kind == "trino" and { "server", "user", "catalog" }
		or profile.kind == "postgres" and { "database" }
		or profile.kind == "vertica" and { "host", "user", "database" }
		or { "path" }
  for _, field in ipairs(required) do
    valid, err = require_string(profile.options[field], "options." .. field, profile.name)
    if not valid then
      return nil, err
    end
  end

  return true
end

-- Validates an entire profiles document -- the whole decoded JSON structure
-- that's read from (or about to be written to) the profiles file. This is
-- the main gatekeeper: both M.load and M.write refuse to proceed with a
-- document that fails this check.
--
-- Parameters:
--   document (any): the value to validate, expected shape:
--     { version = 1, profiles = { <profile>, ... } }.
--
-- Returns:
--   On success: true.
--   On failure: nil, plus a string describing the first problem found (not a
--     table, wrong/unsupported version, `profiles` isn't an array, an
--     individual profile fails validate_profile, a duplicate profile name, or
--     an adapter rejects a profile's options).
--
-- Side effects: none directly, but it does call
-- require("orbit.adapters").validate_options(profile) for every profile,
-- which may perform its own kind-specific checks.
local function validate_document(document)
  if type(document) ~= "table" then
    return nil, "profile file contains invalid JSON"
  end
  -- Only one document format is understood right now; this exists so a
  -- future breaking format change can be detected explicitly rather than
  -- silently misinterpreted.
  if document.version ~= 1 then
    return nil, string.format("unsupported profile file version: %s", tostring(document.version))
  end
  -- vim.islist checks that `profiles` is a proper sequential array (1..n,
  -- no holes/non-integer keys), not just any table -- JSON arrays decode to
  -- Lua tables, but so do JSON objects, so this distinguishes the two.
  if type(document.profiles) ~= "table" or not vim.islist(document.profiles) then
    return nil, "profile file requires a profiles array"
  end

  -- Track which profile names have already been seen, so duplicates (which
  -- would make M.find ambiguous) are rejected.
  local names = {}
  for _, profile in ipairs(document.profiles) do
    local valid, validation_err = validate_profile(profile)
    if not valid then
      return nil, validation_err
    end
    if names[profile.name] then
      return nil, string.format("duplicate profile name: %q", profile.name)
    end
    -- Beyond the generic shape checks in validate_profile above, let the
    -- relevant database adapter (postgres/sqlite/trino) apply any
    -- connector-specific validation of profile.options it wants.
    local options_valid, options_err = adapters.validate_options(profile)
    if not options_valid then
      return nil, options_err
    end
    names[profile.name] = true
  end

  return true
end

-- Returns the default filesystem path Orbit uses for the profiles file when
-- no explicit path is configured. This matches the default for
-- config.profile_path in lua/orbit/init.lua's M.config.
--
-- Parameters: none.
--
-- Returns (string): an absolute path, e.g.
-- "/home/<user>/.local/share/orbit.nvim/profiles.json". vim.fn.expand resolves
-- the leading "~" to the user's actual home directory.
--
-- Side effects: none (does not touch the filesystem, just computes a path
-- string).
function M.default_path()
  return vim.fn.expand("~/.local/share/orbit.nvim/profiles.json")
end

-- Loads, parses, and validates the profiles document from disk. This is the
-- main function other modules call to get the list of saved connection
-- profiles (e.g. lua/orbit/query.lua's M.profile_for_buffer calls this).
--
-- Parameters:
--   path (string|nil): path to the profiles JSON file. If nil, falls back to
--     M.default_path().
--
-- Returns:
--   On success: the decoded document table, shape { version = 1, profiles =
--     { <profile>, ... } }.
--   On failure: nil, plus a string error message (file couldn't be read
--     safely, contents aren't valid JSON, or the document fails validation).
--
-- Side effects: reads the file from disk (via the local `read` function
-- above, including its owner-only permission check) and JSON-decodes its
-- contents with vim.json.decode, wrapped in pcall since decode raises a Lua
-- error on malformed JSON rather than returning nil/err.
function M.load(path)
  path = path or M.default_path()
  local contents, read_err = read(path)
  if not contents then
    return nil, read_err
  end

  local ok, document = pcall(vim.json.decode, contents)
  if not ok then
    return nil, "profile file contains invalid JSON"
  end
  local valid, validation_err = validate_document(document)
  if not valid then
    return nil, validation_err
  end

  return document
end

-- Finds a single profile by name within an already-loaded document.
--
-- Parameters:
--   document (table): a document as returned by M.load, with a `profiles`
--     array.
--   name (string): the profile name to look for (matched exactly, case
--     sensitive).
--
-- Returns: the matching profile table, or nil if no profile in the document
-- has that name.
--
-- Side effects: none (pure lookup over the given in-memory table; does not
-- touch disk).
function M.find(document, name)
  for _, profile in ipairs(document.profiles) do
    if profile.name == name then
      return profile
    end
  end
  return nil
end

-- Validates and atomically writes a profiles document to disk, replacing
-- whatever was previously at `path`. Callers (e.g. a profile-editing UI)
-- should call this whenever the user adds, edits, or removes a profile.
--
-- Parameters:
--   path (string): destination path for the profiles JSON file.
--   document (table): the full document to save, shape { version = 1,
--     profiles = { <profile>, ... } }. This is validated exactly like a
--     document loaded from disk -- an invalid document is never written.
--
-- Returns:
--   On success: true.
--   On failure: nil, plus a string error message (failed validation, JSON
--     encode failure, couldn't create the parent directory, or any of the
--     file I/O steps below failed).
--
-- Side effects: JSON-encodes the document (vim.json.encode); creates the
-- parent directory if missing (vim.fn.mkdir with mode 448 = 0o700); then
-- performs a "write to temp file, fsync, rename over the real path, chmod"
-- sequence. Writing to a temporary sibling file first and only renaming it
-- into place at the end means a crash or power loss mid-write can never leave
-- `path` half-written/corrupted -- the rename is atomic, so readers either
-- see the old complete file or the new complete file, never a partial one.
-- The final fs_chmod call re-applies the owner-only 0600 permission, since a
-- fresh file's permissions depend on umask and aren't guaranteed to already
-- be 0600.
function M.write(path, document)
  local valid, validation_err = validate_document(document)
  if not valid then
    return nil, validation_err
  end

  local ok, contents = pcall(vim.json.encode, document)
  if not ok then
    return nil, "cannot encode profile file"
  end

  local directory = vim.fn.fnamemodify(path, ":h")
  if vim.fn.mkdir(directory, "p", 448) == 0 and not uv.fs_stat(directory) then
    return nil, "cannot create profile directory: " .. directory
  end

  -- Give the temp file a unique-ish name (suffixed with this process's PID)
  -- so two concurrent Orbit instances writing at once don't collide on the
  -- same temp file.
  local temporary = path .. ".tmp-" .. tostring(uv.os_getpid())
  -- Write and sync a sibling first so rename replaces the document atomically.
  local fd, open_err = uv.fs_open(temporary, "w", 384)
  if not fd then
    return nil, "cannot create profile file: " .. open_err
  end

  local _, write_err = uv.fs_write(fd, contents, 0)
  if write_err then
    uv.fs_close(fd)
    uv.fs_unlink(temporary)
    return nil, "cannot write profile file: " .. write_err
  end
  -- fsync forces the OS to actually flush the written bytes to durable
  -- storage before we proceed, rather than trusting they're still sitting in
  -- an in-memory page cache -- otherwise the atomic rename below wouldn't
  -- actually guarantee the new content survives a crash.
  uv.fs_fsync(fd)
  uv.fs_close(fd)

  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    uv.fs_unlink(temporary)
    return nil, "cannot replace profile file: " .. rename_err
  end
  -- Rename inherits filesystem behavior, so enforce owner-only mode on the final path too.
  local chmodded, chmod_err = uv.fs_chmod(path, 384)
  if not chmodded then
    return nil, "cannot protect profile file: " .. chmod_err
  end

  return true
end

-- Makes sure a usable, safely-permissioned profiles file exists at `path`,
-- creating an empty one if necessary. Called from lua/orbit/init.lua's
-- OrbitProfiles command before opening the file for editing, so that opening
-- the file for the very first time doesn't require the user to create it (or
-- its parent directory) by hand.
--
-- Parameters:
--   path (string): the profiles file path to check/create.
--
-- Returns:
--   On success: true.
--   On failure: nil, plus a string error message (from either the chmod
--     repair path or from M.write, if creating a fresh file failed).
--
-- Side effects: if the file already exists, re-applies owner-only (0600)
-- permissions to it (in case it somehow drifted); if it does not exist,
-- delegates to M.write to create a brand new, empty (`profiles = {}`),
-- version-1 document at that path.
function M.ensure(path)
  if uv.fs_stat(path) then
    -- Repair permissions on existing files; initialize missing files as an empty v1 document.
    local ok, err = uv.fs_chmod(path, 384)
    if not ok then
      return nil, "cannot protect profile file: " .. err
    end
    return true
  end
  return M.write(path, { version = 1, profiles = {} })
end

return M
