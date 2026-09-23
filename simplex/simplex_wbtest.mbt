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
/// An unboundedness verdict is a proof, not just a status: the run reports the
/// feasible point it was standing on and the direction it could travel forever from
/// there. (The public `Solution` still reports no values for this status; the pair is
/// there for a certificate to be checked against.)
test "kernel detects unboundedness and reports where the ray starts" {
  // min -x  s.t.  x >= 1
  let result = solve_standard(1, [-1.0], [
    ([1.0], @model.Rel::GreaterEqual, 1.0),
  ])
  assert_eq(result.status, Unbounded)
  assert_eq(result.values.length(), 1)
  assert_true(result.values[0] >= 1.0 - 1.0e-7)
  assert_eq(result.ray.length(), 1)
  assert_true(result.ray[0] > 0.5)
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
/// A non-basic variable resting at its upper bound is part of the solution.
///
/// This is the invariant the bounded-variable kernel adds: before, a finite upper
/// bound was a row and the variable's value lived in the row's slack. Now the
/// variable sits at one end of its range and the flag that says which end has to
/// reach `values()`, or a solution would silently lose a variable that does have a
/// value.
test "kernel: a non-basic variable at its upper bound is reported at that bound" {
  // min x  s.t.  x <= 1,  0 <= x <= 1. The constraint becomes an ordinary row with a
  // slack column, the bound stays a bound, so the kernel has one row and two
  // columns: x (bounded above by one, cost one) and the row's slack.
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=1.0)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::LessEqual, 1.0)
  let problem = match from_model_with(model, false) {
    Ok(problem) => problem
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(problem.nrows, 1)
  let state = State::new(problem, SimplexOptions::default())
  // The slack of the row is basic at one and `x` is non-basic at its lower bound.
  // Moving `x` to its upper bound is exactly the move a bound buys: as a row it
  // would have been a pivot through the row's slack.
  state.enter_sigma = 1.0
  state.apply_flip(0, [1.0], 1.0)
  let values = state.values()
  assert_true(@core.approx_eq(values[0], 1.0, rel=0.0, abs=1.0e-9))
  // The slack only moves by the round-off the degeneracy perturbation leaves behind
  // (a `1e-12` nudge of the right hand side), so the tolerance is that scale and not
  // a machine epsilon.
  assert_true(@core.approx_eq(values[1], 0.0, rel=0.0, abs=1.0e-9))
}

///|
/// The ratio test has to read both bounds: a basic variable can stop a step by
/// falling to zero *or* by rising to its own upper bound, and the second limit is
/// new. `max x + y` with `x + y <= 4`, `x <= 3`, `y <= 1` puts the optimum at
/// (3, 1), where both variables sit on their upper bounds.
test "model path: an optimum that sits on two upper bounds" {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=3.0)
  let y = model.add_var("y", lb=0.0, ub=1.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 4.0)
  let result = match solve_model(model) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, 4.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(result.values[0] <= 3.0 + 1.0e-9)
  assert_true(result.values[1] <= 1.0 + 1.0e-9)
  assert_true(
    @core.approx_eq(
      result.values[0] + result.values[1],
      4.0,
      rel=1.0e-9,
      abs=1.0e-9,
    ),
  )
}

///|
/// Gain pricing is a control on the *run*, not on its answer: which column enters
/// changes the path through the vertices, and the optimum a path arrives at has to
/// be the same one. This pins that at a budget of nothing, of one measured
/// candidate, and of more than there are columns.
test "gain pricing changes the run, not the answer" {
  // min -x - 2y  s.t.  x + y <= 4,  x + 3y <= 6,  x, y >= 0  ->  -5 at (3, 1)
  let cost : Array[Double] = [-1.0, -2.0]
  let rows : Array[(Array[Double], @model.Rel, Double)] = [
    ([1.0, 1.0], @model.Rel::LessEqual, 4.0),
    ([1.0, 3.0], @model.Rel::LessEqual, 6.0),
  ]
  let baseline = solve_standard_with(2, cost, rows, SimplexOptions::default())
  assert_eq(baseline.status, Optimal)
  assert_true(@core.approx_eq(baseline.objective, -5.0, rel=1.0e-9, abs=1.0e-9))
  for budget in [0, 1, 64] {
    let result = solve_standard_with(
      2,
      cost,
      rows,
      SimplexOptions::with_gain_candidates(budget),
    )
    assert_eq(result.status, Optimal)
    assert_true(
      @core.approx_eq(
        result.objective,
        baseline.objective,
        rel=1.0e-9,
        abs=1.0e-9,
      ),
    )
  }
}

