local structure = require("orbit.sql.structure")
local tokenizer = require("orbit.sql.tokenizer")

return {
  ["tokenizer keeps semicolons inside quoted and commented constructs"] = function()
    local tokens = tokenizer.tokenize({ "SELECT ';', \"semi;colon\"; -- ignored;", "SELECT 2 /* ; */;" })
    local separators = 0
    for _, token in ipairs(tokens) do
      if token.type == "semicolon" then
        separators = separators + 1
      end
    end
    assert(separators == 2)
  end,

  ["tokenizer keeps PostgreSQL dollar-quoted bodies together"] = function()
    local entries = structure.extract({
      "CREATE FUNCTION f() RETURNS void AS $body$",
      "BEGIN",
      "  INSERT INTO log VALUES ('x');",
      "END;",
      "$body$ LANGUAGE plpgsql;",
      "SELECT $1;",
    })
    assert(#entries == 2)
    assert(entries[1].category == "DDL")
    assert(entries[2].category == "SELECT")
    assert(entries[2].start_row == 6)
  end,

  ["a completed function does not consume a later transaction"] = function()
    local entries = structure.extract({
      "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;",
      "BEGIN;",
      "UPDATE users SET active = 1;",
      "COMMIT;",
    })
    assert(#entries == 4)
    assert(entries[1].category == "DDL")
    assert(entries[2].category == "Other")
    assert(entries[3].category == "DML")
  end,

  ["structure extracts groups labels and source ranges"] = function()
    local entries = structure.extract({
      "-- heading",
      "SELECT  *", "FROM users;",
      "UPDATE users SET active = 1;",
      "VACUUM;",
    })
    assert(#entries == 3)
    assert(entries[1].category == "SELECT")
    assert(entries[1].label == "SELECT * FROM users;")
    assert(entries[1].start_row == 2 and entries[1].end_row == 3)
    assert(entries[2].category == "DML")
    assert(entries[3].category == "Other")
    assert(structure.at(entries, 3, 2) == entries[1])
    assert(structure.at(entries, 4, 0) == entries[2])
  end,

  ["structure classifies WITH statements by their outer operation"] = function()
    local entries = structure.extract({
      "WITH updated AS (SELECT 1) UPDATE users SET active = 1;",
      "WITH rows AS (SELECT 1) SELECT * FROM rows;",
      "WITH rows(id) AS (SELECT 1) SELECT * FROM rows;",
    })
    assert(entries[1].category == "DML")
    assert(entries[2].category == "SELECT")
    assert(entries[3].category == "SELECT")
  end,

  ["structure extracts WITH clauses into navigable query trees"] = function()
    local entries = structure.extract({
      "WITH crm AS (",
      "  SELECT id FROM source_one",
      "  UNION DISTINCT",
      "  SELECT id FROM source_two",
      "  WHERE day = (SELECT max(day) FROM source_two)",
      "), guids AS (",
      "  SELECT id FROM crm",
      ")",
      "SELECT count(*) FROM guids;",
    })
    local statement = entries[1]
    assert(statement.kind == "statement")
    assert(#statement.children == 2)
    assert(statement.children[1].kind == "with" and statement.children[1].label == "WITH")
    assert(#statement.children[1].children == 2)
    assert(statement.children[1].children[1].label == "crm")
    assert(statement.children[1].children[1].children[1].kind == "query")
    assert(#statement.children[1].children[1].children == 2)
    assert(statement.children[1].children[1].children[1].label == "SELECT id FROM source_one")
    assert(
      statement.children[1].children[1].children[2].label
        == "SELECT id FROM source_two WHERE day = (SELECT max(day) FROM source_two)"
    )
    assert(statement.children[1].children[1].children[1].start_row == 2)
    assert(statement.children[1].children[1].children[2].start_row == 4)
    assert(statement.children[1].children[1].children[1].id == "statement:1:0:cte:1:5:query:2:2")
    assert(statement.children[1].children[1].children[2].id == "statement:1:0:cte:1:5:query:4:2")
    assert(statement.children[1].children[2].label == "guids")
    assert(statement.children[2].kind == "query")
    assert(statement.children[2].label == "SELECT count(*) FROM guids")
    assert(structure.at(entries, 7, 4).label:match("SELECT id FROM crm"))
    assert(structure.at(entries, 9, 0) == statement.children[2])
  end,

  ["incomplete CTE syntax falls back to a statement root"] = function()
    local malformed = {
      "WITH crm AS (SELECT id FROM users",
      "WITH crm AS () SELECT * FROM crm",
      "WITH crm AS (SELECT 1),",
      "WITH crm AS NOT (SELECT 1) SELECT * FROM crm",
      "WITH crm AS (SELECT 1 UNION DISTINCT) SELECT * FROM crm",
      "WITH crm AS (UNION SELECT 1) SELECT * FROM crm",
      "WITH crm AS (SELECT 1)",
    }
    for _, sql in ipairs(malformed) do
      local entries = structure.extract({ sql })
      assert(#entries == 1)
      assert(entries[1].kind == "statement")
      assert(#entries[1].children == 0)
    end
  end,

  ["structure splits every top-level set operation"] = function()
    for _, operator in ipairs({ "UNION ALL", "INTERSECT", "EXCEPT" }) do
      local entries = structure.extract({ "WITH values AS (SELECT 1 " .. operator .. " SELECT 2) SELECT * FROM values" })
      assert(#entries[1].children[1].children[1].children == 2, operator)
    end
  end,

  ["structure keeps a SQLite trigger body as one coarse entry"] = function()
    local entries = structure.extract({
      "CREATE TRIGGER audit AFTER UPDATE ON users BEGIN",
      "  INSERT INTO log VALUES (NEW.id);",
      "  UPDATE counters SET total = total + 1;",
      "END;",
      "SELECT 1;",
    })
    assert(#entries == 2)
    assert(entries[1].category == "Other")
    assert(entries[1].end_row == 4)
    assert(entries[2].category == "SELECT")
  end,

  ["structure keeps temporary and generic procedural bodies coarse"] = function()
    local entries = structure.extract({
      "CREATE TEMP TRIGGER IF NOT EXISTS audit AFTER UPDATE ON users BEGIN",
      "  UPDATE log SET seen = 1;",
      "END;",
      "CREATE PROCEDURE p() DECLARE value INTEGER; BEGIN",
      "  UPDATE users SET active = 1;",
      "END;",
    })
    assert(#entries == 2)
    assert(entries[1].category == "Other" and entries[1].end_row == 3)
    assert(entries[2].category == "Other" and entries[2].end_row == 6)
  end,

  ["structure keeps an atomic compound body coarse"] = function()
    local entries = structure.extract({
      "BEGIN ATOMIC",
      "  UPDATE users SET active = 1;",
      "END;",
      "SELECT 1;",
    })
    assert(#entries == 2)
    assert(entries[1].category == "Other" and entries[1].end_row == 3)
    assert(entries[2].category == "SELECT")
  end,

  ["structure removes comments from labels and respects adjacent boundaries"] = function()
    local entries = structure.extract({ "SELECT /* note */ 1;SELECT 2;" })
    assert(entries[1].label == "SELECT 1;")
    assert(structure.at(entries, 1, entries[2].start_col) == entries[2])
  end,

  ["dollar quote openers require a lexical boundary"] = function()
    local entries = structure.extract({ "SELECT foo$tag$; SELECT 2;" })
    assert(#entries == 2)
  end,

  ["structure ignores empty and comment-only fragments"] = function()
    local entries = structure.extract({ "; -- comment", ";", "  " })
    assert(#entries == 0)
  end,
}
