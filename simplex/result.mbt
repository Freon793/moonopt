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
/// A basis, in the form a later run can start from.
///
/// `basis[row]` is the column that is basic in that row and `at_upper[column]` says
/// whether a non-basic column rests at its upper bound instead of at zero. The row and
/// column counts travel with it because a basis only means anything for the problem it
/// came from: a warm start whose shape does not match is refused and the run falls back
/// to a cold start, rather than pivoting on columns that are not there.
pub struct SimplexBasis {
  nrows : Int
  ncols : Int
  basis : Array[Int]
  at_upper : Array[Bool]
} derive(Debug)

///|
/// What a kernel run produced.
///
/// `values` is empty unless the status is `Optimal` or `Unbounded` (where it is the
/// feasible point a recession direction starts from); `objective` is in the caller's
/// own sense (a maximisation comes back as a maximised value) and is only meaningful
/// for `Optimal`.
///
/// `duals` and `ray` are the run's **certificate** — the numbers an independent
/// checker needs to confirm the verdict instead of taking its word for it:
///
/// - `Optimal`: `values` plus `duals` (row multipliers) is an optimality proof.
/// - `Infeasible`: `duals` is a Farkas ray, which proves no point can satisfy the
///   rows — a measured residual says how infeasible the best attempt was, which is
///   not the same statement.
/// - `Unbounded`: `values` is a feasible point and `ray` a direction that improves
///   the objective forever from it.
///
/// Both arrays are in the convention `verify` documents, are stated against the
/// **model the kernel was handed** (not the kernel's internal normal form), and are
/// empty when the run has nothing to prove.
pub struct SimplexResult {
  status : SimplexStatus
  values : Array[Double]
  objective : Double
  iterations : Int
  message : String
  duals : Array[Double]
  ray : Array[Double]
  /// The basis the run ended on, so a later run over the same columns can start from
  /// it and reoptimize with the dual simplex instead of rebuilding Phase I. Set only
  /// when the run reached a verdict, because only then is the basis a statement about
  /// the model rather than about where the run gave up.
  basis : SimplexBasis?
} derive(Debug)

