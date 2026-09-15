///|
/// Presolve behaviour: each reduction on a model small enough to check by hand,
/// and the reconstruction that has to undo it.
///
/// The reductions are exact, so the assertions are exact: no tolerance games,
/// only the same `@core` comparisons the rest of the project uses.

///|
/// A row with no terms decides the model on its own: satisfied is redundant,
/// violated is a proof of infeasibility.
test "presolve drops a satisfied empty row and rejects an impossible one" {
  let satisfied = @model.Model::new(@model.Sense::Minimize)
  let x = satisfied.add_var("x", lb=0.0, ub=10.0)
  satisfied.set_objective([(x, 1.0)])
  satisfied.add_named_constraint([], @model.Rel::LessEqual, 5.0, "empty")
  let reduced = presolve(satisfied)
  assert_eq(reduced.verdict(), Reduced)
  assert_eq(reduced.stats().rows_removed_empty, 1)
  assert_eq(reduced.reduced().num_constraints(), 0)

  let impossible = @model.Model::new(@model.Sense::Minimize)
  let y = impossible.add_var("y", lb=0.0, ub=10.0)
  impossible.set_objective([(y, 1.0)])
  impossible.add_named_constraint([], @model.Rel::LessEqual, -1.0, "impossible")
  let clash = presolve(impossible)
  assert_eq(clash.verdict(), Infeasible)
  assert_true(clash.reason().contains("infeasible"))
}

///|
/// `2x >= 6` is a bound, not a row: the reduction consumes it, and once `x` is
/// decided by its own bound the objective comes entirely from the offset.
test "presolve consumes a singleton row as a bound" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  model.set_objective([(x, 1.0)])
  model.add_named_constraint([(x, 2.0)], @model.Rel::GreaterEqual, 6.0, "min_x")
  let reduced = presolve(model)
  assert_eq(reduced.verdict(), Reduced)
  assert_eq(reduced.stats().rows_removed_singleton, 1)
  assert_eq(reduced.reduced().num_constraints(), 0)
  // x >= 3 from the row, then eliminated at 3 because no row mentions it.
  assert_eq(reduced.stats().variables_fixed, 1)
  let values = reduced.reconstruct([])
  assert_true(@core.approx_eq(values[0], 3.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(
    @core.approx_eq(reduced.objective(0.0), 3.0, rel=1.0e-9, abs=1.0e-9),
  )
}

///|
/// A row the bounds already satisfy is dropped without touching the bounds.
test "presolve drops a row the bounds already imply" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=1.0)
  model.set_objective([(x, 1.0)])
  model.add_named_constraint([(x, 1.0)], @model.Rel::LessEqual, 5.0, "loose")
  let reduced = presolve(model)
  assert_eq(reduced.stats().rows_removed_redundant, 1)
  assert_eq(reduced.stats().rows_removed_singleton, 0)
  assert_eq(reduced.reduced().num_constraints(), 0)
}

