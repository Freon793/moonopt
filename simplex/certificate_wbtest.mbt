///|
/// The duality-gap self-check measures the checker's number, not a second opinion about it.
///
/// `State::duality_gap_violation` exists so that the kernel never hands a caller a certificate
/// whose optimality argument does not close — the measurement `verify` makes from the
/// certificate after the fact, made by the producer before it emits one. A self-check that
/// stands in for another check is only worth having if it measures *what that check measures*:
/// being stricter refuses certificates the checker would have accepted (and costs the search
/// the work of a node it did not have to lose), and being looser is not a check at all. So the
/// test below does not assert that the kernel's gap is *small* — the other tests already say
/// the optima are right — it asserts that it is the same number the checker computes, on models
/// that between them exercise a shifted lower bound, a row bound, an equality, a free variable
/// and a free variable with an upper bound (the split and the split-plus-row cases, where the
/// model's bounds are neither the kernel's column bounds nor its offsets).

///|
/// `min 2x + 3y` subject to `x + y = 4`, `x − y ≥ 1`, `0 ≤ x ≤ 3`, `0 ≤ y ≤ 2`.
fn gap_model_equalities() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=3.0)
  let y = model.add_var("y", lb=0.0, ub=2.0)
  model.set_objective([(x, 2.0), (y, 3.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::Equal, 4.0)
  model.add_constraint([(x, 1.0), (y, -1.0)], @model.Rel::GreaterEqual, 1.0)
  model
}

///|
/// `max x + 2y` subject to `x + y ≤ 5`, `0 ≤ x ≤ 4`, `0 ≤ y ≤ 4`.
fn gap_model_maximisation() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=4.0)
  let y = model.add_var("y", lb=0.0, ub=4.0)
  model.set_objective([(x, 1.0), (y, 2.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 5.0)
  model
}

///|
/// `min x` subject to `−2 ≤ x ≤ 3` (rows, since `x` is free), `x + y = 1`, `y ≥ 0`.
///
/// `x` is split into two non-negative columns with no column bound of its own, so its model
/// bounds come back from the rows rather than from `var_offset` or `upper`.
fn gap_model_free_variable() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=-@model.infinite_bound)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, -2.0)
  model.add_constraint([(x, 1.0)], @model.Rel::LessEqual, 3.0)
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::Equal, 1.0)
  model
}

///|
/// `max x` subject to `x + y = 10`, `0 ≤ y ≤ 4`, `x` free below and `x ≤ 7` by its own bound.
///
/// This is the split *plus* an explicit row for the upper bound, the case where a
/// difference of two columns has no per-column bound to carry it.
fn gap_model_free_with_bound() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=-@model.infinite_bound, ub=7.0)
  let y = model.add_var("y", lb=0.0, ub=4.0)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::Equal, 10.0)
  model
}

///|
/// `min x + y` subject to `x + y ≥ 5`, `x ≥ 2`, `−3 ≤ y ≤ 1`: two shifted lower bounds, so
/// `var_offset` is not zero and the kernel's right hand sides are not the model's.
fn gap_model_shifted_bounds() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=2.0)
  let y = model.add_var("y", lb=-3.0, ub=1.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::GreaterEqual, 5.0)
  model
}