///|
/// Tuning knobs for a kernel run.
///
/// The tolerances are the ones the algorithm actually consults, so they can be
/// tightened when hunting a numerical failure instead of guessing.
///
/// `max_kernel_rows` is a hard ceiling on the size the kernel will attempt. It
/// exists because the basis inverse used to be dense — `m` rows cost `m²` doubles,
/// and a bound expressed as a row could turn a model with a few hundred rows into a
/// kernel problem of tens of thousands of rows, where the allocation that follows is
/// not a slow solve but a dead process. A refused run is a fact the caller can act
/// on; a crash is not. Bounds are bounds now, so the ceiling mostly guards against
/// runs that cannot be honoured rather than against allocation.
pub(all) struct SimplexOptions {
  max_iterations : Int
  refactorize_every : Int
  feasibility_tolerance : Double
  pivot_tolerance : Double
  /// A pivot smaller than this fraction of the largest entry of the tableau
  /// direction is treated as evidence that the basis inverse is stale. A stale
  /// inverse is how a mathematically valid pivot turns into a singular basis: the
  /// ratio test picks a leaving row from `B⁻¹aⱼ`, and if that entry is really zero
  /// while the computed one is not, the new basis is singular. When this fires the
  /// kernel rebuilds the inverse and redoes the ratio test before pivoting. Zero
  /// disables the check.
  pivot_relative_tolerance : Double
  /// Start with Bland's rule instead of Dantzig's. Bland's rule is deterministic
  /// and cannot cycle, so it walks a different path through a degenerate problem;
  /// the kernel uses it for the recovery attempt after a numerically singular
  /// basis, where a different path is the whole point.
  start_with_bland : Bool
  /// Number of consecutive pivots that may leave the objective (numerically)
  /// unchanged before pricing switches to Bland's rule. Zero disables the switch.
  ///
  /// This is a **fixed** count on purpose, and it is counted in pivots, not in
  /// rows. The rule used to be `2m + 50`, which reads like a generous anti-cycling
  /// guard and is one on small models — but `m` is the kernel's row count, and the
  /// kernel adds one row per finite upper bound, so the real instances here reach
  /// tens of thousands of rows. Against the default cap of 20 000 iterations the
  /// old rule could only ever fire on `m < 9 975`: on a 63 490-row problem it asked
  /// for 127 030 consecutive unimproved pivots, which is a guard that cannot fire
  /// rather than a guard that does not need to. What a stall means does not change
  /// with the row count, so neither should the window.
  ///
  /// The default is deliberately far above the stalls real runs show: measured over
  /// the whole 1000-row manifest, the longest run of unimproved pivots anywhere is
  /// 91 (danoint's Phase I), and fast0507's Phase I — the run this rule was
  /// suspected of breaking — never goes past 6 in 6 000 pivots. Bland's rule is a
  /// termination guarantee, not a fast path: firing it early costs iterations,
  /// never firing it costs an answer.
  stall_window : Int
  /// Number of columns per iteration whose *actual* objective gain is measured
  /// before pivoting; zero keeps plain Dantzig pricing.
  ///
  /// Dantzig prices by the reduced cost alone, which is the improvement *rate* of a
  /// column, not the improvement: a column that covers many uncovered rows has the
  /// largest rate and is often blocked by the first nearly-tight row it meets, so the
  /// step it can take is tiny. Measured on `fast0507`, the column Dantzig picks had
  /// `r = −121.1` with a step of `0.00632` (gain `0.76`) while a sample of 24 columns
  /// already contained one with `r = −6` and a step of `1.0` (gain `6.0`) — the
  /// Dantzig choice was worth a tenth of what was available, and Phase II crawled at
  /// `2e-5` per pivot because of it.
  ///
  /// The gain `|r| · step` is only known after a ratio test, which costs about as
  /// much as the pivot itself, so it is measured for a bounded candidate set instead
  /// of for every column: the Dantzig pick, a few columns that recently showed the
  /// best gains, and a rotating window over the column space. Set this to the total
  /// number of measurements per iteration (`0` disables the whole thing).
  gain_candidates : Int
  /// Relative size of the perturbation added to the right hand side before the run
  /// starts. This is the classical answer to degeneracy, and degeneracy — not
  /// scaling — is what breaks this kernel on the hard instance: noswot's
  /// coefficients span 0.25 to 21, a ratio of 84, so it is a well scaled model whose
  /// trouble is hundreds of basic values sitting at zero. A tie between two rows
  /// whose ratio is `min(0, 0)` gives the ratio test nothing to choose between, and
  /// a long run of such pivots is how a basis drifts into being nearly singular.
  ///
  /// The default is deliberately far below the tolerances the algorithm and its
  /// callers use: big enough to make those ties strict, small enough that no
  /// accuracy claim changes. At `1.0e-9` it fixed noswot but moved objectives by more
  /// than the `1e-9` relative accuracy the test suite asserts; at `1.0e-12` noswot
  /// reaches its optimum in 158 pivots with no recovery attempt and every accuracy
  /// assertion still holds. Zero disables it. The residual self-check always measures
  /// against the **unperturbed** right hand side, so a perturbed run still has to be
  /// feasible for the model the caller wrote.
  degeneracy_perturbation : Double
  /// Largest number of entries the sparse factors of one basis may hold. Fill is
  /// the one quantity a sparse factorization cannot predict from the row count, so
  /// it gets a budget instead of a promise; exceeding it fails the factorization
  /// rather than allocating without limit.
  max_factor_entries : Int
  reduced_cost_tolerance : Double
  /// Treat integer variables as continuous (the LP relaxation of a model).
  relax_integrality : Bool
  /// Largest kernel row count the run will attempt. Above it the result is
  /// `TooLarge` and nothing is allocated.
  ///
  /// This was 4000 while the kernel carried a dense basis inverse, because `m²`
  /// doubles is what an inverse costs a run. With sparse factors the memory is
  /// `O(nnz + fill)` instead, so the ceiling is a coarse guard against a hopeless
  /// run rather than a real limit, and `max_factor_entries` is the sharper bound on
  /// the part that is not knowable in advance — fill.
  ///
  /// What still inflates the kernel row count is a free variable with a finite upper
  /// bound: a difference of two columns has no per-column bound, so that one stays an
  /// explicit row. Finite upper bounds on ordinary variables used to add a row each,
  /// and on `fast0507` that turned 489 rows into 63 490; the pivot count follows the
  /// row count, so it was also the reason the instance did not finish.
  max_kernel_rows : Int
} derive(Debug)

