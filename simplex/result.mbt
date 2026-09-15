///|
/// Outcome of a kernel run.
pub(all) enum SimplexStatus {
  Optimal
  Infeasible
  Unbounded
  IterationLimit
  NumericalFailure
  /// The kernel problem is larger than `SimplexOptions::max_kernel_rows`. The run
  /// stops before allocating, so this is a boundary of the current milestone
  /// rather than a failed attempt at a solve.
  TooLarge
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
///
/// `max_kernel_rows` is a hard ceiling on the size the kernel will attempt. It
/// exists because the basis inverse is dense: `m` rows cost `m²` doubles, so the
/// bound rows this milestone adds for finite upper bounds can turn a model with a
/// few hundred rows into a kernel problem of tens of thousands of rows, and the
/// allocation that follows is not a slow solve but a dead process. A refused run
/// is a fact the caller can act on; a crash is not.
pub(all) struct SimplexOptions {
  max_iterations : Int
  refactorize_every : Int
  feasibility_tolerance : Double
  pivot_tolerance : Double
  reduced_cost_tolerance : Double
  /// Treat integer variables as continuous (the LP relaxation of a model).
  relax_integrality : Bool
  /// Largest kernel row count the run will attempt. Above it the result is
  /// `TooLarge` and nothing is allocated.
  max_kernel_rows : Int
} derive(Debug)

///|
/// Defaults: generous iteration budget, refactorization every 500 pivots (the
/// product-form updates are cheap, so the expensive rebuild can wait longer), and
/// tolerances in the range real LP codes use.
///
/// The row ceiling is chosen so the dense inverse stays at 128 MB (4000² doubles);
/// the cubic refactorization cost is the wall well before that, which is why the
/// sparse factorization is the next thing the kernel needs.
pub fn SimplexOptions::default() -> SimplexOptions {
  {
    max_iterations: 20000,
    refactorize_every: 500,
    feasibility_tolerance: 1.0e-7,
    pivot_tolerance: 1.0e-9,
    reduced_cost_tolerance: 1.0e-9,
    relax_integrality: false,
    max_kernel_rows: 4000,
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
    max_kernel_rows: base.max_kernel_rows,
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
    max_kernel_rows: base.max_kernel_rows,
  }
}

///|
/// Options with an explicit kernel row ceiling. Used by the tests to reach the
/// `TooLarge` path with a model that is small enough to build instantly.
pub fn SimplexOptions::with_max_kernel_rows(
  max_kernel_rows : Int,
) -> SimplexOptions {
  let base = SimplexOptions::default()
  {
    max_iterations: base.max_iterations,
    refactorize_every: base.refactorize_every,
    feasibility_tolerance: base.feasibility_tolerance,
    pivot_tolerance: base.pivot_tolerance,
    reduced_cost_tolerance: base.reduced_cost_tolerance,
    relax_integrality: base.relax_integrality,
    max_kernel_rows,
  }
}
