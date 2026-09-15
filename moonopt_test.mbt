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
  // The wording depends on which layer proved it: the reduction says it proved
  // infeasibility at a named row, the kernel says no feasible point exists. Both
  // have to say something, and both have to be about feasibility.
  assert_true(sol.message.contains("feasible"))
}

///|
test "non-zero lower bounds are supported by the kernel" {
  // min x  s.t.  x >= 0,  x >= 1 (from the bound)  ->  1
  let m = @model.Model::new(@model.Sense::Minimize)
  let x = m.add_var("x", lb=1.0)
  m.set_objective([(x, 1.0)])
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(sol.objective, 1.0))
  assert_true(@core.approx_eq(sol.values[0], 1.0))
}

///|
test "free variables are supported by the kernel" {
  // max x  s.t.  x <= -2,  x free  ->  -2
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", lb=-@model.infinite_bound, ub=@model.infinite_bound)
  m.set_objective([(x, 1.0)])
  m.add_constraint([(x, 1.0)], @model.Rel::LessEqual, -2.0)
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(sol.objective, -2.0))
  assert_true(@core.approx_eq(sol.values[0], -2.0))
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
  // Presolve is on by default and would settle this model by itself (the row is a
  // bound, and the variable then appears in no row), which is a different thing
  // from what this test is about: the kernel's own iteration limit.
  let sol = @moonopt.solve_with(m, { max_iterations: 0, presolve: false, })
  assert_eq(sol.status, @moonopt.SolveStatus::NotSolved)
  assert_true(sol.message.length() > 0)
}

///|
/// Presolve is the default path, and it is allowed to finish a model on its own:
/// `max x` with `x <= 1` is decided by the reduction, so the answer comes back with
/// no kernel run at all — and with the reconstructed values indexed by the
/// original variables.
test "presolve solves a model on its own and reconstructs the value" {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x")
  m.set_objective([(x, 1.0)])
  m.add_constraint([(x, 1.0)], @model.Rel::LessEqual, 1.0)
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::Optimal)
  assert_eq(sol.iterations, 0)
  assert_true(@core.approx_eq(sol.objective, 1.0, rel=1.0e-9, abs=1.0e-9))
  assert_eq(sol.values.length(), 1)
  assert_true(@core.approx_eq(sol.values[0], 1.0, rel=1.0e-9, abs=1.0e-9))
}

///|
/// The two paths have to agree. With a fixed variable the reduced model no longer
/// contains it, so the objective has to pick up its contribution from the offset
/// and the value vector has to put it back in the right place.
test "the presolved path and the kernel-only path agree" {
  // min x + y  s.t.  x + y >= 5,  x = 2,  y >= 0   ->   x = 2, y = 3, objective 5
  let with_presolve = @model.Model::new(@model.Sense::Minimize)
  let x1 = with_presolve.add_var("x", lb=2.0, ub=2.0)
  let y1 = with_presolve.add_var("y", lb=0.0)
  with_presolve.set_objective([(x1, 1.0), (y1, 1.0)])
  with_presolve.add_constraint(
    [(x1, 1.0), (y1, 1.0)],
    @model.Rel::GreaterEqual,
    5.0,
  )
  let presolved = @moonopt.solve(with_presolve)
  assert_eq(presolved.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(presolved.objective, 5.0, rel=1.0e-9, abs=1.0e-9))
  assert_eq(presolved.values.length(), 2)
  assert_true(@core.approx_eq(presolved.values[0], 2.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(@core.approx_eq(presolved.values[1], 3.0, rel=1.0e-9, abs=1.0e-9))

  let direct = @model.Model::new(@model.Sense::Minimize)
  let x2 = direct.add_var("x", lb=2.0, ub=2.0)
  let y2 = direct.add_var("y", lb=0.0)
  direct.set_objective([(x2, 1.0), (y2, 1.0)])
  direct.add_constraint([(x2, 1.0), (y2, 1.0)], @model.Rel::GreaterEqual, 5.0)
  let kernel_only = @moonopt.solve_with(direct, {
    max_iterations: 10000,
    presolve: false,
  })
  assert_eq(kernel_only.status, @moonopt.SolveStatus::Optimal)
  assert_true(
    @core.approx_eq(kernel_only.objective, 5.0, rel=1.0e-9, abs=1.0e-9),
  )
}

///|
/// A verdict presolve can prove on its own is reported as such, without a kernel
/// run: this variable appears in no row, its cost improves with the value growing,
/// and nothing bounds it above.
test "a model presolve proves unbounded is reported without a kernel run" {
  let m = @model.Model::new(@model.Sense::Minimize)
  let x = m.add_var("x", lb=0.0)
  let y = m.add_var("y", lb=0.0)
  m.set_objective([(x, -1.0), (y, 1.0)])
  m.add_constraint([(y, 1.0)], @model.Rel::GreaterEqual, 4.0)
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::Unbounded)
  assert_true(sol.message.length() > 0)
}
