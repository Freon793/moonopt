///|
/// End to end: a model read from MPS text is a normal model, so the solver can
/// consume it without any special casing.
test "a model parsed from MPS solves to the known optimum" {
  let text = "NAME          PRODPLAN\n" +
    "OBJSENSE\n" +
    " MAX\n" +
    "ROWS\n" +
    " N  COST\n" +
    " L  MACHINE\n" +
    " L  LABOUR\n" +
    "COLUMNS\n" +
    "    X  COST  5  MACHINE  6\n" +
    "    X  LABOUR  1\n" +
    "    Y  COST  4  MACHINE  4\n" +
    "    Y  LABOUR  2\n" +
    "RHS\n" +
    "    RHS  MACHINE  24  LABOUR  6\n" +
    "ENDATA\n"
  let model = match @format.parse_mps(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  let solution = @moonopt.solve(model)
  assert_eq(solution.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(solution.objective, 21.0))
  assert_eq(solution.values.length(), 2)
  assert_true(@core.approx_eq(solution.values[0], 3.0))
  assert_true(@core.approx_eq(solution.values[1], 1.5))
}

///|
/// The writer output must be readable by the reader, which is the property the
/// benchmark harness depends on when it normalises an instance before parsing.
test "written MPS text reads back" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x")
  let y = model.add_var("y", ub=10.0)
  model.set_objective([(x, 2.0), (y, 3.0)])
  model.add_named_constraint(
    [(x, 1.0), (y, 1.0)],
    @model.Rel::GreaterEqual,
    4.0,
    "demand",
  )
  let text = @format.write_mps(model)
  let parsed = match @format.parse_mps(text) {
    Ok(back) => back
    Err(issue) => fail("round trip failed: " + issue.to_text())
  }
  let solution = @moonopt.solve(parsed)
  assert_eq(solution.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(solution.objective, 8.0))
}
