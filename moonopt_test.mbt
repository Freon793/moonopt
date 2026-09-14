///|
/// Blackbox tests: they exercise the public surface exactly as a user would, via
/// `@moonopt` and `@model`.
test "production plan is solved to the known optimum" {
  // max 5x + 4y  s.t.  6x + 4y <= 24,  x + 2y <= 6,  x, y >= 0  ->  21 at (3, 1.5)
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x")
  let y = m.add_var("y")
  m.set_objective([(x, 5.0), (y, 4.0)])
  m.add_named_constraint(
    [(x, 6.0), (y, 4.0)],
    @model.Rel::LessEqual,
    24.0,
    "machine",
  )
  m.add_named_constraint(
    [(x, 1.0), (y, 2.0)],
    @model.Rel::LessEqual,
    6.0,
    "labour",
  )
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(sol.objective, 21.0))
  assert_eq(sol.values.length(), 2)
  assert_true(@core.approx_eq(sol.values[0], 3.0))
  assert_true(@core.approx_eq(sol.values[1], 1.5))
  assert_eq(sol.message, "")
}

///|
test "minimisation is handled by sign convention" {
  // min 2x + 3y  s.t.  x + y >= 4,  x, y >= 0  ->  8 at (4, 0)
  let m = @model.Model::new(@model.Sense::Minimize)
  let x = m.add_var("x")
  let y = m.add_var("y")
  m.set_objective([(x, 2.0), (y, 3.0)])
  m.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::GreaterEqual, 4.0)
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(sol.objective, 8.0))
  assert_true(@core.approx_eq(sol.values[0], 4.0))
  assert_true(@core.approx_eq(sol.values[1], 0.0))
}

///|
test "finite upper bounds become explicit rows" {
  // max x + y  s.t.  x + y <= 10,  x <= 2,  y <= 3  ->  5
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", ub=2.0)
  let y = m.add_var("y", ub=3.0)
  m.set_objective([(x, 1.0), (y, 1.0)])
  m.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 10.0)
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(sol.objective, 5.0))
}

///|
test "infeasible model reports Infeasible, not a wrong answer" {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", ub=1.0)
  m.set_objective([(x, 1.0)])
  m.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 2.0)
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::Infeasible)
  assert_eq(sol.values.length(), 0)
  assert_eq(sol.message, "no feasible point exists")
}

///|
test "unsupported constructs are reported with a reason" {
  // Non-zero lower bound: outside the current kernel's model class.
  let m = @model.Model::new(@model.Sense::Maximize)
  let _ = m.add_var("x", lb=1.0)
  m.set_objective([(0, 1.0)])
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::NotSolved)
  assert_eq(sol.values.length(), 0)
  assert_true(sol.message.length() > 0)
}

///|
test "integer variables are rejected until the MIP stage lands" {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", ub=1.0, is_int=true)
  m.set_objective([(x, 1.0)])
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::NotSolved)
}

///|
test "an ill-formed model is rejected before any solving happens" {
  let m = @model.Model::new(@model.Sense::Minimize)
  let _ = m.add_var("x", lb=5.0, ub=1.0)
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::NotSolved)
  assert_true(sol.message.length() > 0)
}

///|
test "iteration limit is surfaced instead of being ignored" {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x")
  m.set_objective([(x, 1.0)])
  m.add_constraint([(x, 1.0)], @model.Rel::LessEqual, 1.0)
  let sol = @moonopt.solve_with(m, { max_iterations: 0, })
  assert_eq(sol.status, @moonopt.SolveStatus::NotSolved)
  assert_true(sol.message.length() > 0)
}
