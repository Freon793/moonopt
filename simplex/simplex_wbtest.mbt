///|
/// Kernel behaviour: known optima, Phase I, degeneracy, the bound
/// transformations, and the failure statuses.
test "kernel solves a bounded problem with two rows" {
  // min 3x + 2y  s.t.  x + y >= 4,  x + 3y >= 6,  x, y >= 0
  // The cheapest vertex is (0, 4): 3·0 + 2·4 = 8.
  let result = solve_standard(2, [3.0, 2.0], [
    ([1.0, 1.0], @model.Rel::GreaterEqual, 4.0),
    ([1.0, 3.0], @model.Rel::GreaterEqual, 6.0),
  ])
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, 8.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(result.values[0] >= -1.0e-9)
  assert_true(result.values[1] >= -1.0e-9)
}

///|
test "kernel handles equality rows through Phase I" {
  // min x + y  s.t.  x + y = 1,  x, y >= 0  ->  1
  let result = solve_standard(2, [1.0, 1.0], [
    ([1.0, 1.0], @model.Rel::Equal, 1.0),
  ])
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, 1.0))
}

///|
test "kernel detects infeasibility" {
  // x <= 1 and x >= 2
  let result = solve_standard(1, [1.0], [
    ([1.0], @model.Rel::LessEqual, 1.0),
    ([1.0], @model.Rel::GreaterEqual, 2.0),
  ])
  assert_eq(result.status, Infeasible)
  assert_eq(result.values.length(), 0)
  assert_true(result.message.length() > 0)
}

///|
test "kernel detects unboundedness" {
  // min -x  s.t.  x >= 1
  let result = solve_standard(1, [-1.0], [
    ([1.0], @model.Rel::GreaterEqual, 1.0),
  ])
  assert_eq(result.status, Unbounded)
  assert_eq(result.values.length(), 0)
}

///|
test "kernel terminates on a degenerate problem" {
  // min -x - y  s.t.  x + y <= 1,  x <= 1,  y <= 1  ->  -1
  let result = solve_standard(2, [-1.0, -1.0], [
    ([1.0, 1.0], @model.Rel::LessEqual, 1.0),
    ([1.0, 0.0], @model.Rel::LessEqual, 1.0),
    ([0.0, 1.0], @model.Rel::LessEqual, 1.0),
  ])
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, -1.0))
}

///|
test "kernel normalises rows with negative right hand sides" {
  // min x  s.t.  -x <= -2  (x >= 2) and  x <= 5  ->  2
  let result = solve_standard(1, [1.0], [
    ([-1.0], @model.Rel::LessEqual, -2.0),
    ([1.0], @model.Rel::LessEqual, 5.0),
  ])
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, 2.0))
}

///|
test "kernel reports the iteration limit instead of guessing" {
  let result = solve_standard_with(
    2,
    [3.0, 2.0],
    [
      ([1.0, 1.0], @model.Rel::LessEqual, 4.0),
      ([1.0, 3.0], @model.Rel::LessEqual, 6.0),
    ],
    SimplexOptions::with_max_iterations(0),
  )
  assert_eq(result.status, IterationLimit)
  assert_eq(result.values.length(), 0)
}

///|
test "model path: maximisation, upper bounds and the objective sense" {
  // max 5x + 4y  s.t.  6x + 4y <= 24,  x + 2y <= 6,  x <= 2.5  ->  21 at (3, 1.5)
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=10.0)
  let y = model.add_var("y", lb=0.0, ub=10.0)
  model.set_objective([(x, 5.0), (y, 4.0)])
  model.add_named_constraint(
    [(x, 6.0), (y, 4.0)],
    @model.Rel::LessEqual,
    24.0,
    "machine",
  )
  model.add_named_constraint(
    [(x, 1.0), (y, 2.0)],
    @model.Rel::LessEqual,
    6.0,
    "labour",
  )
  let result = match solve_model(model) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, 21.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(@core.approx_eq(result.values[0], 3.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(@core.approx_eq(result.values[1], 1.5, rel=1.0e-9, abs=1.0e-9))
}

///|
test "model path: non-zero lower bounds are shifted exactly" {
  // min x + y  s.t.  x >= 5,  y >= 2,  x + y >= 10  ->  10 at (5, 5)
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=5.0)
  let y = model.add_var("y", lb=2.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::GreaterEqual, 10.0)
  let result = match solve_model(model) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, 10.0))
  assert_true(@core.approx_eq(result.values[0] + result.values[1], 10.0))
  assert_true(result.values[0] >= 5.0 - 1.0e-9)
  assert_true(result.values[1] >= 2.0 - 1.0e-9)
}

