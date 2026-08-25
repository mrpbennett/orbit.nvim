local runner = require("orbit.runner")
local session = require("orbit.session")

return {
  ["runner reuses one SQLite connection for queued requests"] = function()
    local profile = {
      name = "session-reuse",
      kind = "sqlite",
      options = { path = ":memory:" },
    }
    local created, rows, create_err, select_err

    runner.run(profile, "CREATE TEMP TABLE orbit_session_test (value INTEGER); INSERT INTO orbit_session_test VALUES (7)", function(_, err)
      created, create_err = true, err
    end)
    runner.run(profile, "SELECT value FROM orbit_session_test", function(result, err)
      rows, select_err = result, err
    end)

    assert(vim.wait(1000, function()
      return created and (rows or select_err)
    end), "timed out waiting for retained SQLite session")
    assert(create_err == nil, create_err)
    assert(select_err == nil, select_err)
    assert(rows[1].value == 7)
    assert(session.connected(profile.name))
    session.close(profile.name)
  end,

  ["closing a session fails active requests and allows reconnecting"] = function()
    local profile = {
      name = "session-close",
      kind = "sqlite",
      options = { path = ":memory:" },
    }
    local closed_err, rows, select_err

    local request = runner.run(profile, "SELECT 1", function(_, err)
      closed_err = err
    end)
    session.close(profile.name)
    assert(vim.wait(1000, function()
      return closed_err ~= nil
    end), "timed out waiting for closed request")
    assert(closed_err == "connection closed")

    runner.run(profile, "SELECT 2 AS value", function(result, err)
      rows, select_err = result, err
    end)
    assert(vim.wait(1000, function()
      return rows or select_err
    end), "timed out waiting for reconnected SQLite session")
    assert(select_err == nil, select_err)
    assert(rows[1].value == 2)
    assert(request.done)
    session.close(profile.name)
  end,
}
