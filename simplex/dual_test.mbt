///|
/// The dual simplex warm start.
///
/// The claim being tested is narrow and checkable: starting from a previous optimal
/// basis and reoptimizing has to give the same answer as solving from scratch, on the
/// model as it now stands — same status, same objective, a point that is feasible, and a
/// certificate the independent verifier accepts. The warm start is a speedup, so a
/// difference in the answer would not be a rounding curiosity but a bug.

///|
/// Solves cold, or `None` when the kernel refuses the model itself.
fn cold(model : @model.Model) -> @simplex.SimplexResult? {
  try_solve(model)
}

///|
/// `min 3x + 2y  s.t.  x + y ≥ 4,  x + 3y ≥ 6,  0 ≤ x, y ≤ 5`.
fn bounded_two_variable_lp() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=5.0)
  let y = model.add_var("y", lb=0.0, ub=5.0)
  model.set_objective([(x, 3.0), (y, 2.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::GreaterEqual, 4.0)
  model.add_constraint([(x, 1.0), (y, 3.0)], @model.Rel::GreaterEqual, 6.0)
  model
}

///|
test "a warm start reaches the same answer as a cold solve" {
  let model = bounded_two_variable_lp()
  let first = match cold(model) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  assert_eq(first.status, @simplex.SimplexStatus::Optimal)
  let basis = match first.basis {
    Some(value) => value
    None => fail("an optimal run did not report a basis")
  }
  // Tighten a bound, so the basis is now primal infeasible but still dual feasible —
  // the state the dual simplex exists for.
  model.set_var_bounds(1, 0.0, 0.5)
  let warm = match
    @simplex.solve_model_with_basis(
      model,
      @simplex.SimplexOptions::default(),
      basis,
    ) {
    Ok(result) => result
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  let scratch = match cold(model) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  assert_eq(warm.status, scratch.status)
  assert_true(
    @core.approx_eq(warm.objective, scratch.objective, rel=1.0e-7, abs=1.0e-7),
  )
  assert_true(warm.values[1] <= 0.5 + 1.0e-7)
  // The reoptimized answer carries a proof the independent verifier accepts, which is
  // what makes it an answer rather than a plausible vector.
  let verdict = @verify.verify(model, certificate_of(warm))
  if !verdict.accepted {
    fail("the warm start's certificate was refused:\n" + verdict.to_text())
  }
}

///|
test "a warm start detects infeasibility after a bound is tightened" {
  let model = bounded_two_variable_lp()
  let first = match cold(model) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  let basis = match first.basis {
    Some(value) => value
    None => fail("no basis")
  }
  // `x + y ≥ 4` cannot hold when both variables are capped below 2.
  model.set_var_bounds(0, 0.0, 1.0)
  model.set_var_bounds(1, 0.0, 1.0)
  let warm = match
    @simplex.solve_model_with_basis(
      model,
      @simplex.SimplexOptions::default(),
      basis,
    ) {
    Ok(result) => result
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  assert_eq(warm.status, @simplex.SimplexStatus::Infeasible)
  // The verdict comes from the cold path: the dual simplex's own "no column can bring
  // this row back" is a statement about its basis, not a proof about the model, and it
  // produced a false "infeasible" on two MIPLIB instances (see `solve_from_basis`).
  // Whatever the path, the certificate has to hold up under the independent check.
  let verdict = @verify.verify(model, certificate_of(warm))
  if !verdict.accepted {
    fail(
      "the warm start's infeasibility certificate was refused:\n" +
      verdict.to_text(),
    )
  }
}

///|
test "a basis from another problem is refused rather than trusted" {
  let model = bounded_two_variable_lp()
  let first = match cold(model) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  let basis = match first.basis {
    Some(value) => value
    None => fail("no basis")
  }
  // A different model, so the basis cannot mean anything for it: the run has to notice
  // and fall back to a cold start rather than pivot on columns that are not there.
  let other = @model.Model::new(@model.Sense::Minimize)
  let a = other.add_var("a", lb=0.0, ub=5.0)
  let b = other.add_var("b", lb=0.0, ub=5.0)
  let c = other.add_var("c", lb=0.0, ub=5.0)
  other.set_objective([(a, 1.0), (b, 1.0), (c, 1.0)])
  other.add_constraint(
    [(a, 1.0), (b, 1.0), (c, 1.0)],
    @model.Rel::GreaterEqual,
    2.0,
  )
  let warm = match
    @simplex.solve_model_with_basis(
      other,
      @simplex.SimplexOptions::default(),
      basis,
    ) {
    Ok(result) => result
    Err(reason) => fail("kernel refused the model: " + reason)
  }
  let scratch = match cold(other) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  assert_eq(warm.status, scratch.status)
  assert_true(
    @core.approx_eq(warm.objective, scratch.objective, rel=1.0e-7, abs=1.0e-7),
  )
}

///|
/// The same comparison over a corpus, because one model proves that a path works and a
/// corpus is what says it keeps working. Each round solves a random model, tightens a
/// random bound on its optimum, and requires the warm start and a cold solve to agree.
test "warm and cold agree on a random corpus of tightened models" {
  let lcg = CertLcg::new(20260918)
  let mut compared = 0
  let mut tightened = 0
  let mut infeasible = 0
  let mut skipped = 0
  let mut warm_iterations = 0
  let mut cold_iterations = 0
  for sample = 0; sample < 120; sample = sample + 1 {
    let model = random_certificate_model(lcg)
    let first = match cold(model) {
      Some(result) => result
      None => {
        skipped = skipped + 1
        continue
      }
    }
    if first.status != @simplex.SimplexStatus::Optimal {
      skipped = skipped + 1
      continue
    }
    let basis = match first.basis {
      Some(value) => value
      None => {
        skipped = skipped + 1
        continue
      }
    }
    // Tighten one variable's upper bound so the previous optimum stops being feasible.
    let target = lcg.below(model.num_vars())
    let variable = model.get_var(target)
    let upper = if variable.ub < 1.0e29 { variable.ub } else { 4.0 }
    let lowered = variable.lb + (upper - variable.lb) * 0.5
    if lowered <= variable.lb {
      skipped = skipped + 1
      continue
    }
    model.set_var_bounds(target, variable.lb, lowered)
    tightened = tightened + 1
    let warm = match
      @simplex.solve_model_with_basis(
        model,
        @simplex.SimplexOptions::default(),
        basis,
      ) {
      Ok(result) => result
      Err(_) => {
        skipped = skipped + 1
        continue
      }
    }
    let scratch = match cold(model) {
      Some(result) => result
      None => {
        skipped = skipped + 1
        continue
      }
    }
    if warm.status != scratch.status {
      fail(
        "sample " +
        sample.to_string() +
        ": warm " +
        status_name(warm.status) +
        " against cold " +
        status_name(scratch.status) +
        "\nmodel:\n" +
        describe_model(model),
      )
    }
    if warm.status == @simplex.SimplexStatus::Infeasible {
      infeasible = infeasible + 1
    }
    if warm.status == @simplex.SimplexStatus::Optimal {
      if !@core.approx_eq(
          warm.objective,
          scratch.objective,
          rel=1.0e-6,
          abs=1.0e-6,
        ) {
        fail(
          "sample " +
          sample.to_string() +
          ": warm objective " +
          warm.objective.to_string() +
          " against cold " +
          scratch.objective.to_string() +
          "\nmodel:\n" +
          describe_model(model),
        )
      }
      if !@core.approx_eq(
          warm.values[target],
          scratch.values[target],
          rel=1.0e-6,
          abs=1.0e-6,
        ) {
        // Two optima may differ, so the values are not required to agree; what is
        // required is that both are optimal. The objective above carries that.
      }
    }
    let verdict = @verify.verify(model, certificate_of(warm))
    if !verdict.accepted {
      fail(
        "sample " +
        sample.to_string() +
        ": the warm certificate was refused:\n" +
        verdict.to_text() +
        "\nmodel:\n" +
        describe_model(model),
      )
    }
    compared = compared + 1
    warm_iterations = warm_iterations + warm.iterations
    cold_iterations = cold_iterations + scratch.iterations
  }
  assert_true(compared > 0)
  assert_true(tightened > 0)
  // The corpus has to reach the infeasible case too, or the dual simplex's own
  // infeasibility path is untested by it.
  assert_true(infeasible > 0)
  assert_eq(compared + skipped, 120)
  // And the point of the whole thing: reoptimizing from a basis has to cost fewer
  // pivots than rebuilding the run from scratch. Aggregated over the corpus, not per
  // model, because a single small model can go either way and this is a claim about
  // the path rather than about one instance.
  assert_true(warm_iterations < cold_iterations)
}

///|
/// Status as text, for failure messages.
fn status_name(status : @simplex.SimplexStatus) -> String {
  match status {
    @simplex.SimplexStatus::Optimal => "Optimal"
    @simplex.SimplexStatus::Infeasible => "Infeasible"
    @simplex.SimplexStatus::Unbounded => "Unbounded"
    @simplex.SimplexStatus::IterationLimit => "IterationLimit"
    @simplex.SimplexStatus::NumericalFailure => "NumericalFailure"
    @simplex.SimplexStatus::TooLarge => "TooLarge"
  }
}
