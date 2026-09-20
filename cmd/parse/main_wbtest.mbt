///|
/// The CLI's machine-readable half, tested where it can be tested: the verb table, the JSON
/// writer, and the document it wraps.
///
/// Running the CLI itself from a test would need a process, so what is pinned here is every
/// part of the JSON path that is a pure function of its inputs. The parts that solve are the
/// library's, and they are tested where they live.

///|
/// A tiny model with one integer variable, so the outcome's facts have something to count.
fn json_test_model() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=3.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=4.0)
  model.set_objective([(x, 1.0), (y, 2.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 5.0)
  model
}

///|
/// The verb table: the five names are commands, everything else is an argument, which is how
/// the flag-only form keeps working.
test "the verb table takes the five subcommands and nothing else" {
  for name in ["parse", "solve", "verify", "fmt", "bench"] {
    assert_eq(command_of(name), name)
  }
  assert_eq(command_of("mip"), "")
  assert_eq(command_of("--json"), "")
  assert_eq(command_of("bench/data/instances/flugpl"), "")
  assert_eq(command_of(""), "")
}

///|
/// JSON strings: quotes and backslashes are escaped, so a path is a string and not a syntax
/// error, and a document stays parseable whatever it carries.
test "json strings escape what would break the document" {
  assert_eq(json_text("flugpl"), "\"flugpl\"")
  assert_eq(json_text("a\"b"), "\"a\\\"b\"")
  assert_eq(json_text("a\\b"), "\"a\\\\b\"")
  assert_eq(json_text("a\nb"), "\"a\\nb\"")
  assert_eq(json_text(""), "\"\"")
}

///|
/// The numbers are the shortest representation that reads back to the same value: the CLI
/// does not round, because a consumer's copy of a report would then disagree with the report.
test "json numbers keep every digit the run produced" {
  let value = 1201500.000000284
  assert_eq(json_number(value), value.to_string())
  // The digits are the run's, not a shorter form: a rounded number would be a differently
  // shaped claim about what the solver produced.
  assert_true(json_number(value).length() > 10)
  assert_eq(json_number(-43.000000000044004), "-43.000000000044004")
}

///|
/// The parsing facts come from the model, not from a counter kept alongside it.
test "an outcome counts what the model is" {
  let outcome = new_outcome("toy.mps", json_test_model())
  assert_eq(outcome.vars, 2)
  assert_eq(outcome.cons, 1)
  // The objective's two terms plus the row's two: `report` counts the same two places, and
  // the number means "entries the model writes down", not "matrix entries".
  assert_eq(outcome.nonzeros, 4)
  assert_eq(outcome.integers, 1)
  assert_eq(outcome.sense, "MAX")
  assert_eq(outcome.mode, "parse")
  assert_true(outcome.parse_ok)
  assert_false(outcome.failed)
}

///|
/// A parse outcome carries the facts and no status: a document that said `status: optimal`
/// about a file nobody solved would be a lie a consumer could act on.
test "a parse outcome has facts and no status" {
  let outcome = new_outcome("toy.mps", json_test_model())
  let json = outcome.to_json()
  assert_true(json.contains("\"mode\": \"parse\""))
  assert_true(json.contains("\"vars\": 2"))
  assert_true(json.contains("\"integer_vars\": 1"))
  assert_true(json.contains("\"sense\": \"MAX\""))
  assert_true(json.contains("\"failed\": false"))
  assert_false(json.contains("\"status\""))
  assert_false(json.contains("\"objective\""))
}

///|
/// An outcome of a run reports what the run said, and only the fields that exist for it.
test "a solve outcome reports the run's own numbers" {
  let outcome = new_outcome("toy.mps", json_test_model())
  outcome.mode = "solve"
  outcome.status = "optimal"
  outcome.has_objective = true
  outcome.objective = 12.5
  outcome.iterations = 7
  let json = outcome.to_json()
  assert_true(json.contains("\"mode\": \"solve\""))
  assert_true(json.contains("\"status\": \"optimal\""))
  assert_true(json.contains("\"objective\": 12.5"))
  assert_true(json.contains("\"iterations\": 7"))
  // A field the run did not set is absent rather than zero: `nodes` is a branch and bound
  // number, and a solve that printed zero of them would be claiming something.
  assert_false(json.contains("\"nodes\""))
  assert_false(json.contains("\"cuts\""))
}

///|
/// A file that could not be read is a failure in the document, which is what the exit code
/// is computed from.
test "an unusable file is a failed document" {
  let outcome = unusable_outcome("missing.mps", "cannot read the file")
  assert_false(outcome.parse_ok)
  assert_true(outcome.failed)
  let json = outcome.to_json()
  assert_true(json.contains("\"parsed\": false"))
  assert_true(json.contains("\"error\": \"cannot read the file\""))
  assert_true(json.contains("\"failed\": true"))
}

///|
/// The document wraps the files and the summary the exit code comes from.
test "the document carries the command, the files and the summary" {
  let outcome = new_outcome("toy.mps", json_test_model())
  let json = document_json("parse", [outcome], 0)
  assert_true(json.contains("\"tool\": \"moonopt\""))
  assert_true(json.contains("\"command\": \"parse\""))
  assert_true(json.contains("\"files\": ["))
  assert_true(json.contains("\"summary\": {\"files\": 1,\"failed\": 0}"))
  let failed = document_json("parse", [outcome], 3)
  assert_true(failed.contains("\"failed\": 3"))
}