///|
/// The stall window is a guard on the *run*, never on its answer. It used to be
/// `2m + 50` pivots, which on a kernel problem of tens of thousands of rows asks
/// for more consecutive unimproved pivots than the default iteration cap allows,
/// so the Bland fallback could not fire at all — in exactly the case it exists
/// for. It is a fixed count now, and this test pins the property that matters:
/// firing at every stall, at the default, and never has to give the same answer.
test "the stall window changes the run, not the answer" {
  // A degenerate problem: three rows share the same optimum face, so a run over it
  // has plenty of pivots that do not move the objective.
  //   min -x - y - z  s.t.  x + y <= 1, x + z <= 1, y + z <= 1, x + y + z <= 2
  let cost : Array[Double] = [-1.0, -1.0, -1.0]
  let rows : Array[(Array[Double], @model.Rel, Double)] = [
    ([1.0, 1.0, 0.0], @model.Rel::LessEqual, 1.0),
    ([1.0, 0.0, 1.0], @model.Rel::LessEqual, 1.0),
    ([0.0, 1.0, 1.0], @model.Rel::LessEqual, 1.0),
    ([1.0, 1.0, 1.0], @model.Rel::LessEqual, 2.0),
  ]
  let baseline = solve_standard_with(3, cost, rows, SimplexOptions::default())
  assert_eq(baseline.status, Optimal)
  // Summing the three pair constraints gives `2(x+y+z) <= 3`, so the best is 1.5
  // at (0.5, 0.5, 0.5), and the all-pairs total row is slack there.
  assert_true(@core.approx_eq(baseline.objective, -1.5, rel=1.0e-9, abs=1.0e-9))
  for window in [0, 1, 10, 500] {
    let result = solve_standard_with(
      3,
      cost,
      rows,
      SimplexOptions::with_stall_window(window),
    )
    assert_eq(result.status, Optimal)
    assert_true(
      @core.approx_eq(
        result.objective,
        baseline.objective,
        rel=1.0e-9,
        abs=1.0e-9,
      ),
    )
  }
}

///|
/// A finite upper bound is a bound, not a row. It used to be an explicit row, so
/// this model — twenty bounded variables and one constraint — was twenty-one kernel
/// rows, and it is the same mechanism that took MIPLIB's 507 constraint `fast0507`
/// to 63 490 rows. The pivot count follows the kernel row count, so those rows were
/// the instance: with bounded-variable pivoting the kernel problem is the one
/// constraint, and a ceiling of exactly one row is enough to solve it.
test "model path: a finite upper bound costs no kernel row" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let vars : Array[Int] = []
  for j = 0; j < 20; j = j + 1 {
    vars.push(model.add_var("x" + j.to_string(), lb=0.0, ub=1.0))
  }
  model.set_objective([(vars[0], 1.0)])
  model.add_constraint([(vars[0], 1.0)], @model.Rel::GreaterEqual, 0.5)
  let result = match
    solve_model_with(model, SimplexOptions::with_max_kernel_rows(1)) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.objective, 0.5, rel=1.0e-9, abs=1.0e-9))
}

///|
/// A model row count is still not a kernel row count, and the ceiling still counts
/// the latter. What inflates it now is a free variable with a finite upper bound:
/// `x` free with `x ≤ ub` has to be a difference of two columns, and a difference
/// has no per-column bound, so that one stays an explicit row. Eight of those plus
/// one constraint is nine kernel rows.
test "model path: kernel rows can still exceed the model's rows" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let vars : Array[Int] = []
  for j = 0; j < 8; j = j + 1 {
    vars.push(
      model.add_var("f" + j.to_string(), lb=-@model.infinite_bound, ub=10.0),
    )
  }
  model.set_objective([(vars[0], 1.0)])
  model.add_constraint([(vars[0], 1.0)], @model.Rel::GreaterEqual, 0.5)
  let result = match
    solve_model_with(model, SimplexOptions::with_max_kernel_rows(5)) {
    Ok(ok) => ok
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, TooLarge)
  assert_true(result.message.contains("9 rows"))
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

