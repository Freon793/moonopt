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
/// `max 5x + 4y  s.t.  6x + 4y <= 13`, `x, y` integers in `[0, 2]`.
///
/// The relaxation fills `y` to its bound of 2 and gives `x` what is left — `(5/6, 2)` for
/// 12.1667 — while the integer optimum is 10 at `(2, 0)`. That gap is what makes this a
/// model where the answer has to come from the branch and bound rather than from the
/// relaxation: a relaxation reported as an answer would say 12.1667 and be wrong.
fn integer_mip() -> @model.Model {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", ub=2.0, is_int=true)
  let y = m.add_var("y", ub=2.0, is_int=true)
  m.set_objective([(x, 5.0), (y, 4.0)])
  m.add_constraint([(x, 6.0), (y, 4.0)], @model.Rel::LessEqual, 13.0)
  m
}

///|
/// `max x + y  s.t.  x + y <= 1`, both continuous: the LP the two fields are pinned on.
fn continuous_lp() -> @model.Model {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", ub=1.0)
  let y = m.add_var("y", ub=1.0)
  m.set_objective([(x, 1.0), (y, 1.0)])
  m.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 1.0)
  m
}

///|
/// A model with integer variables is answered by the branch and bound, not by its
/// relaxation: the relaxation's optimum here is 73/6 and the answer is 10.
test "an integer model is solved to the integer optimum, not to its relaxation" {
  let sol = @moonopt.solve(integer_mip())
  assert_eq(sol.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(sol.objective, 10.0, rel=1.0e-9, abs=1.0e-9))
  assert_eq(sol.values.length(), 2)
  // The point is whole, which is the one thing a relaxation answer would not be.
  assert_true(@core.approx_eq(sol.values[0], 2.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(@core.approx_eq(sol.values[1], 0.0, rel=1.0e-9, abs=1.0e-9))
  // Nothing is left open, and the two fields say so.
  assert_true(@core.approx_eq(sol.bound, 10.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(@core.approx_eq(sol.gap, 0.0, rel=0.0, abs=1.0e-12))
  assert_true(sol.nodes > 0)
  // A linear solve is its own bound, so the same two fields mean the same thing there.
  let linear = @moonopt.solve(continuous_lp())
  assert_eq(linear.status, @moonopt.SolveStatus::Optimal)
  assert_true(
    @core.approx_eq(linear.bound, linear.objective, rel=1.0e-12, abs=0.0),
  )
  assert_true(@core.approx_eq(linear.gap, 0.0, rel=0.0, abs=1.0e-12))
  assert_eq(linear.nodes, 0)
}

///|
/// A node budget is a budget, not an answer: the run stops as `NodeLimit` with whatever
/// integer point it has (here none, at one relaxation) and the bound still open.
test "a node budget is reported as a budget rather than as an optimality claim" {
  // Cuts off: this is about what one relaxation's budget leaves behind, and a round of
  // cuts at the root would spend a second relaxation to tighten the same node.
  let sol = @moonopt.solve_with(integer_mip(), {
    max_iterations: 10000,
    presolve: true,
    max_nodes: 1,
    cut_rounds: 0,
  })
  assert_eq(sol.status, @moonopt.SolveStatus::NodeLimit)
  assert_eq(sol.values.length(), 0)
  assert_true(@core.approx_eq(sol.bound, 73.0 / 6.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(sol.gap > 1.0e299)
  assert_true(sol.message.length() > 0)
  assert_eq(sol.nodes, 1)
}

///|
/// A model whose relaxation is feasible and whose integer points are not: the tree
/// exhausts itself, so `Infeasible` is a proof here in a way it never is for a single
/// relaxation.
test "an integer model with no integer point is proved infeasible" {
  let m = @model.Model::new(@model.Sense::Minimize)
  let x = m.add_var("x", ub=4.0, is_int=true)
  let y = m.add_var("y", ub=4.0, is_int=true)
  m.set_objective([(x, 1.0), (y, 1.0)])
  m.add_constraint([(x, 2.0), (y, 2.0)], @model.Rel::Equal, 1.0)
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::Infeasible)
  assert_eq(sol.values.length(), 0)
  assert_true(sol.nodes > 0)
}

///|
/// An unbounded *relaxation* is not an unbounded model. The improving ray of the
/// relaxation carries no integrality of its own, so this comes back as `NotSolved` with
/// the search's own words — never as `Unbounded`, which would be a claim about a model
/// nothing has proven anything about.
test "an unbounded relaxation is not reported as an unbounded integer model" {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", is_int=true)
  let y = m.add_var("y")
  m.set_objective([(x, 1.0), (y, 1.0)])
  m.add_constraint([(x, 1.0), (y, -1.0)], @model.Rel::LessEqual, 3.0)
  let sol = @moonopt.solve(m)
  assert_eq(sol.status, @moonopt.SolveStatus::NotSolved)
  assert_eq(sol.values.length(), 0)
  assert_true(sol.message.length() > 0)
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
  let sol = @moonopt.solve_with(m, {
    max_iterations: 0,
    presolve: false,
    max_nodes: 20000,
    cut_rounds: 2,
  })
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
    max_nodes: 20000,
    cut_rounds: 2,
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
