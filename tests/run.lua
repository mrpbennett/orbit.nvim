local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local modules = {
  "quarry",
  "quarry.adapters",
  "quarry.browser",
  "quarry.completion",
  "quarry.diagnostics",
  "quarry.feedback",
  "quarry.profiles",
  "quarry.query",
  "quarry.results",
  "quarry.runner",
  "quarry.schema",
  "quarry.schema_cache",
  "quarry.statements",
  "quarry.workspace",
}

for _, module in ipairs(modules) do
  assert(require(module), "cannot load " .. module)
end

local specs = {
  require("tests.profile_spec"),
  require("tests.browser_spec"),
  require("tests.feedback_spec"),
  require("tests.keymaps_spec"),
  require("tests.statements_spec"),
  require("tests.results_spec"),
  require("tests.status_spec"),
  require("tests.schema_spec"),
  require("tests.workspace_spec"),
  require("tests.completion_spec"),
}

local failures = {}

for _, spec in ipairs(specs) do
  for name, test in pairs(spec) do
    local ok, err = xpcall(test, debug.traceback)
    if ok then
      print("PASS " .. name)
    else
      table.insert(failures, name .. "\n" .. err)
      print("FAIL " .. name)
    end
  end
end

if #failures > 0 then
  error(table.concat(failures, "\n\n"))
end