///|
/// A fixed variable leaves the model, but its objective contribution stays: the
/// offset is what keeps the reduced objective comparable with the original.
///
/// The reduction goes further than the substitution here, and that is the point:
/// once `x = 2` is substituted the row reads `y >= 3`, which is a singleton bound,
/// and after that no row mentions `y` at all, so it is decided by its own cost and
/// the whole model collapses to two numbers. The reductions compose.
test "presolve eliminates a fixed variable and keeps its objective contribution" {
  // min x + y  s.t.  x + y >= 5,  x = 2,  y >= 0   ->   x = 2, y = 3, objective 5
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=2.0, ub=2.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_named_constraint(
    [(x, 1.0), (y, 1.0)],
    @model.Rel::GreaterEqual,
    5.0,
    "cover",
  )
  let reduced = presolve(model)
  assert_eq(reduced.verdict(), Reduced)
  assert_eq(reduced.stats().variables_fixed, 2)
  // Phase order matters and is worth pinning down: the row is tightened first
  // (`y >= 5 - 2`), and by the time the singleton rule would look at it the row is
  // already implied by the bound, so it leaves as redundant rather than as a
  // singleton. Dropping settled rows before consuming singleton rows is safe
  // because a settled row carries no information the bounds do not.
  assert_eq(reduced.stats().bounds_tightened, 1)
  assert_eq(reduced.stats().rows_removed_redundant, 1)
  assert_eq(reduced.stats().rows_removed_singleton, 0)
  assert_eq(reduced.reduced().num_constraints(), 0)
  assert_eq(reduced.reduced().num_vars(), 0)
  assert_true(
    @core.approx_eq(reduced.objective_offset(), 5.0, rel=1.0e-9, abs=1.0e-9),
  )
  let values = reduced.reconstruct([])
  assert_true(@core.approx_eq(values[0], 2.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(@core.approx_eq(values[1], 3.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(
    @core.approx_eq(reduced.objective(0.0), 5.0, rel=1.0e-9, abs=1.0e-9),
  )
  // The reconstruction is a solution of the original model, checked from the row
  // data rather than from the reduction's own bookkeeping.
  assert_true(max_row_violation(model, values) <= 1.0e-9)
  assert_true(max_bound_violation(model, values) <= 1.0e-9)
}

///|
/// A variable no row mentions is decided by its own cost alone. Here that happens
/// twice: `x` never appears in a row, and `y` stops appearing in one as soon as
/// its singleton row is consumed.
test "presolve fixes an unconstrained variable at its improving bound" {
  // min 3x + y  s.t.  y >= 4,  0 <= x <= 10   ->   x = 0, y = 4, objective 4
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=10.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(x, 3.0), (y, 1.0)])
  model.add_named_constraint(
    [(y, 1.0)],
    @model.Rel::GreaterEqual,
    4.0,
    "need_y",
  )
  let reduced = presolve(model)
  assert_eq(reduced.stats().columns_removed_empty, 2)
  assert_eq(reduced.num_original_vars(), 2)
  let values = reduced.reconstruct([])
  assert_true(@core.approx_eq(values[0], 0.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(@core.approx_eq(values[1], 4.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(
    @core.approx_eq(reduced.objective(0.0), 4.0, rel=1.0e-9, abs=1.0e-9),
  )
}

///|
/// The same reduction, with the improving direction unbounded: that is a proof
/// about the model, and it has to be reported instead of solved.
test "presolve reports an unconstrained variable that runs away" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(x, -1.0), (y, 1.0)])
  model.add_named_constraint(
    [(y, 1.0)],
    @model.Rel::GreaterEqual,
    4.0,
    "need_y",
  )
  let reduced = presolve(model)
  assert_eq(reduced.verdict(), Unbounded)
  assert_true(reduced.reason().contains("no finite upper bound"))
}

///|
/// An implied bound, and the direction that makes it non-trivial: a `>=` row is
/// bounded by the largest the other terms can be, not the smallest.
test "presolve tightens a bound implied by the other terms" {
  // min y  s.t.  x + y >= 10,  0 <= x <= 4,  y >= 0   ->   y >= 10 - 4 = 6
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=4.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(y, 1.0)])
  model.add_named_constraint(
    [(x, 1.0), (y, 1.0)],
    @model.Rel::GreaterEqual,
    10.0,
    "cover",
  )
  let reduced = presolve(model)
  assert_eq(reduced.verdict(), Reduced)
  assert_true(reduced.stats().bounds_tightened >= 1)
  assert_eq(reduced.reduced().num_vars(), 2)
  assert_true(
    @core.approx_eq(
      reduced.reduced().get_var(1).lb,
      6.0,
      rel=1.0e-9,
      abs=1.0e-9,
    ),
  )
}

///|
/// The case where subtracting a variable's own contribution from the activity
/// would produce `inf - inf`. With the other term unbounded, the row implies
/// nothing here, so presolve must *not* invent a bound; the model is unbounded,
/// and proving that is the kernel's job (a ray, not a box).
test "presolve invents no bound when the other terms are unbounded" {
  // min -y  s.t.  y - x <= 7,  y >= 0,  x >= 0, x unbounded above
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(y, -1.0)])
  model.add_named_constraint(
    [(x, -1.0), (y, 1.0)],
    @model.Rel::LessEqual,
    7.0,
    "cap",
  )
  let reduced = presolve(model)
  assert_eq(reduced.verdict(), Reduced)
  assert_eq(reduced.reduced().num_vars(), 2)
  assert_true(is_sentinel(reduced.reduced().get_var(1).ub))
}

///|
/// The mirror image: with the other variable bounded, the same row does imply an
/// upper bound, and the reduction has to find it.
test "presolve finds an upper bound through a negative coefficient" {
  // min -y  s.t.  y - x <= 7,  0 <= x <= 2,  y >= 0   ->   y <= 9
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=2.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(y, -1.0)])
  model.add_named_constraint(
    [(x, -1.0), (y, 1.0)],
    @model.Rel::LessEqual,
    7.0,
    "cap",
  )
  let reduced = presolve(model)
  assert_eq(reduced.verdict(), Reduced)
  assert_eq(reduced.reduced().num_vars(), 2)
  assert_true(
    @core.approx_eq(
      reduced.reduced().get_var(1).ub,
      9.0,
      rel=1.0e-9,
      abs=1.0e-9,
    ),
  )
  let values = reduced.reconstruct([2.0, 9.0])
  assert_true(max_row_violation(model, values) <= 1.0e-9)
  assert_true(max_bound_violation(model, values) <= 1.0e-9)
}
