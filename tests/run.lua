local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local modules = {
  "orbit",
  "orbit.adapters",
	"orbit.completion",
	"orbit.connectors.postgres",
	"orbit.connectors.utils.mutation_sql",
   "orbit.diagnostics",
   "orbit.editable_result",
  "orbit.feedback",
  "orbit.profiles",
  "orbit.query",
  "orbit.results",
  "orbit.runner",
  "orbit.session",
  "orbit.sql.tokenizer",
  "orbit.sql.scope",
  "orbit.blink",
  "orbit.schema",
  "orbit.schema_cache",
  "orbit.schema_tree",
  "orbit.statements",
  "orbit.workspace",
}

for _, module in ipairs(modules) do
  assert(require(module), "cannot load " .. module)
end

local specs = {
  require("tests.config_spec"),
  require("tests.profile_spec"),
  require("tests.feedback_spec"),
  require("tests.keymaps_spec"),
  require("tests.statements_spec"),
  require("tests.results_spec"),
  require("tests.status_spec"),
  require("tests.schema_spec"),
  require("tests.schema_tree_spec"),
  require("tests.session_spec"),
  require("tests.mutation_sql_spec"),
  require("tests.workspace_spec"),
   require("tests.completion_spec"),
   require("tests.editable_result_spec"),
   require("tests.sql_tokenizer_spec"),
   require("tests.sql_scope_spec"),
   require("tests.blink_spec"),
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
