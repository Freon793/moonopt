///|
/// Outcome of a kernel run.
pub(all) enum SimplexStatus {
  Optimal
  Infeasible
  Unbounded
  IterationLimit
  NumericalFailure
} derive(Debug, Eq)

///|
/// What a kernel run produced.
///
/// `values` is empty unless the status is `Optimal`; `objective` is in the
/// caller's own sense (a maximisation comes back as a maximised value).
pub struct SimplexResult {
  status : SimplexStatus
  values : Array[Double]
  objective : Double
  iterations : Int
  message : String
} derive(Debug)

///|
/// Tuning knobs for a kernel run.
///
/// The tolerances are the ones the algorithm actually consults, so they can be
/// tightened when hunting a numerical failure instead of guessing.
pub(all) struct SimplexOptions {
  max_iterations : Int
  refactorize_every : Int
  feasibility_tolerance : Double
  pivot_tolerance : Double
  reduced_cost_tolerance : Double
  /// Treat integer variables as continuous (the LP relaxation of a model).
  relax_integrality : Bool
} derive(Debug)

///|
/// Defaults: generous iteration budget, refactorization every 500 pivots (the
/// product-form updates are cheap, so the expensive rebuild can wait longer), and
/// tolerances in the range real LP codes use.
pub fn SimplexOptions::default() -> SimplexOptions {
  {
    max_iterations: 20000,
    refactorize_every: 500,
    feasibility_tolerance: 1.0e-7,
    pivot_tolerance: 1.0e-9,
    reduced_cost_tolerance: 1.0e-9,
    relax_integrality: false,
  }
}

///|
/// Options that treat integer variables as continuous: the LP relaxation.
pub fn SimplexOptions::relaxed() -> SimplexOptions {
  let base = SimplexOptions::default()
  {
    max_iterations: base.max_iterations,
    refactorize_every: base.refactorize_every,
    feasibility_tolerance: base.feasibility_tolerance,
    pivot_tolerance: base.pivot_tolerance,
    reduced_cost_tolerance: base.reduced_cost_tolerance,
    relax_integrality: true,
  }
}

///|
/// Options with an explicit iteration cap, keeping the default tolerances.
pub fn SimplexOptions::with_max_iterations(
  max_iterations : Int,
) -> SimplexOptions {
  let base = SimplexOptions::default()
  {
    max_iterations,
    refactorize_every: base.refactorize_every,
    feasibility_tolerance: base.feasibility_tolerance,
    pivot_tolerance: base.pivot_tolerance,
    reduced_cost_tolerance: base.reduced_cost_tolerance,
    relax_integrality: base.relax_integrality,
  }
}