///|
/// `min 4x + y` subject to `x + y ≥ 5`, `0 ≤ y ≤ 3`, `x` fixed at `3` by its bounds: a kernel
/// column with an upper bound of zero.
fn gap_model_fixed_variable() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=3.0, ub=3.0)
  let y = model.add_var("y", lb=0.0, ub=3.0)
  model.set_objective([(x, 4.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::GreaterEqual, 5.0)
  model
}

///|
/// For every model: the gap the kernel measures before it emits a certificate is the number
/// `verify` measures from that certificate, and the two agree on whether it is inside the
/// tolerance the checker is given.
test "the kernel measures the duality gap the checker measures" {
  let models = [
    gap_model_equalities(),
    gap_model_maximisation(),
    gap_model_free_variable(),
    gap_model_free_with_bound(),
    gap_model_shifted_bounds(),
    gap_model_fixed_variable(),
  ]
  let mut compared = 0
  for model in models {
    let result = match solve_model_with(model, SimplexOptions::default()) {
      Ok(value) => value
      Err(reason) => fail("kernel refused the model: " + reason)
    }
    assert_eq(result.status, Optimal)
    let problem = match KernelProblem::from_model(model) {
      Ok(value) => value
      Err(reason) => fail("kernel refused the model: " + reason)
    }
    let state = State::new(problem, SimplexOptions::default())
    let (gap, _, _) = state.duality_gap_violation(result.values, result.duals)
    let certificate : @verify.Certificate = {
      claim: @verify.Claim::Optimal,
      values: result.values,
      duals: result.duals,
      ray: result.ray,
      objective: result.objective,
    }
    let verdict = @verify.verify(model, certificate)
    // The certificate the kernel emits is one the checker accepts, so the gap below is a gap
    // the checker actually computed about a certificate it accepted rather than about one it
    // refused for something else first.
    assert_true(verdict.accepted)
    let mut seen = 0
    for item in verdict.checks {
      if item.name == "duality gap" {
        seen = seen + 1
        // The same number: same expression, same operands, same order of accumulation, so the
        // two agree to the last place rather than to a tolerance of their own.
        assert_true(@core.approx_eq(gap, item.measured, rel=1.0e-15, abs=0.0))
        // And the same verdict about it.
        assert_eq(gap <= 1.0e-7, item.ok)
      }
    }
    assert_eq(seen, 1)
    compared = compared + 1
  }
  assert_eq(compared, 6)
}

///|
/// The term a reduced cost contributes from *inside* the tolerance band, which is the case the
/// checker's own bound used to get wrong and the case the six models above turn out not to reach.
///
/// `min x` subject to `1000x ≥ 1000` with `x ∈ [0, 1000]`: the optimum is `x = 1`, and its
/// multiplier is `c/1000 = 1e-3`, which makes `x`'s reduced cost exactly zero. Nudging the
/// multiplier by `1e-10` moves that reduced cost to `1000 · (−1e-10) = −1e-7`, against a scale of
/// `1 + |c| + |1000y| ≈ 3` and so a band of `3e-7`: the reduced cost is *inside* the band, points
/// at the upper bound `1000`, and is worth `1000 · (−1e-7) = −1e-4` of Lagrangian bound.
///
/// A box minimum that reads "inside the band" as "worth nothing" comes out `1e-4` above the
/// bound the checker computes — three orders of magnitude, which is why the two have to be
/// measured the same way rather than each with a rule of its own. The certificate here is one
/// the checker refuses (that is the point: the gap is real), and its refusal is a statement
/// about a certificate the kernel's own measurement agrees with.
test "the kernel's gap counts a reduced cost inside the tolerance band" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=1000.0)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1000.0)], @model.Rel::GreaterEqual, 1000.0)
  let result = match solve_model_with(model, SimplexOptions::default()) {
    Ok(value) => value
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(result.status, Optimal)
  assert_true(@core.approx_eq(result.values[0], 1.0, rel=1.0e-9, abs=1.0e-12))
  let problem = match KernelProblem::from_model(model) {
    Ok(value) => value
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  let state = State::new(problem, SimplexOptions::default())
  let (honest, _, _) = state.duality_gap_violation(result.values, result.duals)
  assert_true(honest <= 1.0e-7)
  let duals = result.duals.copy()
  duals[0] = duals[0] + 1.0e-10
  let (gap, primal, bound) = state.duality_gap_violation(result.values, duals)
  // The two numbers this measurement is made of, so a change in either is visible: the point is
  // worth `1`, and the bound is `1e-4` short of it.
  assert_true(@core.approx_eq(primal, result.values[0], rel=1.0e-15, abs=0.0))
  assert_true(@core.approx_eq(bound, 1.0 - 1.0e-4, rel=1.0e-6, abs=1.0e-12))
  assert_true(gap > 1.0e-7)
  let certificate : @verify.Certificate = {
    claim: @verify.Claim::Optimal,
    values: result.values,
    duals,
    ray: result.ray,
    objective: result.objective,
  }
  let verdict = @verify.verify(model, certificate)
  assert_true(!verdict.accepted)
  let mut seen = 0
  for item in verdict.checks {
    if item.name == "duality gap" {
      seen = seen + 1
      assert_true(@core.approx_eq(gap, item.measured, rel=1.0e-15, abs=0.0))
      assert_false(item.ok)
    }
  }
  assert_eq(seen, 1)
}