///|
/// Defaults: generous iteration budget, refactorization every 500 pivots (the
/// product-form updates are cheap, so the expensive rebuild can wait longer), and
/// tolerances in the range real LP codes use.
///
/// The row ceiling is a coarse guard, not the memory bound it once was: the basis
/// is factored sparsely now, so a run of tens of thousands of rows costs
/// `O(nnz + fill)` rather than `m²`. `max_factor_entries` is what protects the
/// allocation, and time is what decides in practice.
pub fn SimplexOptions::default() -> SimplexOptions {
  {
    max_iterations: 20000,
    refactorize_every: 500,
    feasibility_tolerance: 1.0e-7,
    pivot_tolerance: 1.0e-9,
    pivot_relative_tolerance: 1.0e-8,
    start_with_bland: false,
    stall_window: 500,
    gain_candidates: 32,
    degeneracy_perturbation: 1.0e-12,
    max_factor_entries: 20000000,
    reduced_cost_tolerance: 1.0e-9,
    relax_integrality: false,
    max_kernel_rows: 200000,
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
    pivot_relative_tolerance: base.pivot_relative_tolerance,
    start_with_bland: base.start_with_bland,
    stall_window: base.stall_window,
    gain_candidates: base.gain_candidates,
    degeneracy_perturbation: base.degeneracy_perturbation,
    max_factor_entries: base.max_factor_entries,
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
    pivot_relative_tolerance: base.pivot_relative_tolerance,
    start_with_bland: base.start_with_bland,
    stall_window: base.stall_window,
    gain_candidates: base.gain_candidates,
    degeneracy_perturbation: base.degeneracy_perturbation,
    max_factor_entries: base.max_factor_entries,
    reduced_cost_tolerance: base.reduced_cost_tolerance,
    relax_integrality: base.relax_integrality,
    max_kernel_rows: base.max_kernel_rows,
  }
}

///|
/// Options with an explicit iteration cap, keeping everything else.
///
/// `with_max_iterations` starts from the defaults, which is the wrong tool when a
/// caller has already chosen a relaxation: this one copies every field, so a
/// bounded run stays the run that was asked for.
pub fn SimplexOptions::limit_iterations(
  self : SimplexOptions,
  max_iterations : Int,
) -> SimplexOptions {
  {
    max_iterations,
    refactorize_every: self.refactorize_every,
    feasibility_tolerance: self.feasibility_tolerance,
    pivot_tolerance: self.pivot_tolerance,
    pivot_relative_tolerance: self.pivot_relative_tolerance,
    start_with_bland: self.start_with_bland,
    stall_window: self.stall_window,
    gain_candidates: self.gain_candidates,
    degeneracy_perturbation: self.degeneracy_perturbation,
    max_factor_entries: self.max_factor_entries,
    reduced_cost_tolerance: self.reduced_cost_tolerance,
    relax_integrality: self.relax_integrality,
    max_kernel_rows: self.max_kernel_rows,
  }
}

///|
/// Options with an explicit stall window. Used by the tests to drive the Bland
/// fallback on a problem small enough to solve instantly: the window is a control
/// on the run, and the run's answer has to be the same whether the fallback fires
/// at the first stall or never.
pub fn SimplexOptions::with_stall_window(stall_window : Int) -> SimplexOptions {
  let base = SimplexOptions::default()
  {
    max_iterations: base.max_iterations,
    refactorize_every: base.refactorize_every,
    feasibility_tolerance: base.feasibility_tolerance,
    pivot_tolerance: base.pivot_tolerance,
    pivot_relative_tolerance: base.pivot_relative_tolerance,
    start_with_bland: base.start_with_bland,
    stall_window,
    gain_candidates: base.gain_candidates,
    degeneracy_perturbation: base.degeneracy_perturbation,
    max_factor_entries: base.max_factor_entries,
    reduced_cost_tolerance: base.reduced_cost_tolerance,
    relax_integrality: base.relax_integrality,
    max_kernel_rows: base.max_kernel_rows,
  }
}

///|
/// Options with an explicit gain-pricing budget. Used by the tests to pin that the
/// pricing rule is a control on the *run*: which column enters changes the path, and
/// the answer has to be the same whether the gain is measured or not.
pub fn SimplexOptions::with_gain_candidates(
  gain_candidates : Int,
) -> SimplexOptions {
  let base = SimplexOptions::default()
  {
    max_iterations: base.max_iterations,
    refactorize_every: base.refactorize_every,
    feasibility_tolerance: base.feasibility_tolerance,
    pivot_tolerance: base.pivot_tolerance,
    pivot_relative_tolerance: base.pivot_relative_tolerance,
    start_with_bland: base.start_with_bland,
    stall_window: base.stall_window,
    gain_candidates,
    degeneracy_perturbation: base.degeneracy_perturbation,
    max_factor_entries: base.max_factor_entries,
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
    pivot_relative_tolerance: base.pivot_relative_tolerance,
    start_with_bland: base.start_with_bland,
    stall_window: base.stall_window,
    gain_candidates: base.gain_candidates,
    degeneracy_perturbation: base.degeneracy_perturbation,
    max_factor_entries: base.max_factor_entries,
    reduced_cost_tolerance: base.reduced_cost_tolerance,
    relax_integrality: base.relax_integrality,
    max_kernel_rows,
  }
}
