///|
/// Differential testing of presolve against the kernel.
///
/// The reduction claims two things, and this file is where both are checked on
/// models nobody wrote by hand:
///
/// 1. the reduced model has the same optimum, so solving it and adding the
///    reduction's objective offset has to agree with solving the original one;
/// 2. the reconstruction is a genuine solution of the original model, so the
///    values put back into the eliminated variables have to satisfy the original
///    rows and bounds — checked from the row data, not from presolve's
///    bookkeeping.
///
/// The generator is a deterministic LCG, so a failing case can be reproduced from
/// its seed alone. It deliberately produces the situations the reductions exist
/// for: variables no row mentions, variables whose bounds already meet, rows with
/// a single term, loose rows, and unbounded variables.

///|
/// Small linear congruential generator: reproducible, and good enough to spread
/// coefficient patterns over the corpus. The constants are small on purpose so the
/// sequence does not depend on integer wrap-around behaviour.
priv struct Lcg {
  mut state : Int
}

///|
/// Creates a generator from a seed.
fn Lcg::new(seed : Int) -> Lcg {
  { state: seed % 100003, }
}

///|
/// Next raw value in `[0, 100003)`.
fn Lcg::next(self : Lcg) -> Int {
  self.state = (self.state * 31 + 17) % 100003
  self.state
}

///|
/// Next value in `[0, bound)`.
fn Lcg::below(self : Lcg, bound : Int) -> Int {
  if bound <= 1 {
    0
  } else {
    self.next() % bound
  }
}

///|
/// Next value in `[low, high]` as a double.
fn Lcg::between(self : Lcg, low : Int, high : Int) -> Double {
  Double::from_int(low + self.below(high - low + 1))
}

///|
/// A small random LP that contains the patterns presolve reacts to.
fn random_model(lcg : Lcg) -> @model.Model {
  let sense = if lcg.below(2) == 0 {
    @model.Sense::Minimize
  } else {
    @model.Sense::Maximize
  }
  let model = @model.Model::new(sense)
  let n = 2 + lcg.below(4)
  let vars : Array[Int] = []
  for j = 0; j < n; j = j + 1 {
    let (lb, ub) = match lcg.below(5) {
      0 => (0.0, @model.infinite_bound)
      1 => (0.0, lcg.between(1, 6))
      2 => (lcg.between(1, 4), @model.infinite_bound)
      3 => {
        // A variable whose bounds already meet: presolve has to eliminate it.
        let value = lcg.between(0, 5)
        (value, value)
      }
      _ => (-@model.infinite_bound, lcg.between(1, 5))
    }
    vars.push(model.add_var("x" + j.to_string(), lb~, ub~))
  }
  let objective : Array[(Int, Double)] = []
  for j = 0; j < n; j = j + 1 {
    let coefficient = lcg.between(-3, 3)
    if coefficient != 0.0 {
      objective.push((vars[j], coefficient))
    }
  }
  model.set_objective(objective)
  let rows = lcg.below(4)
  for i = 0; i < rows; i = i + 1 {
    let terms : Array[(Int, Double)] = []
    for j = 0; j < n; j = j + 1 {
      let coefficient = lcg.between(-3, 3)
      if coefficient != 0.0 {
        terms.push((vars[j], coefficient))
      }
    }
    let rel = match lcg.below(3) {
      0 => @model.Rel::LessEqual
      1 => @model.Rel::GreaterEqual
      _ => @model.Rel::Equal
    }
    model.add_named_constraint(
      terms,
      rel,
      lcg.between(-4, 8),
      "r" + i.to_string(),
    )
  }
  model
}

///|
/// Solving the reduced model and putting the values back has to agree with
/// solving the original model directly, and the result has to be feasible for the
/// original rows and bounds.
test "presolve and the direct solve agree on random models" {
  let lcg = Lcg::new(20260915)
  let mut cases = 0
  let mut compared = 0
  let mut eliminated = 0
  let mut reduction_fired = 0
  for sample = 0; sample < 150; sample = sample + 1 {
    let model = random_model(lcg)
    cases = cases + 1
    let direct = match @simplex.solve_model(model) {
      Ok(result) => result
      Err(reason) => fail("kernel refused a continuous model: " + reason)
    }
    // A run that hit its own limits says nothing about the reduction.
    if direct.status == @simplex.SimplexStatus::IterationLimit ||
      direct.status == @simplex.SimplexStatus::NumericalFailure {
      continue
    }
    let presolved = @presolve.presolve(model)
    let stats = presolved.stats()
    if stats.rows_removed_empty > 0 ||
      stats.rows_removed_redundant > 0 ||
      stats.rows_removed_singleton > 0 ||
      stats.variables_fixed > 0 ||
      stats.columns_removed_empty > 0 ||
      stats.bounds_tightened > 0 {
      reduction_fired = reduction_fired + 1
    }
    match presolved.verdict() {
      @presolve.PresolveVerdict::Infeasible => {
        assert_true(direct.status == @simplex.SimplexStatus::Infeasible)
        compared = compared + 1
      }
      @presolve.PresolveVerdict::Unbounded => {
        assert_true(direct.status == @simplex.SimplexStatus::Unbounded)
        compared = compared + 1
      }
      @presolve.PresolveVerdict::Reduced => {
        compared = compared + 1
        if presolved.reduced().num_vars() == 0 {
          // Everything was eliminated, so the reduction's own answer is the whole
          // answer — and it still has to match the direct solve.
          eliminated = eliminated + 1
          assert_true(direct.status == @simplex.SimplexStatus::Optimal)
          let full = presolved.reconstruct([])
          assert_true(
            @core.approx_eq(
              presolved.objective(0.0),
              direct.objective,
              rel=1.0e-6,
              abs=1.0e-6,
            ),
          )
          assert_true(@presolve.max_row_violation(model, full) <= 1.0e-7)
          assert_true(@presolve.max_bound_violation(model, full) <= 1.0e-7)
        } else {
          let reduced = match @simplex.solve_model(presolved.reduced()) {
            Ok(result) => result
            Err(reason) => fail("kernel refused the reduced model: " + reason)
          }
          assert_eq(reduced.status, direct.status)
          if reduced.status == @simplex.SimplexStatus::Optimal {
            let full = presolved.reconstruct(reduced.values)
            assert_true(
              @core.approx_eq(
                presolved.objective(reduced.objective),
                direct.objective,
                rel=1.0e-6,
                abs=1.0e-6,
              ),
            )
            // The reconstruction has to be a solution of the *original* model.
            assert_true(@presolve.max_row_violation(model, full) <= 1.0e-7)
            assert_true(@presolve.max_bound_violation(model, full) <= 1.0e-7)
          }
        }
      }
    }
  }
  assert_eq(cases, 150)
  assert_eq(compared, 150)
  // The corpus has to actually exercise the reductions, otherwise the agreement
  // above would be vacuous.
  assert_true(reduction_fired > 40)
  assert_true(eliminated > 0)
}