///|
test "model path: free variables are split, not approximated" {
  // min x  s.t.  x >= -3,  x free otherwise  ->  -3
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var(
    "x",
    lb=-@model.infinite_bound,
    ub=@model.infinite_bound,
  )
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, -3.0)
  let result = match solve_model(model) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, -3.0, rel=1.0e-9, abs=1.0e-9))
}

///|
test "model path: bound rows are enforced" {
  // max x + y  s.t.  x <= 2,  y <= 3  ->  5
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=2.0)
  let y = model.add_var("y", lb=0.0, ub=3.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  let result = match solve_model(model) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, 5.0))
}

///|
test "model path: integer variables are refused with a reason" {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=1.0, is_int=true)
  model.set_objective([(x, 1.0)])
  let refused = match solve_model(model) {
    Ok(_) => false
    Err(reason) => reason.contains("integer")
  }
  assert_true(refused)
}

///|
test "model path: infeasible bound combination is reported" {
  // x in [0, 1] but x >= 4
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=1.0)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 4.0)
  let result = match solve_model(model) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, Infeasible)
}

///|
/// The row ceiling is what keeps a run from being started that this kernel has no
/// business attempting. It has to refuse before any of the problem's storage is
/// laid out, and it has to say why: an access violation on the native backend is
/// not a boundary a caller can act on.
test "kernel refuses a problem over the row limit instead of allocating" {
  let result = solve_standard_with(
    2,
    [1.0, 1.0],
    [([1.0, 1.0], @model.Rel::LessEqual, 4.0)],
    SimplexOptions::with_max_kernel_rows(0),
  )
  assert_eq(result.status, TooLarge)
  assert_eq(result.iterations, 0)
  assert_true(result.message.contains("row limit"))
  assert_true(result.values.length() == 0)
}

///|
/// Every finite upper bound becomes an explicit kernel row, so a model whose
/// constraint count is small can still exceed the limit. Twenty bounded variables
/// and one constraint is twenty-one kernel rows, which is the same mechanism that
/// took a 635 row instance to 63 644 rows.
test "model path: bound rows count against the kernel row limit" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let vars : Array[Int] = []
  for j = 0; j < 20; j = j + 1 {
    vars.push(model.add_var("x" + j.to_string(), lb=0.0, ub=1.0))
  }
  model.set_objective([(vars[0], 1.0)])
  model.add_constraint([(vars[0], 1.0)], @model.Rel::GreaterEqual, 0.5)
  let result = match
    solve_model_with(model, SimplexOptions::with_max_kernel_rows(5)) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, TooLarge)
  assert_true(result.message.contains("21 rows"))
}

///|
/// The same model solved with the default limit is untouched by the gate: the
/// ceiling only exists to stop runs that cannot be honoured.
test "model path: the default row limit does not interfere with small models" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let vars : Array[Int] = []
  for j = 0; j < 20; j = j + 1 {
    vars.push(model.add_var("x" + j.to_string(), lb=0.0, ub=1.0))
  }
  model.set_objective([(vars[0], 1.0)])
  model.add_constraint([(vars[0], 1.0)], @model.Rel::GreaterEqual, 0.5)
  let result = match solve_model(model) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, 0.5, rel=1.0e-9, abs=1.0e-9))
}