///|
/// The warm path is not allowed to make an infeasibility claim.
///
/// "No column can bring this infeasible row back" is a statement about the basis the dual
/// simplex is standing on, and the tableau it reads it from can be wrong: on branch and
/// bound nodes of MIPLIB's `blend2` and `noswot` it stopped with "infeasible" on models a
/// cold solve then solved to optimality (7.727699757815 and -39.830059908477, both
/// confirmed by an outside solver). A warm start may be slower than a claim, never more
/// confident than one, so `solve_from_basis` hands the verdict to the cold path — and this
/// pins that by calling it directly on a model whose tightened bounds make it infeasible.
test "the warm path refuses to declare infeasibility" {
  // min x + y  s.t.  x + y ≥ 4, 0 ≤ x, y ≤ 2 — feasible at (2, 2).
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=2.0)
  let y = model.add_var("y", lb=0.0, ub=2.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::GreaterEqual, 4.0)
  let first = match solve_model(model) {
    Ok(value) => value
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  let basis = match first.basis {
    Some(value) => value
    None => fail("no basis")
  }
  // Tighten both bounds so `x + y ≥ 4` can no longer hold.
  model.set_var_bounds(x, 0.0, 1.0)
  model.set_var_bounds(y, 0.0, 1.0)
  let problem = match KernelProblem::from_model(model) {
    Ok(value) => value
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  let warm = solve_from_basis(problem, SimplexOptions::default(), basis)
  assert_true(warm is None)
  // And the verdict is still available, from the path that can justify it.
  let cold = match solve_model(model) {
    Ok(value) => value
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(cold.status, Infeasible)
}

///|
/// The case that broke this was a basic value a few 1e-10 *outside* its bounds — the
/// round-off every long run carries. Read as a distance, "already past the bound it is
/// moving toward" came out negative, and because the strict pass compares against a
/// `ratio_min` that starts at zero the first such row won: the entering variable then
/// travelled backwards, every basic value moved away from its bounds at once, and the
/// rows that ended up outside were *skipped* by the guards meant to keep them in. On a
/// branch and bound node of MIPLIB's `22433` that walked a basic artificial down to -4,
/// and Phase I reported a feasible model as infeasible; the verifier's refusal of the
/// Farkas ray is what made it visible.
test "the ratio test never returns a negative step" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=1.0)
  let y = model.add_var("y", lb=0.0, ub=1.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 1.0)
  let problem = match KernelProblem::from_model(model) {
    Ok(value) => value
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  let state = State::new(problem, SimplexOptions::default())
  // `x` (kernel column 0, upper bound 1) as the basic column of row 0, sitting a hair
  // above its own upper bound, with an entering column that pushes it further up.
  state.basis[0] = 0
  state.xb[0] = 1.0 + 2.0e-10
  state.enter_sigma = 1.0
  let up = state.ratio_test(1, [-1.0])
  assert_true(up.step >= 0.0)
  assert_eq(up.step, 0.0)
  // And the mirror case: a basic value a hair below zero, pushed further down.
  state.basis[0] = 0
  state.xb[0] = -2.0e-10
  let down = state.ratio_test(1, [1.0])
  assert_true(down.step >= 0.0)
  // `row_step` is the routine that produced the backward distance, so it is pinned on
  // its own as well.
  assert_eq(state.row_step(0, 1.0), 0.0)
  assert_true(state.row_step(0, -1.0) >= 0.0)
}

///|
/// A step is a distance travelled in the direction the entering column moves, so the
/// ratio test may never return a negative one.

///|
/// The non-negativity self-check has to read a value against its *own* size, because
/// that is what the variable's bound means and that is how `verify` reads it.
///
/// It used to read it against the largest entry anywhere in the solution, and that is a
/// different statement: a basic value of `-7.7e-7` next to an entry of `1e5` measured
/// `7.7e-12` here and passed the kernel's own gate, while the independent checker —
/// which divides each violation by `1 + |xⱼ|` — measured `7.7e-7` and refused the point.
/// A branch and bound node of `noswot` reached exactly that pair of numbers, and the run
/// had reported the node as solved.
test "non-negativity is measured per variable, not against the solution" {
  let worst = max_negativity([1.0e5, 0.0, -7.7e-7])
  let expected = 7.7e-7 / (1.0 + 7.7e-7)
  assert_true(@core.approx_eq(worst, expected, rel=1.0e-12, abs=1.0e-15))
  // A giant entry elsewhere does not license a violation of a variable's own bound.
  let small = max_negativity([1.0e5, -1.0e-6])
  assert_true(
    @core.approx_eq(small, 1.0e-6 / (1.0 + 1.0e-6), rel=1.0e-12, abs=1.0e-15),
  )
  assert_true(small > 1.0e-7)
  // Round-off next to a variable of size one is still round-off.
  assert_true(max_negativity([1.0, -1.0e-12]) < 1.0e-7)
  assert_eq(max_negativity([1.0, 2.0, 0.0]), 0.0)
}

///|
/// The dual sign self-check is the checker's own expression, and the two have to reach
/// the same verdict on the same multipliers.
///
/// A multiplier is judged by the effect a wrong sign can have — `|y| · max|aᵢⱼ|` against
/// the largest objective coefficient — and not by its own size. The model below separates
/// the two: the offending multiplier is `5e-8`, which is round-off by itself, against a row
/// of coefficients in the hundreds whose prices are of order one, which makes it a
/// violation three hundred million times the tolerance. Every number here is exact by
/// construction, so the assertion is on the formula rather than on a range.
test "the dual sign self-check measures what the checker measures" {
  // min 4x  s.t.  300x ≥ 6,  x ≥ 0  ->  0.08 at x = 0.02, with the dual 4/300.
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  model.set_objective([(x, 4.0)])
  model.add_constraint([(x, 300.0)], @model.Rel::GreaterEqual, 6.0)
  let problem = match KernelProblem::from_model(model) {
    Ok(value) => value
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  let state = State::new(problem, SimplexOptions::default())
  let tolerance = 1.0e-7
  // The convention wants `y ≥ 0` on a `≥` row; this one goes the other way.
  let (worst, row) = state.max_dual_sign_violation([-5.0e-8])
  assert_eq(row, 0)
  let expected = 5.0e-8 * 300.0 / 4.0
  assert_true(@core.approx_eq(worst, expected, rel=1.0e-12, abs=1.0e-18))
  // The multiplier's own size is *not* the measurement.
  assert_true(5.0e-8 < tolerance)
  assert_true(worst > tolerance)
  // And the independent checker, given the same multipliers and a point that satisfies
  // everything else, refuses for the same reason and at the same scale.
  let refused = @verify.verify(model, {
    claim: @verify.Claim::Optimal,
    values: [0.02],
    duals: [-5.0e-8],
    ray: [],
    objective: 0.08,
  })
  assert_false(refused.accepted)
  assert_true(refused.reason.contains("dual signs"))
  // The honest multiplier of the same row is accepted by both, and the measurement answers
  // "no row" without looking at the matrix at all — which is the state every ordinary solve
  // is in, so it is what this check costs there.
  let honest_duals = [4.0 / 300.0]
  let (honest_worst, honest_row) = state.max_dual_sign_violation(honest_duals)
  assert_eq(honest_worst, 0.0)
  assert_eq(honest_row, -1)
  let accepted = @verify.verify(model, {
    claim: @verify.Claim::Optimal,
    values: [0.02],
    duals: honest_duals,
    ray: [],
    objective: 0.08,
  })
  assert_true(accepted.accepted)
  // An equality row's multiplier is free, so the self-check has to skip it — a kernel
  // that measured it would refuse certificates the checker accepts.
  let equality = @model.Model::new(@model.Sense::Minimize)
  let u = equality.add_var("u", lb=0.0)
  equality.set_objective([(u, 4.0)])
  equality.add_constraint([(u, 300.0)], @model.Rel::Equal, 6.0)
  let equality_problem = match KernelProblem::from_model(equality) {
    Ok(value) => value
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  let equality_state = State::new(equality_problem, SimplexOptions::default())
  let (equality_worst, equality_row) = equality_state.max_dual_sign_violation([
    -5.0e-8,
  ])
  assert_eq(equality_worst, 0.0)
  assert_eq(equality_row, -1)
  // The same pair of operations on the other scale: a model whose prices are `4e9` makes
  // the same multiplier round-off, and the checker's sign check passes it there — which is
  // the whole reason the scale is the objective's size and not the row's.
  let dear = @model.Model::new(@model.Sense::Minimize)
  let v = dear.add_var("v", lb=0.0)
  dear.set_objective([(v, 4.0e9)])
  dear.add_constraint([(v, 300.0)], @model.Rel::GreaterEqual, 6.0)
  let dear_problem = match KernelProblem::from_model(dear) {
    Ok(value) => value
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  let dear_state = State::new(dear_problem, SimplexOptions::default())
  let dear_worst = dear_state.max_dual_sign_violation([-5.0e-8]).0
  assert_true(
    @core.approx_eq(
      dear_worst,
      5.0e-8 * 300.0 / 4.0e9,
      rel=1.0e-12,
      abs=1.0e-20,
    ),
  )
  assert_true(dear_worst <= tolerance)
  let dear_verdict = @verify.verify(dear, {
    claim: @verify.Claim::Optimal,
    values: [0.02],
    duals: [-5.0e-8],
    ray: [],
    objective: 0.0,
  })
  assert_false(dear_verdict.reason.contains("dual signs"))
}

///|
/// The invariant the self-check exists for: a run that reports `Optimal` has multipliers its
/// own gate accepts, so nothing the kernel emits can be refused by the checker on the sign
/// axis.
///
/// The measurement and the emitted vector are the same array, and this is what keeps them
/// from drifting apart — a run that recomputed its multipliers for the result after
/// measuring an earlier vector would pass its own check and fail the caller's.
test "an optimal run emits the multipliers it measured" {
  let models : Array[@model.Model] = []
  let degenerate = @model.Model::new(@model.Sense::Minimize)
  let a = degenerate.add_var("a", lb=0.0)
  let b = degenerate.add_var("b", lb=0.0)
  degenerate.set_objective([(a, 1.0), (b, 1.0)])
  degenerate.add_constraint([(a, 1.0), (b, 1.0)], @model.Rel::GreaterEqual, 1.0)
  degenerate.add_constraint([(a, 1.0), (b, 1.0)], @model.Rel::LessEqual, 9.0)
  models.push(degenerate)
  let maximisation = @model.Model::new(@model.Sense::Maximize)
  let c = maximisation.add_var("c", lb=0.0, ub=4.0)
  let d = maximisation.add_var("d", lb=0.0, ub=4.0)
  maximisation.set_objective([(c, 1.0), (d, 2.0)])
  maximisation.add_constraint([(c, 1.0), (d, 1.0)], @model.Rel::Equal, 5.0)
  models.push(maximisation)
  let shifted = @model.Model::new(@model.Sense::Minimize)
  let e = shifted.add_var("e", lb=2.0, ub=5.0)
  shifted.set_objective([(e, -3.0)])
  shifted.add_constraint([(e, -1.0)], @model.Rel::LessEqual, -2.0)
  shifted.add_constraint([(e, 1.0)], @model.Rel::GreaterEqual, 1.0)
  models.push(shifted)
  let mut optimal = 0
  for model in models {
    let result = match solve_model_with(model, SimplexOptions::default()) {
      Ok(value) => value
      Err(reason) => fail("kernel refused the model: " + reason)
    }
    if result.status != Optimal {
      continue
    }
    optimal = optimal + 1
    let problem = match KernelProblem::from_model(model) {
      Ok(value) => value
      Err(reason) => fail("kernel refused the model: " + reason)
    }
    let state = State::new(problem, SimplexOptions::default())
    let (worst, row) = state.max_dual_sign_violation(result.duals)
    if worst > 1.0e-7 {
      fail(
        "an optimal run emitted multipliers its own gate refuses: " +
        worst.to_string() +
        " on model row " +
        row.to_string(),
      )
    }
  }
  assert_true(optimal > 0)
}

///|
/// The necessary condition between the two Phase I measurements, which is what decides whether
/// an infeasibility claim may be made at all. A total artificial value that cannot absorb the
/// violation it would be proving is not a proof of anything; the numbers below are the ones
/// measured on MIPLIB's `noswot` node 1558, where the kernel used to claim infeasibility and
/// the independent checker then measured a Farkas margin of exactly zero — stopping a search
/// that had nothing wrong with it.
test "an infeasibility claim needs artificials that can account for the violation" {
  // The measured failure: five orders of magnitude apart, about the same rows.
  assert_false(
    infeasibility_is_certified(1.204507679712393e-11, 1.942741867821951e-6),
  )
  // Real infeasibilities on the same instance: the artificials dwarf the violation.
  assert_true(infeasibility_is_certified(2.5840360220461505, 0.833001000000003))
  assert_true(infeasibility_is_certified(1.6667000000082763, 1.0))
  // The boundary is the margin, not equality: `Σ a = raw` passes, `Σ a = raw/20` does not.
  assert_true(infeasibility_is_certified(1.0, 10.0))
  assert_false(infeasibility_is_certified(0.5, 10.0))
  // An exact zero artificial sum is the trivial combination whatever the residual says.
  assert_false(infeasibility_is_certified(0.0, 1.0e-6))
}
