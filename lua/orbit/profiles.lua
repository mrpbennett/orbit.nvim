local uv = vim.uv
local bit = bit
local adapters = require("orbit.adapters")

local M = {}

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

local function require_string(value, field, profile_name)
  if type(value) ~= "string" or value == "" then
    return nil, string.format("profile %q requires %s", profile_name, field)
  end
  return true
end

local function validate_profile(profile)
  if type(profile) ~= "table" then
    return nil, "each profile must be an object"
  end

  local valid, err = require_string(profile.name, "name", "<unnamed>")
  if not valid then
    return nil, err
  end
	if profile.kind ~= "trino" and profile.kind ~= "sqlite" and profile.kind ~= "postgres" then
    return nil, string.format("profile %q has unsupported kind %q", profile.name, tostring(profile.kind))
  end
  if type(profile.options) ~= "table" then
    return nil, string.format("profile %q requires options", profile.name)
  end

	local required = profile.kind == "trino" and { "server", "user", "catalog" }
		or profile.kind == "postgres" and { "database" }
		or { "path" }
  for _, field in ipairs(required) do
    valid, err = require_string(profile.options[field], "options." .. field, profile.name)
    if not valid then
      return nil, err
    end
  end

  return true
end

local function validate_document(document)
  if type(document) ~= "table" then
    return nil, "profile file contains invalid JSON"
  end
  if document.version ~= 1 then
    return nil, string.format("unsupported profile file version: %s", tostring(document.version))
  end
  if type(document.profiles) ~= "table" or not vim.islist(document.profiles) then
    return nil, "profile file requires a profiles array"
  end

  local names = {}
  for _, profile in ipairs(document.profiles) do
    local valid, validation_err = validate_profile(profile)
    if not valid then
      return nil, validation_err
    end
    if names[profile.name] then
      return nil, string.format("duplicate profile name: %q", profile.name)
    end
    local options_valid, options_err = adapters.validate_options(profile)
    if not options_valid then
      return nil, options_err
    end
    names[profile.name] = true
  end

  return true
end

function M.default_path()
  return vim.fn.expand("~/.local/share/orbit.nvim/profiles.json")
end

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

function M.find(document, name)
  for _, profile in ipairs(document.profiles) do
    if profile.name == name then
      return profile
    end
  end
  return nil
end

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

  local temporary = path .. ".tmp-" .. tostring(uv.os_getpid())
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
  uv.fs_fsync(fd)
  uv.fs_close(fd)

  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    uv.fs_unlink(temporary)
    return nil, "cannot replace profile file: " .. rename_err
  end
  local chmodded, chmod_err = uv.fs_chmod(path, 384)
  if not chmodded then
    return nil, "cannot protect profile file: " .. chmod_err
  end

  return true
end

function M.ensure(path)
  if uv.fs_stat(path) then
    local ok, err = uv.fs_chmod(path, 384)
    if not ok then
      return nil, "cannot protect profile file: " .. err
    end
    return true
  end
  return M.write(path, { version = 1, profiles = {} })
end

return M
