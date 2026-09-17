///|
/// The revised simplex iteration.
///
/// Shape of one iteration: compute the duals `y = c_Bᵀ B⁻¹`, price the
/// non-basic columns with `rⱼ = cⱼ − y·Aⱼ` (walking the sparse column), pick an
/// improving column, form `d = B⁻¹ Aⱼ`, run the ratio test, then either pivot or —
/// when the entering variable reaches its own other bound first — flip it without
/// touching the basis. The basis inverse is updated by the product-form row
/// operation and rebuilt from the basis columns every `refactorize_every` pivots.
///
/// The column to enter is chosen by measured gain (`|rⱼ| · step`) when
/// `gain_candidates` is set: the reduced cost alone is a rate, and on the instance
/// this was measured against the largest rates belonged to columns that were blocked
/// at once. The gain needs a ratio test to know, so it is measured for a bounded
/// candidate set per iteration — the Dantzig pick, a pool of recently good columns,
/// and a rotating window over the column space.
///
/// Variables carry both bounds. A non-basic variable sits at one of them, which is
/// why a finite upper bound is a bound here and not an extra row: on the instances
/// this kernel is measured against, turning bounds into rows multiplied the row
/// count by 130 and the pivot count follows the row count. The ratio test therefore
/// has two kinds of limits — a basic variable falling to zero, and a basic variable
/// rising to its own upper bound — plus the entering variable's own range.
///
/// Termination: no column that can improve in the direction its bound allows means
/// optimal; an entering column with no limit at all means unbounded; hitting the
/// iteration cap or a singular refactorization is reported as its own status.
/// When progress stalls the pricing switches to Bland's rule, which guarantees
/// termination on degenerate problems instead of cycling.

///|
/// One product-form update of the basis.
///
/// Pivoting column `j` into row `r` replaces column `r` of the basis, so
/// `B_new = B + (aⱼ − B eᵣ)·eᵣᵀ = B·M` with `M = I + (d − eᵣ)·eᵣᵀ`, where
/// `d = B⁻¹ aⱼ`. Inverting `M` by Sherman–Morrison gives
///
///   `B_new⁻¹ = E · B⁻¹`,   `E = I + w·eᵣᵀ`,   `w = (eᵣ − d)/dᵣ`.
///
/// The sign matters: `(d − eᵣ)/dᵣ` is the negation and inverts the update
/// backwards (the test suite caught exactly that). Storing `w` sparsely is what
/// makes the update cheap: applying `E` costs the nonzeros of `w` rather than the
/// number of rows, so a pivot no longer performs an O(m²) row operation on an
/// explicit inverse.
priv struct Eta {
  row : Int
  indices : Array[Int]
  weights : Array[Double]
}

///|
/// Builds the product-form update from a tableau direction.
fn Eta::from_direction(row : Int, direction : Array[Double]) -> Eta {
  let pivot = direction[row]
  let indices : Array[Int] = []
  let weights : Array[Double] = []
  for i = 0; i < direction.length(); i = i + 1 {
    let weight = if i == row {
      (1.0 - direction[i]) / pivot
    } else {
      -direction[i] / pivot
    }
    // Dropping the negligible entries keeps the updates sparse; they cannot
    // affect the result beyond the pivot tolerance the ratio test already uses.
    if @core.fabs(weight) > 1.0e-12 {
      indices.push(i)
      weights.push(weight)
    }
  }
  { row, indices, weights, }
}

///|
/// `x ← E x = x + u·xᵣ`.
fn Eta::apply(self : Eta, x : Array[Double]) -> Unit {
  let factor = x[self.row]
  if factor != 0.0 {
    for k = 0; k < self.indices.length(); k = k + 1 {
      x[self.indices[k]] = x[self.indices[k]] + self.weights[k] * factor
    }
  }
}

///|
/// `z ← Eᵀ z`, which adds `uᵀz` to component `r`.
fn Eta::apply_transpose(self : Eta, z : Array[Double]) -> Unit {
  let mut acc = 0.0
  for k = 0; k < self.indices.length(); k = k + 1 {
    acc = acc + self.weights[k] * z[self.indices[k]]
  }
  z[self.row] = z[self.row] + acc
}

///|
/// Mutable state of one run.
priv struct State {
  problem : KernelProblem
  options : SimplexOptions
  m : Int
  n : Int
  /// Sparse factors of the basis as of the last refactorization (`P·B₀ = L·U`).
  ///
  /// `None` before the first factorization and after one that failed, and the run
  /// stops in that case instead of pivoting on factors that are not a
  /// factorization. This replaced a dense `m x m` inverse, which is what capped the
  /// problem size: the factors cost `O(nnz(B) + fill)` where the inverse cost `m²`.
  mut lu : BasisLu?
  /// `true` once the basis has been factored successfully.
  mut factorized : Bool
  /// Product-form updates since then: `B⁻¹ = E_k · … · E₁ · B₀⁻¹`.
  mut etas : Array[Eta]
  /// Scratch buffers, allocated once per run: the iteration loop must not
  /// allocate, and the duals and the tableau direction are computed on every
  /// iteration.
  duals_buffer : Array[Double]
  /// Residual of the dual system, used by the refinement in `duals`.
  dual_error_buffer : Array[Double]
  /// Signed deviation and row scale of the direction check, one entry per row.
  direction_error_buffer : Array[Double]
  direction_scale_buffer : Array[Double]
  direction_buffer : Array[Double]
  basic_cost_buffer : Array[Double]
  /// Scratch for the triangular solves. The solvers permute the vector they are
  /// handed, so they need somewhere to do it that is not the caller's buffer.
  solve_scratch : Array[Double]
  /// Scratch for the right hand side with the variables pinned at their upper
  /// bounds moved to the other side of `B x_B = b`.
  rhs_buffer : Array[Double]
  /// Values of the basic variables.
  xb : Array[Double]
  /// `true` for a non-basic column standing at its upper bound instead of at zero.
  /// Every column's lower bound is zero (the model's lower bounds were absorbed
  /// into `var_offset`), so one flag per column decides which end of its range it
  /// occupies; a basic column is never at either end by this bookkeeping — its value
  /// is in `xb`.
  at_upper : Array[Bool]
  /// Direction the entering column moves in this iteration: `+1` when it is at its
  /// lower bound and increases, `-1` when it is at its upper bound and decreases.
  /// The ratio test and the pivot both need it, and it is decided by the pricing
  /// step that chose the column.
  mut enter_sigma : Double
  /// Columns whose measured gain was the best in recent iterations, re-measured
  /// every iteration when `gain_candidates` pricing is on. `-1` is an empty slot.
  gain_pool : Array[Int]
  /// The gain each pool slot showed when it was last measured.
  gain_pool_gains : Array[Double]
  /// Where the rotating window over the column space stands.
  mut gain_cursor : Int
  /// Column that entered when the run concluded the objective is unbounded, and the
  /// direction it moved in (`+1` increasing, `-1` decreasing). `-1` means no such
  /// verdict was reached. Together with the direction buffer still holding `B⁻¹aⱼ`,
  /// this is the recession direction a certificate reports.
  mut ray_column : Int
  mut ray_sigma : Double
  /// The right hand side the run is solved against.
  ///
  /// This is `problem.rhs` plus the degeneracy perturbation, and it is what every
  /// recomputation of the basic values uses. The residual self-check at the end
  /// reads `problem.rhs` instead, so a solution only gets reported if it is
  /// feasible for the model the caller actually wrote rather than for the slightly
  /// perturbed one the algorithm preferred.
  solve_rhs : Array[Double]
  /// `basis[row]` is the column that is basic in that row.
  basis : Array[Int]
  is_basic : Array[Bool]
  cost : Array[Double]
  /// Columns that may not enter (artificials during Phase II).
  forbid : Array[Bool]
  mut iterations : Int
  mut bland : Bool
  mut stalled : Int
  mut best_objective : Double
  mut saw_objective : Bool
}

///|
/// Creates the state with the slack / artificial basis.
fn State::new(problem : KernelProblem, options : SimplexOptions) -> State {
  let m = problem.nrows
  let n = problem.ncols
  let basis : Array[Int] = []
  let is_basic : Array[Bool] = Array::make(n, false)
  for i = 0; i < m; i = i + 1 {
    let column = problem.initial_basis[i]
    basis.push(column)
    is_basic[column] = true
  }
  // Degeneracy perturbation, applied row by row with a deterministic pattern so a
  // run is reproducible and the direction of every nudge is known. The size is
  // chosen well below the feasibility tolerance: it is there to make ties strict,
  // not to change the problem.
  let solve_rhs : Array[Double] = Array::make(m, 0.0)
  for i = 0; i < m; i = i + 1 {
    let value = problem.rhs[i]
    let factor = 1.0 + Double::from_int(i % 11) * 0.037
    solve_rhs[i] = value +
      options.degeneracy_perturbation * (1.0 + @core.fabs(value)) * factor
  }
  let state = {
    problem,
    options,
    m,
    n,
    lu: None,
    factorized: false,
    etas: [],
    duals_buffer: Array::make(m, 0.0),
    dual_error_buffer: Array::make(m, 0.0),
    direction_error_buffer: Array::make(m, 0.0),
    direction_scale_buffer: Array::make(m, 0.0),
    direction_buffer: Array::make(m, 0.0),
    basic_cost_buffer: Array::make(m, 0.0),
    solve_scratch: Array::make(m, 0.0),
    rhs_buffer: Array::make(m, 0.0),
    xb: solve_rhs.copy(),
    at_upper: Array::make(n, false),
    enter_sigma: 1.0,
    gain_pool: Array::make(gain_pool_size, -1),
    gain_pool_gains: Array::make(gain_pool_size, 0.0),
    gain_cursor: 0,
    ray_column: -1,
    ray_sigma: 1.0,
    solve_rhs,
    basis,
    is_basic,
    cost: problem.cost.copy(),
    forbid: problem.is_artificial.copy(),
    iterations: 0,
    bland: options.start_with_bland,
    stalled: 0,
    best_objective: 0.0,
    saw_objective: false,
  }
  // The starting basis is the slacks and artificials, i.e. a permutation of the
  // identity, so this always succeeds; the flag still records the outcome because
  // everything afterwards depends on it being true.
  state.factorized = state.refactorize()
  state
}

///|
/// Creates the state on a basis handed in by a previous run, for reoptimization.
///
/// The basis is trusted only as far as its shape: the caller has to have come from a
/// kernel problem with the same number of rows and columns, and the entry checks
/// nothing else. Whether it is *dual feasible* — the property the dual simplex needs
/// — is `dual_feasible`'s question, asked by the caller before the run starts,
/// because a basis that is not dual feasible belongs in the cold path rather than in
/// the middle of this one.
///
/// The basic values are recomputed from the right hand side rather than carried over:
/// a bound change is exactly what a warm start is for, and it changes the values.
fn State::new_with_basis(
  problem : KernelProblem,
  options : SimplexOptions,
  basis : SimplexBasis,
) -> State {
  let state = State::new(problem, options)
  // The starting state marks the cold basis (slacks and artificials) as basic, and every
  // one of those flags has to come off before the warm basis goes in. Leaving them on
  // makes columns that are *not* in this basis invisible to pricing and to the dual
  // feasibility check — the two places that decide whether a run may call its answer
  // optimal — and the run then reports a point no certificate can justify. (A warm start
  // on dcmulti did exactly that before this line existed: 36 pivots, "optimal", and a
  // verifier refusal on the duals.)
  for j = 0; j < state.n; j = j + 1 {
    state.is_basic[j] = false
    state.at_upper[j] = false
  }
  for i = 0; i < state.m; i = i + 1 {
    let column = basis.basis[i]
    state.basis[i] = column
    state.is_basic[column] = true
  }
  for j = 0; j < state.n; j = j + 1 {
    state.at_upper[j] = basis.at_upper[j]
  }
  // A column that is basic is not at a bound; the flag only means something for the
  // non-basic ones and the two arrays come from different runs.
  for i = 0; i < state.m; i = i + 1 {
    state.at_upper[state.basis[i]] = false
  }
  if state.refactorize() {
    // The factorized path recomputes the basic values from the (possibly re-bounded)
    // right hand side, which is the whole reason a warm start is cheap.
  } else {
    state.factorized = false
  }
  state
}

///|
/// Phase I: minimise the sum of the artificial variables.
fn State::set_phase1(self : State) -> Unit {
  for j = 0; j < self.n; j = j + 1 {
    self.cost[j] = if self.problem.is_artificial[j] { 1.0 } else { 0.0 }
    self.forbid[j] = false
  }
}

///|
/// Phase II: the real objective, with artificials barred from entering. An
/// artificial that is still basic holds value zero (its row was redundant), so
/// leaving it in the basis keeps the solution valid.
fn State::set_phase2(self : State) -> Unit {
  for j = 0; j < self.n; j = j + 1 {
    self.cost[j] = self.problem.cost[j]
    self.forbid[j] = self.problem.is_artificial[j]
  }
}

///|
/// Total of the artificial variables in the current basis (their nonbasic value
/// is zero).
fn State::artificial_sum(self : State) -> Double {
  let acc = @core.CompensatedSum::new()
  for i = 0; i < self.m; i = i + 1 {
    if self.problem.is_artificial[self.basis[i]] {
      acc.add(self.xb[i])
    }
  }
  acc.value()
}

///|
/// Current kernel objective value `c_B·x_B` (nonbasic variables are zero).
fn State::kernel_objective(self : State) -> Double {
  let acc = @core.CompensatedSum::new()
  for i = 0; i < self.m; i = i + 1 {
    acc.add(self.cost[self.basis[i]] * self.xb[i])
  }
  acc.value()
}

///|
/// Duals `y = c_Bᵀ B⁻¹`, computed by a backward solve.
///
/// The product-form updates are applied to `c_B` in reverse chronological order
/// (each costs the nonzeros of its update), and the base transpose is applied
/// through the rows of the base inverse, so only the nonzeros of the running
/// vector cost a pass over `m`.
///
/// The triangular solves leave a small *residual* rather than a small *error*, and
/// those are not the same statement: on an ill-conditioned basis the two differ by
/// the condition number. A branch and bound node of `noswot` reached a basis where
/// the computed multipliers missed `Bᵀy = c_B` by `3.7e-7`, five orders of magnitude
/// above the round-off every other node there showed — and since the true multiplier
/// was zero, the computed one came out negative, which is not a multiplier at all:
/// the certificate's sign condition failed and `verify` refused an optimum that was
/// real. Everything this kernel decides from a dual — the reduced costs, the pricing,
/// whether a column can still improve the objective — was decided from that vector,
/// so the fix belongs here and not at the certificate boundary: one step of iterative
/// refinement on the residual (see `refine_duals`) took that node's residual from
/// `3.7e-7` to `4e-13`.
fn State::duals(self : State) -> Array[Double] {
  let y = self.duals_buffer
  for k = 0; k < self.m; k = k + 1 {
    y[k] = self.cost[self.basis[k]]
  }
  let mut e = self.etas.length() - 1
  while e >= 0 {
    self.etas[e].apply_transpose(y)
    e = e - 1
  }
  // `B₀⁻ᵀ` on what is left, through the sparse factors rather than a dense table.
  match self.lu {
    Some(lu) => lu.solve_transpose_into(y, self.basic_cost_buffer)
    None => ()
  }
  self.refine_duals(y)
  y
}

///|
/// One step of iterative refinement on `Bᵀy = c_B`, in place.
///
/// The residual `r = c_B − Bᵀy` is measured on the basis the run is standing on —
/// `m` columns walked once, which is what the columns cost, not what the factors do —
/// and the same product-form solve that produced `y` is applied to `r` instead of to
/// `c_B`: `Δ = (Bᵀ)⁻¹r`, `y ← y + Δ`. The solve is the same one, so the step costs one
/// more triangular pass, and it converges because the factors are a backward-stable
/// approximation of the basis: an error of order `ε·κ` becomes one of order `(ε·κ)²`.
///
/// It is applied unconditionally rather than behind a threshold: an unconditional
/// step is a guarantee about every dual the kernel reports, and a threshold would be
/// one more number to justify — the measurement that would set it is the residual this
/// refinement removes anyway.
fn State::refine_duals(self : State, y : Array[Double]) -> Unit {
  let error = self.dual_error_buffer
  let pointers = self.problem.matrix.col_pointers()
  let rows = self.problem.matrix.row_indices()
  let values = self.problem.matrix.values_view()
  for r = 0; r < self.m; r = r + 1 {
    let column = self.basis[r]
    let mut acc = 0.0
    let mut k = pointers[column]
    let end = pointers[column + 1]
    while k < end {
      acc = acc + y[rows[k]] * values[k]
      k = k + 1
    }
    error[r] = self.cost[column] - acc
  }
  let mut e = self.etas.length() - 1
  while e >= 0 {
    self.etas[e].apply_transpose(error)
    e = e - 1
  }
  match self.lu {
    Some(lu) => lu.solve_transpose_into(error, self.solve_scratch)
    None => ()
  }
  for k = 0; k < self.m; k = k + 1 {
    y[k] = y[k] + error[k]
  }
}

///|
/// Scaled residual of the direction solve: how far `d = B⁻¹aⱼ` is from satisfying the
/// basis equation `A·d = aⱼ`, one pass over the basis columns.
///
/// An exact inverse makes this zero, so whatever is left is the error of the computed
/// direction, judged row by row against the numbers it came from —
/// `|aᵢⱼ − (Ad)ᵢ| / (1 + |aᵢⱼ| + Σₖ |Aᵢₖdₖ|)`, the convention the feasibility residual
/// uses. A direction that misses its own column means the factors have stopped
/// describing the basis, and every decision taken from it is then unfounded: on a
/// branch and bound node of `noswot` one such direction was off by `20` against column
/// entries of `20`, so the pivot moved a basic value `20` away from feasibility, and
/// the run went on to report that node's bounded relaxation as unbounded. The existing
/// pivot-stability check reads the size of the pivot element, which is a proxy for this
/// question; this is the question.
fn State::direction_residual(
  self : State,
  column : Int,
  d : Array[Double],
) -> Double {
  let error = self.direction_error_buffer
  let scale = self.direction_scale_buffer
  for i = 0; i < self.m; i = i + 1 {
    error[i] = 0.0
    scale[i] = 1.0
  }
  let pointers = self.problem.matrix.col_pointers()
  let rows = self.problem.matrix.row_indices()
  let values = self.problem.matrix.values_view()
  let mut k = pointers[column]
  let end = pointers[column + 1]
  while k < end {
    let row = rows[k]
    error[row] = error[row] + values[k]
    scale[row] = scale[row] + @core.fabs(values[k])
    k = k + 1
  }
  for j = 0; j < self.m; j = j + 1 {
    let weight = d[j]
    if weight != 0.0 {
      let basic = self.basis[j]
      let mut p = pointers[basic]
      let column_end = pointers[basic + 1]
      while p < column_end {
        let row = rows[p]
        let term = weight * values[p]
        error[row] = error[row] - term
        scale[row] = scale[row] + @core.fabs(term)
        p = p + 1
      }
    }
  }
  let mut worst = 0.0
  for i = 0; i < self.m; i = i + 1 {
    let scaled = @core.fabs(error[i]) / scale[i]
    if scaled > worst {
      worst = scaled
    }
  }
  worst
}

///|
/// Reduced cost of a column: `cⱼ − y·Aⱼ`, walking only that column's nonzeros.
/// The accumulation is a plain sum rather than a compensated one: a column of an
/// LP holds a handful of entries, and paying for an accumulator object per column
/// would cost more than it saves. The compensated path is used where it matters,
/// on the long accumulations (residuals, objective values).
fn State::reduced_cost(
  self : State,
  column : Int,
  duals : Array[Double],
  pointers : ArrayView[Int],
  rows : ArrayView[Int],
  values : ArrayView[Double],
) -> Double {
  let mut acc = 0.0
  let mut k = pointers[column]
  let end = pointers[column + 1]
  while k < end {
    acc = acc + duals[rows[k]] * values[k]
    k = k + 1
  }
  self.cost[column] - acc
}

///|
/// Picks the entering column and the direction it moves in.
///
/// Dantzig (largest improvement rate `|rⱼ|`) by default, Bland (smallest index)
/// when the run has stalled — Bland's rule is what makes termination certain on
/// degenerate problems, at the price of more iterations.
///
/// Which direction a column can move in is decided by the bound it sits at: a
/// non-basic variable at its lower bound may increase, and that is worth doing when
/// `rⱼ < 0`; one at its upper bound may decrease, which is worth doing when
/// `rⱼ > 0`. A column whose range is empty cannot move either way and is not a
/// candidate at all — pricing it would produce a step of zero and no progress.
///
/// Pricing walks the raw CSC arrays: an earlier version asked for a freshly
/// allocated `(row, value)` list per column, which dominated the runtime on the
/// larger instances (a few million short-lived arrays for one solve).
fn State::choose_entering(self : State, duals : Array[Double]) -> Int {
  let tolerance = self.options.reduced_cost_tolerance
  let upper = self.problem.upper
  let pointers = self.problem.matrix.col_pointers()
  let rows = self.problem.matrix.row_indices()
  let values = self.problem.matrix.values_view()
  let mut best = -1
  let mut best_magnitude = 0.0
  for j = 0; j < self.n; j = j + 1 {
    if self.is_basic[j] || self.forbid[j] {
      continue
    }
    let cap = upper[j]
    if kernel_has_upper(cap) && cap <= 0.0 {
      continue
    }
    let reduced = self.reduced_cost(j, duals, pointers, rows, values)
    // The improvement rate of the direction this column is allowed to move in.
    let magnitude = if self.at_upper[j] { reduced } else { -reduced }
    if magnitude > tolerance {
      if self.bland {
        self.enter_sigma = if self.at_upper[j] { -1.0 } else { 1.0 }
        return j
      }
      if best < 0 || magnitude > best_magnitude {
        best = j
        best_magnitude = magnitude
      }
    }
  }
  if best >= 0 {
    self.enter_sigma = if self.at_upper[best] { -1.0 } else { 1.0 }
  }
  best
}

///|
/// `d = B⁻¹ Aⱼ` for the entering column: a forward solve.
///
/// The base inverse is applied by walking the nonzeros of the column (so the cost
/// is `m` per nonzero, not a full matrix-vector product), and then the
/// product-form updates are applied in chronological order.
///
/// Returns the shared direction buffer: the caller must use it before the next
/// solve, which is exactly what the iteration does (ratio test, then pivot).
fn State::direction(self : State, column : Int) -> Array[Double] {
  let d = self.direction_buffer
  for i = 0; i < self.m; i = i + 1 {
    d[i] = 0.0
  }
  let pointers = self.problem.matrix.col_pointers()
  let rows = self.problem.matrix.row_indices()
  let values = self.problem.matrix.values_view()
  let mut k = pointers[column]
  let end = pointers[column + 1]
  while k < end {
    let row = rows[k]
    d[row] = d[row] + values[k]
    k = k + 1
  }
  // `d = B₀⁻¹ aⱼ` through the sparse factors: scatter the column, one triangular
  // solve forward and one backward. The dense version of this stepped over every
  // row for every nonzero of the column, which is where the old cost lived.
  match self.lu {
    Some(lu) => lu.solve_into(d, self.solve_scratch)
    None => ()
  }
  for e = 0; e < self.etas.length(); e = e + 1 {
    self.etas[e].apply(d)
  }
  d
}

///|
/// Row `r` of `B⁻¹`, i.e. `eᵣᵀB⁻¹`, used as the weight vector that turns a
/// tableau entry into a sparse dot product.
fn State::inverse_row(self : State, row : Int) -> Array[Double] {
  let z : Array[Double] = Array::make(self.m, 0.0)
  z[row] = 1.0
  let mut e = self.etas.length() - 1
  while e >= 0 {
    self.etas[e].apply_transpose(z)
    e = e - 1
  }
  // `eᵣᵀB₀⁻¹` is the transposed solve `B₀⁻ᵀ eᵣ`. This runs during artificial
  // eviction only, so the two allocations are not in the hot loop.
  let scratch : Array[Double] = Array::make(self.m, 0.0)
  match self.lu {
    Some(lu) => lu.solve_transpose_into(z, scratch)
    None => ()
  }
  z
}

///|
/// Tableau entry `(B⁻¹ Aⱼ)ᵣ` of one column, without forming the whole direction.
///
/// Uses row `r` of the basis inverse as a weight vector, so the cost is the
/// column's nonzero count instead of a matrix-vector product. This is what makes
/// the artificial eviction below affordable: it would otherwise build a full
/// direction for every candidate column it looks at.
fn State::tableau_entry(
  self : State,
  column : Int,
  weights : Array[Double],
) -> Double {
  let pointers = self.problem.matrix.col_pointers()
  let rows = self.problem.matrix.row_indices()
  let values = self.problem.matrix.values_view()
  let mut acc = 0.0
  let mut k = pointers[column]
  let end = pointers[column + 1]
  while k < end {
    acc = acc + weights[rows[k]] * values[k]
    k = k + 1
  }
  acc
}

///|
/// Drives artificial variables out of the basis.
///
/// Called between the phases. For every row whose basic variable is artificial,
/// a non-artificial column with a non-zero tableau entry in that row is pivoted
/// in; the artificial sits at zero, so the pivot leaves every other basic value
/// untouched. When no such column exists the row is redundant and the artificial
/// cannot move either — every eligible direction has a zero entry in that row —
/// so it is safe to leave it in place.
fn State::drive_artificials_out(self : State) -> Unit {
  let tolerance = self.options.pivot_tolerance
  for r = 0; r < self.m; r = r + 1 {
    if !self.problem.is_artificial[self.basis[r]] {
      continue
    }
    // Row r of B⁻¹ is the weight vector: `eᵣᵀ B⁻¹ Aⱼ` is the entry we need.
    let weights = self.inverse_row(r)
    for j = 0; j < self.n; j = j + 1 {
      if self.is_basic[j] || self.problem.is_artificial[j] {
        continue
      }
      // The pivot below is degenerate — the artificial sits at zero, so the
      // entering column takes value zero. That is only consistent with a column
      // resting at its lower bound; one standing at its upper bound would have to
      // jump to zero to enter, which this step does not do.
      if self.at_upper[j] {
        continue
      }
      let entry = self.tableau_entry(j, weights)
      if @core.fabs(entry) > tolerance {
        // Rebuild the full direction only for the column that will be pivoted. The
        // step is zero by construction: the artificial sits at zero and the entering
        // column takes its place there. Letting the pivot work the step out from the
        // direction instead is how an artificial — a column with no upper bound —
        // gets handed a step the size of that sentinel.
        self.enter_sigma = 1.0
        let d = self.direction(j)
        self.pivot(r, j, d, 0.0)
        break
      }
    }
  }
}

///|
/// Where one iteration's step is limited.
priv struct StepLimit {
  /// Row that limits the step, or `-1` when no basic variable does.
  row : Int
  /// Movement of the entering variable, in its own units and always `>= 0`. It is
  /// the flip distance when `flip` is set; a pivot recomputes its own step from the
  /// leaving row, which the band may have moved off the strict minimum.
  step : Double
  /// `true` when the entering variable reaches its other bound before any row
  /// stops it. Then the basis does not change: the variable flips from one end of
  /// its range to the other.
  flip : Bool
  /// `true` when neither a row nor the entering variable's own range limits the
  /// step, i.e. the objective is unbounded along this direction.
  unbounded : Bool
}

///|
/// Bounded-variable ratio test (Harris, two passes).
///
/// `d = B⁻¹ Aⱼ` and the entering variable moves by `step` in the direction its
/// bound allows, so basic value `i` changes by `−step · σ · dᵢ` where `σ` is the
/// direction of the step. Two kinds of row limit follow from that, and both are
/// needed once variables have two bounds:
///
/// - the rate `σ·dᵢ` is positive: basic value `i` falls, and it may not go below
///   zero — ratio `xbᵢ / (σ·dᵢ)`;
/// - the rate is negative: basic value `i` rises, and it may not go above its own
///   upper bound — ratio `(uᵢ − xbᵢ) / (−σ·dᵢ)`.
///
/// Pass one takes the strict minimum over both kinds and over the entering
/// variable's own range. If the entering variable's range is smaller than the row
/// minimum by more than the band, the step is a **flip**: no basis change, the
/// variable goes from one bound to the other, and every basic value moves along.
/// Otherwise pass two picks, among the rows whose ratio is within a relative band
/// of the minimum, the one with the largest pivot element — that second pass is
/// what keeps the basis well-conditioned.
///
/// The band is deliberately relative (`1e-9·|ratio|`) rather than the feasibility
/// tolerance. A band of `1e-7·(1+|ratio|)` lets the step overshoot by `1e-7·ratio`,
/// and that overshoot is multiplied by the pivot element when the basic values are
/// updated: with ratios and pivots around 1e5, a "tiny" relative allowance became
/// an absolute violation of tens on MIPLIB's noswot.
fn State::ratio_test(
  self : State,
  column : Int,
  d : Array[Double],
) -> StepLimit {
  let tolerance = self.options.pivot_tolerance
  let feasibility = self.options.feasibility_tolerance
  let sigma = self.enter_sigma
  let upper = self.problem.upper
  // A basic variable that drifted slightly negative counts as zero, and it may
  // not limit the step: letting it do so takes the step backwards and leaves a
  // basis that is infeasible by far more than the round-off it started from.
  for i = 0; i < self.m; i = i + 1 {
    if self.xb[i] < 0.0 && self.xb[i] > -feasibility {
      self.xb[i] = 0.0
    }
  }
  let mut ratio_min = 0.0
  let mut strict_row = -1
  for i = 0; i < self.m; i = i + 1 {
    let rate = sigma * d[i]
    if rate > tolerance {
      // A value at or below zero allows no further fall: the limit is zero, not the
      // negative ratio `xb / rate` would give. Letting a negative ratio into the
      // strict comparison is how the step comes out backwards — `ratio_min` starts at
      // zero, so the first negative candidate wins — and a backwards step moves every
      // basic value away from its bounds at once.
      let ratio = if self.xb[i] > 0.0 { self.xb[i] / rate } else { 0.0 }
      if strict_row < 0 || ratio < ratio_min {
        ratio_min = ratio
        strict_row = i
      }
    } else if rate < -tolerance {
      let cap = upper[self.basis[i]]
      if kernel_has_upper(cap) {
        // Mirror image: a value already at or above its own cap allows no further rise.
        let ratio = if self.xb[i] < cap {
          (cap - self.xb[i]) / -rate
        } else {
          0.0
        }
        if strict_row < 0 || ratio < ratio_min {
          ratio_min = ratio
          strict_row = i
        }
      }
    }
  }
  // The entering variable's own range: from the end it sits at to the other one,
  // which is `uⱼ` in both directions because its lower bound is zero.
  let own_cap = upper[column]
  let own_ratio = if kernel_has_upper(own_cap) { own_cap } else { 1.0e30 }
  let row_ratio = if strict_row < 0 { 1.0e30 } else { ratio_min }
  if own_ratio >= 1.0e30 && row_ratio >= 1.0e30 {
    return { row: -1, step: 0.0, flip: false, unbounded: true, }
  }
  let band = 1.0e-9 * @core.fabs(row_ratio) + tolerance
  if own_ratio < row_ratio - band {
    return { row: -1, step: own_ratio, flip: true, unbounded: false, }
  }
  let leave = self.choose_leaving_row(sigma, d, row_ratio, band, strict_row)
  if leave.0 < 0 {
    return { row: -1, step: 0.0, flip: false, unbounded: true, }
  }
  { row: leave.0, step: leave.1, flip: false, unbounded: false, }
}

///|
/// Harris's second pass: among the rows within the band of the strict minimum
/// ratio, pick the one whose pivot element is largest; ties go to the smallest
/// basis index when Bland's rule is active. Falls back to the strict row when the
/// preferred one would overshoot feasibility.
///
/// Returns the leaving row and the step that follows from it, or `(-1, 0.0)` when
/// no row can limit the step. The step belongs to the return value because the row
/// it comes from decides it: a basic variable stops the step by falling to zero or
/// by rising to its own upper bound, and the two read different numbers off the
/// same row. A caller that recomputed it from the row alone would have to guess
/// which of the two it was looking at.
fn State::choose_leaving_row(
  self : State,
  sigma : Double,
  d : Array[Double],
  row_ratio : Double,
  band : Double,
  strict_row : Int,
) -> (Int, Double) {
  let tolerance = self.options.pivot_tolerance
  let feasibility = self.options.feasibility_tolerance
  let upper = self.problem.upper
  let relaxed = row_ratio + band
  let mut leave = -1
  let mut best_pivot = 0.0
  let mut leave_rate = 0.0
  for i = 0; i < self.m; i = i + 1 {
    let rate = sigma * d[i]
    let mut ratio = 0.0
    let mut limits = false
    if rate > tolerance {
      // Same clamping as the strict pass: negative ratios are not step limits.
      ratio = if self.xb[i] > 0.0 { self.xb[i] / rate } else { 0.0 }
      limits = true
    } else if rate < -tolerance {
      let cap = upper[self.basis[i]]
      if kernel_has_upper(cap) {
        ratio = if self.xb[i] < cap { (cap - self.xb[i]) / -rate } else { 0.0 }
        limits = true
      }
    }
    if limits && ratio <= relaxed {
      let better = if leave < 0 {
        true
      } else if self.bland {
        self.basis[i] < self.basis[leave]
      } else {
        @core.fabs(rate) > best_pivot
      }
      if better {
        leave = i
        best_pivot = @core.fabs(rate)
        leave_rate = rate
      }
    }
  }
  // Harris's preference is only safe if the step it implies keeps every basic
  // value feasible. Simulating the step costs one pass over the rows, and it is
  // what stops a "well conditioned" pivot from writing off feasibility: the
  // overshoot of the band is multiplied by the pivot element, so with ratios and
  // rows in the 1e5 range a relative allowance of 1e-9 still moved a basic value
  // by tens on MIPLIB's noswot.
  //
  // The allowance is read off the value the step *produces*, not off the value it
  // started from. Judging a basic value that lands near zero against the size it
  // used to have is how a `-7.7e-7` gets past a tolerance of `1e-7`: the variable
  // ends next to its bound, where the only number that means anything is its own,
  // and that is the number both the clamping below and `verify` read it against.
  if strict_row < 0 {
    return (-1, 0.0)
  }
  if leave < 0 || leave == strict_row {
    return (strict_row, self.row_step(strict_row, sigma * d[strict_row]))
  }
  let chosen = self.row_step(leave, leave_rate)
  for i = 0; i < self.m; i = i + 1 {
    if i != leave {
      let candidate = self.xb[i] - chosen * sigma * d[i]
      if candidate < -feasibility * (1.0 + @core.fabs(candidate)) {
        return (strict_row, self.row_step(strict_row, sigma * d[strict_row]))
      }
      let cap = upper[self.basis[i]]
      if kernel_has_upper(cap) &&
        candidate > cap + feasibility * (1.0 + @core.fabs(cap)) {
        return (strict_row, self.row_step(strict_row, sigma * d[strict_row]))
      }
    }
  }
  (leave, chosen)
}

///|
/// How far the entering variable travels before row `row` stops it, given the rate
/// at which that row's basic value moves.
///
/// A positive rate means the basic value falls and hits zero; a negative rate means
/// it rises and hits its own upper bound. Reading `xb / rate` in both cases is how a
/// step of the wrong sign gets into the state, and with a bound that is the
/// infinite sentinel the "rise" reading is not a step at all.
fn State::row_step(self : State, row : Int, rate : Double) -> Double {
  let step = if rate > 0.0 {
    self.xb[row] / rate
  } else {
    (self.problem.upper[self.basis[row]] - self.xb[row]) / -rate
  }
  // A step is a distance travelled in the direction the entering column moves, so it
  // can never be negative. A basic value marginally outside its bounds would otherwise
  // read as a negative distance here and be applied as a backwards step.
  if step > 0.0 {
    step
  } else {
    0.0
  }
}

///|
/// Updates the basis inverse and the basic values for a pivot on `(row, column)`.
///
/// `step` is how far the entering variable travels, in the direction its bound
/// allows, and it comes from the ratio test's chosen row. The leaving variable lands
/// on one of its own bounds — zero when its rate was positive, its upper bound when
/// the rate was negative — and the end it lands on is what decides which end it
/// occupies as a non-basic variable. Which of the two it is, is read off the value it
/// came to rest on rather than off the rate: a degenerate pivot rests where it
/// already was, and that is a bound too.
fn State::pivot(
  self : State,
  row : Int,
  column : Int,
  d : Array[Double],
  step : Double,
) -> Unit {
  let sigma = self.enter_sigma
  let rate = sigma * d[row]
  let leaving = self.basis[row]
  let cap = self.problem.upper[leaving]
  // Basic values: the entering variable takes the step, the others move along d.
  for i = 0; i < self.m; i = i + 1 {
    if i != row {
      self.xb[i] = self.xb[i] - step * sigma * d[i]
      // Absorb the drift the ratio test always leaves behind.
      if self.xb[i] < 0.0 && self.xb[i] > -self.options.feasibility_tolerance {
        self.xb[i] = 0.0
      }
    }
  }
  let resting = self.xb[row] - step * rate
  self.xb[row] = if sigma > 0.0 {
    step
  } else {
    self.problem.upper[column] - step
  }
  // Product-form update: the pivot becomes one sparse eta instead of an O(m²)
  // row operation on an explicit inverse.
  self.etas.push(Eta::from_direction(row, d))
  self.is_basic[leaving] = false
  self.at_upper[leaving] = kernel_has_upper(cap) && resting > 0.5 * cap
  self.basis[row] = column
  self.is_basic[column] = true
  self.at_upper[column] = false
  self.iterations = self.iterations + 1
}

///|
/// Moves the entering variable from one bound to the other without changing the
/// basis.
///
/// This is what `x ≤ 1` on a 0/1 column costs when it is a bound rather than a
/// row: the variable travels its whole range in one step, every basic value moves
/// along, and the basis — and therefore the factorization — is untouched. It is
/// also why bounds are worth having: as rows, the same move needed a pivot, and on
/// an instance where every column is bounded those pivots are the run.
fn State::apply_flip(
  self : State,
  column : Int,
  d : Array[Double],
  step : Double,
) -> Unit {
  let sigma = self.enter_sigma
  for i = 0; i < self.m; i = i + 1 {
    self.xb[i] = self.xb[i] - step * sigma * d[i]
    if self.xb[i] < 0.0 && self.xb[i] > -self.options.feasibility_tolerance {
      self.xb[i] = 0.0
    }
  }
  self.at_upper[column] = !self.at_upper[column]
  self.iterations = self.iterations + 1
}

///|
/// Rebuilds the basis factors from the basis columns and recomputes the basic
/// values.
///
/// Returns `false` when the basis has no usable pivot, which means the run has to
/// stop rather than continue on garbage. The threshold is relative to the largest
/// entry left in the column being eliminated: an absolute one would refuse a basis
/// whose columns are simply small.
fn State::refactorize(self : State) -> Bool {
  let m = self.m
  let columns : Array[Array[(Int, Double)]] = []
  for i = 0; i < m; i = i + 1 {
    columns.push(self.problem.matrix.column(self.basis[i]))
  }
  match
    factorize_basis(
      columns,
      m,
      self.options.pivot_tolerance,
      self.options.max_factor_entries,
    ) {
    None => {
      self.lu = None
      false
    }
    Some(factors) => {
      self.lu = Some(factors)
      self.factorized = true
      // The updates are folded into the new base, which is the whole point of
      // refactorizing: the eta list stays short and the drift gets discarded.
      self.etas = []
      // Basic values of the fresh factors, from the right hand side the run is
      // solved against — with the variables pinned at their upper bounds moved
      // across the equation, because `B x_B = b` only holds for the non-basic
      // variables that sit at zero:
      //
      //   B x_B = b − Σ_{j non-basic at its upper bound} uⱼ · Aⱼ
      for i = 0; i < m; i = i + 1 {
        self.rhs_buffer[i] = self.solve_rhs[i]
      }
      let pointers = self.problem.matrix.col_pointers()
      let rows = self.problem.matrix.row_indices()
      let coefficients = self.problem.matrix.values_view()
      let upper = self.problem.upper
      for j = 0; j < self.n; j = j + 1 {
        if self.is_basic[j] || !self.at_upper[j] {
          continue
        }
        let value = upper[j]
        if value == 0.0 {
          continue
        }
        let mut k = pointers[j]
        let end = pointers[j + 1]
        while k < end {
          self.rhs_buffer[rows[k]] = self.rhs_buffer[rows[k]] -
            value * coefficients[k]
          k = k + 1
        }
      }
      for i = 0; i < m; i = i + 1 {
        self.xb[i] = self.rhs_buffer[i]
      }
      match self.lu {
        Some(lu) => lu.solve_into(self.xb, self.solve_scratch)
        None => ()
      }
      true
    }
  }
}

///|
/// `true` when the pivot the ratio test chose is negligible compared with the
/// largest entry of the direction, which means the direction is not accurate
/// enough to trust that pivot.
///
/// The comparison is relative on purpose. An absolute threshold fires on
/// well-scaled small problems and stays silent on badly scaled large ones, which
/// is exactly backwards: the pivot has to be judged against the scale of the
/// direction it came from.
fn State::weak_pivot(self : State, d : Array[Double], leaving : Int) -> Bool {
  let tolerance = self.options.pivot_relative_tolerance
  if tolerance <= 0.0 {
    return false
  }
  let mut scale = 0.0
  for i = 0; i < self.m; i = i + 1 {
    let magnitude = @core.fabs(d[i])
    if magnitude > scale {
      scale = magnitude
    }
  }
  if scale <= 0.0 {
    return false
  }
  @core.fabs(d[leaving]) < tolerance * scale
}

///|
/// How many columns the gain-priced rule remembers between iterations.
let gain_pool_size : Int = 4

///|
/// The actual gain of pivoting on `column`: `|r| · step`, where `step` is what the
/// ratio test allows. A negative value means the column cannot move in the direction
/// its bound allows.
///
/// This is the quantity Dantzig pricing approximates by the reduced cost alone, and
/// the two differ by the whole step. Measuring it costs one direction and one ratio
/// test — the same work a pivot does — so it is measured for a bounded candidate set
/// per iteration rather than for every column.
///
/// Uses the shared direction buffer, so the caller must not expect the direction it
/// had before the call: the iteration recomputes its pivot's direction afterwards.
fn State::candidate_gain(
  self : State,
  column : Int,
  duals : Array[Double],
  pointers : ArrayView[Int],
  rows : ArrayView[Int],
  values : ArrayView[Double],
) -> Double {
  let cap = self.problem.upper[column]
  if kernel_has_upper(cap) && cap <= 0.0 {
    return -1.0
  }
  let at_upper = self.at_upper[column]
  let reduced = self.reduced_cost(column, duals, pointers, rows, values)
  let magnitude = if at_upper { reduced } else { -reduced }
  if magnitude <= self.options.reduced_cost_tolerance {
    return -1.0
  }
  self.enter_sigma = if at_upper { -1.0 } else { 1.0 }
  let limit = self.ratio_test(column, self.direction(column))
  if limit.unbounded {
    // An unlimited step is as good as a gain gets; the pivot will report it.
    return 1.0e30
  }
  magnitude * limit.step
}

///|
/// Picks the entering column by measured gain instead of by reduced cost alone.
///
/// The candidates are bounded per iteration on purpose. Measuring a gain costs a
/// direction and a ratio test, so measuring every column would cost a solve per
/// column; the set is instead:
///
/// - the column Dantzig would have picked (the pricing pass already found it),
/// - the columns that showed the best measured gains recently, re-measured so a
///   column that has since become basic or stopped moving drops out,
/// - a rotating window over the column space, which is how a good column is
///   *discovered* in the first place.
///
/// Returns the winner; the pool and the window cursor are updated as a side effect.
fn State::choose_by_gain(
  self : State,
  duals : Array[Double],
  dantzig : Int,
) -> Int {
  let pointers = self.problem.matrix.col_pointers()
  let rows = self.problem.matrix.row_indices()
  let values = self.problem.matrix.values_view()
  let mut best = dantzig
  let mut best_gain = self.candidate_gain(
    dantzig, duals, pointers, rows, values,
  )
  // The pool: re-measure what was good, and forget what can no longer enter.
  for k = 0; k < self.gain_pool.length(); k = k + 1 {
    let j = self.gain_pool[k]
    if j < 0 || j >= self.n {
      continue
    }
    if self.is_basic[j] || self.forbid[j] {
      self.gain_pool[k] = -1
      self.gain_pool_gains[k] = 0.0
      continue
    }
    if j == best {
      continue
    }
    let gain = self.candidate_gain(j, duals, pointers, rows, values)
    self.gain_pool_gains[k] = gain
    if gain > best_gain {
      best_gain = gain
      best = j
    }
  }
  // The rotating window: every column gets offered eventually.
  let window = self.options.gain_candidates - self.gain_pool.length()
  let mut offered = 0
  let mut offset = 0
  while offered < window && offset < self.n {
    let j = (self.gain_cursor + offset) % self.n
    offset = offset + 1
    if self.is_basic[j] || self.forbid[j] {
      continue
    }
    offered = offered + 1
    if j == best {
      continue
    }
    let gain = self.candidate_gain(j, duals, pointers, rows, values)
    if gain > best_gain {
      best_gain = gain
      best = j
    }
  }
  self.gain_cursor = (self.gain_cursor + offset) % self.n
  // Remember the winner, keeping the pool ordered by the last measured gain.
  if best_gain > 0.0 && best_gain < 1.0e30 {
    let mut slot = -1
    let mut worst = 0.0
    let mut present = false
    for k = 0; k < self.gain_pool.length(); k = k + 1 {
      if self.gain_pool[k] == best {
        present = true
        self.gain_pool_gains[k] = best_gain
      } else if slot < 0 || self.gain_pool_gains[k] < worst {
        slot = k
        worst = self.gain_pool_gains[k]
      }
    }
    if !present && slot >= 0 && best_gain > worst {
      self.gain_pool[slot] = best
      self.gain_pool_gains[slot] = best_gain
    }
  }
  best
}

///|
/// Runs the current phase to optimality.
///
/// Codes: `0` optimal, `1` unbounded, `2` iteration limit, `3` numerical
/// failure (singular refactorization).
fn State::iterate(self : State) -> Int {
  if !self.factorized {
    // Without factors every solve would return whatever the buffers happened to
    // hold, and the run would "converge" on nonsense. Refuse instead.
    return 3
  }
  while self.iterations < self.options.max_iterations {
    if self.options.refactorize_every > 0 &&
      self.iterations > 0 &&
      self.iterations % self.options.refactorize_every == 0 {
      if !self.refactorize() {
        return 3
      }
    }
    let duals = self.duals()
    let entering = self.choose_entering(duals)
    if entering < 0 {
      return 0
    }
    // Gain pricing, when enabled, replaces the column Dantzig priced with the one
    // whose step is worth the most. The direction and the ratio test are redone for
    // the winner below, so the choice is authoritative rather than inherited.
    let mut entering = entering
    if self.options.gain_candidates > 0 {
      entering = self.choose_by_gain(duals, entering)
      self.enter_sigma = if self.at_upper[entering] { -1.0 } else { 1.0 }
    }
    let mut d = self.direction(entering)
    // The direction has to satisfy the basis equation `A·d = aⱼ`. When it does not, the
    // factors no longer describe the basis, and both the ratio test and the pivot read
    // their numbers off that direction — so the run rebuilds them and asks again. A
    // direction that is still off afterwards is not something to pivot on: the run
    // stops as a numerical failure, which the caller answers with a recovery attempt
    // from a different pivot rule rather than with a step nothing supports.
    if self.direction_residual(entering, d) > self.options.feasibility_tolerance {
      if self.refactorize() {
        d = self.direction(entering)
      }
      if self.direction_residual(entering, d) >
        self.options.feasibility_tolerance {
        return 3
      }
    }
    let limit = self.ratio_test(entering, d)
    if limit.unbounded {
      // The direction buffer still holds `B⁻¹aⱼ` and nothing else runs before the
      // result is built, so recording which column entered is enough to reconstruct
      // the recession direction a certificate needs.
      self.ray_column = entering
      self.ray_sigma = self.enter_sigma
      return 1
    }
    let mut leave = limit.row
    let mut step = limit.step
    let mut flip = limit.flip
    // Pivot stability. The ratio test picks the leaving row from the tableau
    // direction, so a pivot that is negligible compared with the rest of the
    // direction means the direction itself is unreliable — the product-form
    // updates have drifted away from the true basis inverse. Pivoting there
    // produces a basis that is singular or nearly so, and the next
    // refactorization then fails on it. Rebuilding the inverse and redoing the
    // choice costs one factorization; the pivot that comes out of the rebuilt
    // inverse is accepted even if it is still small, because at that point the
    // direction is as accurate as this code can make it. A flip has no pivot to
    // check and needs no rebuild.
    if !flip && self.weak_pivot(d, leave) {
      if self.refactorize() {
        let retried = self.ratio_test(entering, self.direction(entering))
        if retried.unbounded {
          return 1
        }
        leave = retried.row
        step = retried.step
        flip = retried.flip
      }
    }
    if flip {
      self.apply_flip(entering, d, step)
    } else {
      self.pivot(leave, entering, d, step)
    }
    // Stall detection: switch to Bland's rule when the objective stops moving.
    let objective = self.kernel_objective()
    let improved = if self.saw_objective {
      objective < self.best_objective - 1.0e-10
    } else {
      true
    }
    if improved {
      self.best_objective = objective
      self.saw_objective = true
      self.stalled = 0
    } else {
      self.stalled = self.stalled + 1
      // A fixed window, not `2m + 50`: what a stall means does not depend on how
      // many rows the kernel problem happens to have, and a window that grows with
      // `m` is unreachable on exactly the large problems that need it — it asked
      // for 127 030 consecutive unimproved pivots on fast0507, whose default
      // iteration cap is 20 000, so the fallback could not fire at all.
      if self.options.stall_window > 0 &&
        self.stalled > self.options.stall_window {
        self.bland = true
      }
    }
  }
  2
}

///|
/// Kernel column values of the current basis (tiny negative basic values are
/// clamped so the caller never sees `-1e-17`).
///
/// A non-basic column is at one end of its range, and that end is part of the
/// solution: the ones at their upper bound used to be invisible here because the
/// bound was a row whose slack carried the difference.
fn State::values(self : State) -> Array[Double] {
  let values : Array[Double] = Array::make(self.n, 0.0)
  for i = 0; i < self.m; i = i + 1 {
    let value = self.xb[i]
    values[self.basis[i]] = if value < 0.0 &&
      value > -self.options.feasibility_tolerance {
      0.0
    } else {
      value
    }
  }
  let upper = self.problem.upper
  for j = 0; j < self.n; j = j + 1 {
    if self.at_upper[j] && !self.is_basic[j] {
      values[j] = upper[j]
    }
  }
  values
}

///|
/// Solves a standard-form problem and returns kernel column values.
///
/// A run that ends in a numerical failure gets exactly one recovery attempt: the
/// same problem, restarted from the initial basis with Bland's rule and a much
/// shorter refactorization interval. A singular basis is a statement about the
/// path a run took, not about the problem, and a different pivot rule walks a
/// different path — Bland's rule is deterministic and cannot cycle, so it is the
/// natural second opinion on a degenerate model.
///
/// The recovery is not trusted on its own. Whatever it returns goes through the
/// same residual self-check as any other run, and if it also fails numerically the
/// original failure is the result, message included.
fn solve_problem(
  problem : KernelProblem,
  options : SimplexOptions,
) -> SimplexResult {
  let first = solve_once(problem, options)
  if first.status != NumericalFailure {
    return first
  }
  let every = if options.refactorize_every <= 0 {
    0
  } else {
    @core.fmin_int(options.refactorize_every, 100)
  }
  let recovery : SimplexOptions = {
    max_iterations: options.max_iterations,
    refactorize_every: every,
    feasibility_tolerance: options.feasibility_tolerance,
    pivot_tolerance: options.pivot_tolerance,
    pivot_relative_tolerance: options.pivot_relative_tolerance,
    start_with_bland: true,
    stall_window: options.stall_window,
    gain_candidates: options.gain_candidates,
    degeneracy_perturbation: options.degeneracy_perturbation,
    max_factor_entries: options.max_factor_entries,
    reduced_cost_tolerance: options.reduced_cost_tolerance,
    relax_integrality: options.relax_integrality,
    max_kernel_rows: options.max_kernel_rows,
  }
  let second = solve_once(problem, recovery)
  if second.status == NumericalFailure {
    return first
  }
  {
    status: second.status,
    values: second.values,
    objective: second.objective,
    iterations: second.iterations,
    duals: second.duals,
    ray: second.ray,
    basis: second.basis,
    message: "recovered from a numerical failure by restarting with Bland's rule (" +
    first.message +
    ")",
  }
}

///|
/// Solves a standard-form problem and returns kernel column values.
///
/// The size check happens before anything is allocated. It is not a performance
/// hint: `State::new` builds a dense `m x m` basis inverse, so a kernel problem of
/// sixty thousand rows asks for tens of gigabytes, and on the native backend that
/// request ends the process instead of returning an error. Refusing with a
/// measured reason is the only outcome the caller can act on.
fn solve_once(
  problem : KernelProblem,
  options : SimplexOptions,
) -> SimplexResult {
  if problem.nrows > options.max_kernel_rows {
    return {
      status: TooLarge,
      values: [],
      objective: 0.0,
      iterations: 0,
      duals: [],
      ray: [],
      basis: None,
      message: "kernel problem has " +
      problem.nrows.to_string() +
      " rows, above the " +
      options.max_kernel_rows.to_string() +
      " row limit. Kernel rows are the model's rows plus one explicit row per finite upper bound, so a model with few constraints can still land here. The basis is factored sparsely, so this limit guards against a hopeless run rather than against allocation; `max_factor_entries` is what bounds the factors",
    }
  }
  let state = State::new(problem, options)
  let mut has_artificial = false
  for j = 0; j < problem.ncols; j = j + 1 {
    if problem.is_artificial[j] {
      has_artificial = true
    }
  }
  if has_artificial {
    state.set_phase1()
    let code = state.iterate()
    if code == 2 {
      return {
        status: IterationLimit,
        values: [],
        objective: 0.0,
        iterations: state.iterations,
        duals: [],
        ray: [],
        basis: None,
        // The measured progress belongs in the message: Phase I's objective is the
        // artificial sum, and a caller that only sees "iteration limit" cannot tell
        // a run that was closing in on feasibility from one that was stuck. The
        // reported `objective` stays zero on purpose — a partially minimised
        // artificial sum is not an objective value of the caller's model, and
        // printing it as one is how a run that was converging by 0.8 units per
        // pivot got read as "stuck at 13" for a whole round of work.
        message: "iteration limit reached during Phase I (artificial sum " +
        state.artificial_sum().to_string() +
        " after " +
        state.iterations.to_string() +
        " pivots, bland=" +
        state.bland.to_string() +
        ")",
      }
    }
    if code == 3 {
      return {
        status: NumericalFailure,
        values: [],
        objective: 0.0,
        iterations: state.iterations,
        duals: [],
        ray: [],
        basis: None,
        message: "basis became numerically singular during Phase I",
      }
    }
    // Feasibility is decided by measuring, not by trusting the bookkeeping.
    //
    // The measurement is taken against the right hand side the run actually solved, which
    // is `solve_rhs` — the model's own right hand side plus the degeneracy perturbation.
    //
    // The verdict is drawn only when the violation is *clearly* beyond the tolerance, and
    // that margin is the point of this branch rather than a detail. A tolerance is the size
    // at which a measurement stops meaning anything: the ratio test's band and the clamping
    // of round-off negative basic values both let the equality system be violated by up to
    // about the tolerance times a row's coefficients, so a point that is feasible can
    // measure a residual a little above the tolerance. Reporting *infeasible* there is not
    // a conservative mistake — it prunes a feasible node out of a branch and bound tree and
    // can make the tree claim an optimum that is not one. A branch and bound node of
    // `misc07` measured 1.0949e-7 against a 1e-7 tolerance with an artificial sum of 6e-9,
    // and the model is feasible: with the margin in place the node solves to 1647.8571326,
    // which is the optimum an outside solver finds (1647.857142857).
    //
    // The caller's model is still measured against the unperturbed right hand side: a point
    // only gets reported as an answer if it survives that (`finish_optimal`), so relaxing
    // the question here cannot turn into a relaxed answer there.
    let phase1_values = state.values()
    let (phase1_scaled, _) = max_scaled_residual(
      problem,
      phase1_values,
      false,
      state.solve_rhs,
    )
    let (phase1_model_scaled, phase1_raw) = max_scaled_residual(
      problem,
      phase1_values,
      false,
      problem.rhs,
    )
    let artificial_sum = state.artificial_sum()
    if phase1_scaled > infeasibility_margin * options.feasibility_tolerance {
      return {
        status: Infeasible,
        values: [],
        objective: 0.0,
        iterations: state.iterations,
        // The duals of the Phase I optimum are a Farkas ray: they certify that no
        // point satisfies the rows, which the residual above only measures.
        duals: state.model_duals(),
        ray: [],
        basis: None,
        message: "no feasible point exists (scaled row residual " +
        phase1_model_scaled.to_string() +
        ", raw " +
        phase1_raw.to_string() +
        ", artificial sum " +
        artificial_sum.to_string() +
        ")",
      }
    }
    // An artificial that is still basic sits at zero because its row is
    // redundant. It has to leave the basis before Phase II: otherwise a later
    // pivot moves it to a positive value, which silently violates that row while
    // the artificial absorbs the residual.
    state.drive_artificials_out()
  }
  state.set_phase2()
  state.saw_objective = false
  state.stalled = 0
  let code = state.iterate()
  if code == 1 {
    // An unboundedness proof is a feasible point *plus* a direction that leaves it
    // improving forever, and the run is standing on the feasible point when the ratio
    // test finds nothing that limits the step. That "standing on" is an assumption
    // about the state, so it is measured rather than assumed: a state that drifted is
    // exactly the state whose ratio test finds no limit, and reporting it as unbounded
    // is a wrong answer with a confident status — the one outcome this project exists
    // to prevent. Two branch and bound nodes of `noswot` reached this verdict while
    // violating a row by its whole scale, and the independent checker refused them.
    let unbounded_values = state.values()
    let (unbounded_residual, _) = max_scaled_residual(
      problem,
      unbounded_values,
      false,
      problem.rhs,
    )
    if unbounded_residual > options.feasibility_tolerance {
      return {
        status: NumericalFailure,
        values: [],
        objective: 0.0,
        iterations: state.iterations,
        duals: [],
        ray: [],
        basis: None,
        message: "no limiting row was found, but the point the run is standing on is not feasible (scaled row residual " +
        unbounded_residual.to_string() +
        "), so the unboundedness verdict is not supported",
      }
    }
    return {
      status: Unbounded,
      // An unboundedness proof is a feasible point *plus* a direction that leaves it
      // improving forever, and the run is standing on the feasible point when the
      // ratio test finds nothing that limits the step.
      values: problem.solution(state.values()),
      objective: 0.0,
      iterations: state.iterations,
      duals: [],
      ray: state.model_ray(),
      basis: None,
      message: "the objective is unbounded on the feasible set",
    }
  }
  if code == 2 {
    return {
      status: IterationLimit,
      values: [],
      objective: 0.0,
      iterations: state.iterations,
      duals: [],
      ray: [],
      basis: None,
      // Same reasoning as Phase I: a run that stops short should say how far it
      // got, measured. The kernel-sense objective is what the loop was reducing;
      // mapping it back to the caller's model would be a claim about a solution
      // that does not exist yet.
      message: "iteration limit reached before optimality was proven (kernel objective " +
      state.kernel_objective().to_string() +
      " after " +
      state.iterations.to_string() +
      " pivots)",
    }
  }
  if code == 3 {
    return {
      status: NumericalFailure,
      values: [],
      objective: 0.0,
      iterations: state.iterations,
      duals: [],
      ray: [],
      basis: None,
      message: "basis became numerically singular",
    }
  }
  state.finish_optimal()
}

///|
/// Turns a basis that has been brought back to feasibility into the run's result.
///
/// Shared by the cold path and the warm start: whatever a run did to get here, the
/// answer leaves through the same self-check, so a reoptimization cannot report an
/// optimum the cold path would have refused. The residual is measured against the
/// **unperturbed** right hand side, as everywhere else.
fn State::finish_optimal(self : State) -> SimplexResult {
  let problem = self.problem
  let options = self.options
  let mut kernel_values = self.values()
  // Final self-check: never report an optimum for a point that does not satisfy
  // the rows or the non-negativity requirement, judged against the scale of the
  // numbers involved (see max_scaled_residual).
  let tolerance = options.feasibility_tolerance
  let measured = max_scaled_residual(problem, kernel_values, false, problem.rhs)
  let mut scaled_residual = measured.0
  let mut raw_residual = measured.1
  let mut negativity = max_negativity(kernel_values)
  if scaled_residual > tolerance || negativity > tolerance {
    // The product-form updates are exact in exact arithmetic but accumulate
    // round-off; folding them into a fresh factorization often restores the last
    // digits. Only a violation that survives that is a numerical failure.
    if self.refactorize() {
      kernel_values = self.values()
      let (retry_scaled, retry_raw) = max_scaled_residual(
        problem,
        kernel_values,
        false,
        problem.rhs,
      )
      scaled_residual = retry_scaled
      raw_residual = retry_raw
      negativity = max_negativity(kernel_values)
    }
  }
  if scaled_residual > tolerance || negativity > tolerance {
    return {
      status: NumericalFailure,
      values: [],
      objective: 0.0,
      iterations: self.iterations,
      duals: [],
      ray: [],
      basis: None,
      message: "the resulting basis is not feasible (scaled row residual " +
      scaled_residual.to_string() +
      ", raw " +
      raw_residual.to_string() +
      ", scaled negative value " +
      negativity.to_string() +
      ")",
    }
  }
  let acc = @core.CompensatedSum::new()
  acc.add(problem.objective_constant)
  for j = 0; j < problem.ncols; j = j + 1 {
    acc.add(problem.cost[j] * kernel_values[j])
  }
  {
    status: Optimal,
    values: problem.solution(kernel_values),
    objective: problem.model_sign * acc.value(),
    iterations: self.iterations,
    // The duals of the final basis are the other half of an optimality proof. They
    // are read after Phase II, so they belong to the costs the run actually
    // minimised.
    duals: self.model_duals(),
    ray: [],
    // The optimal basis, so a later run over the same columns can reoptimize from it
    // instead of rebuilding Phase I.
    basis: Some(self.basis_snapshot()),
    message: "",
  }
}

///|
/// How far past the feasibility tolerance a measured violation has to be before Phase I is
/// allowed to call a model infeasible.
///
/// Not a tuning knob but a statement about resolution: the tolerance is the size at which
/// this kernel stops being able to tell a violation from round-off, so a verdict that says
/// "no point satisfies these rows" has to be drawn from a measurement clearly above it. The
/// comment at the Phase I decision has the instance that made this concrete.
let infeasibility_margin : Double = 10.0

///|
/// Largest *scaled* row residual over the real columns.
///
/// A residual is judged against the scale of the row it belongs to:
///
///   |A x − b| / (1 + |b| + Σ |aᵢⱼ|·|xⱼ|)
///
/// This is the convention real LP codes use, and it is what makes a tolerance
/// mean the same thing across models whose coefficients differ by orders of
/// magnitude. A raw residual of 2.5e-7 on a row whose right hand side is in the
/// hundreds, or whose terms sum to tens, is round-off, not infeasibility; a raw
/// residual of 3.9e-5 against a right hand side of order one is infeasibility.
///
/// How far past the tolerance such a measurement has to be before Phase I may call a model
/// infeasible is a separate question, and `infeasibility_margin` is where it is answered.
///
/// Artificial columns are excluded on purpose: an artificial variable sitting in
/// the basis would absorb exactly the amount by which its row is violated, so
/// including them would make the check vacuous. Slacks and surplus columns are
/// real columns and stay in the measurement.
///
/// `reference` is the right hand side the deviation is measured against: the model's own
/// for an answer that is about to be reported, and the perturbed one the run solved for the
/// Phase I verdict. The two are not interchangeable — a verdict about feasibility belongs
/// to the system the run actually solved — and the comment at that decision says why.
fn max_scaled_residual(
  problem : KernelProblem,
  values : Array[Double],
  include_artificial : Bool,
  reference : Array[Double],
) -> (Double, Double) {
  let signed : Array[Double] = Array::make(problem.nrows, 0.0)
  let magnitude : Array[Double] = Array::make(problem.nrows, 0.0)
  let pointers = problem.matrix.col_pointers()
  let rows = problem.matrix.row_indices()
  let coefficients = problem.matrix.values_view()
  for j = 0; j < problem.ncols; j = j + 1 {
    if !include_artificial && problem.is_artificial[j] {
      continue
    }
    let value = values[j]
    if value != 0.0 {
      let mut k = pointers[j]
      let end = pointers[j + 1]
      while k < end {
        let row = rows[k]
        let contribution = coefficients[k] * value
        signed[row] = signed[row] + contribution
        magnitude[row] = magnitude[row] + @core.fabs(contribution)
        k = k + 1
      }
    }
  }
  let mut worst = 0.0
  let mut raw = 0.0
  for i = 0; i < problem.nrows; i = i + 1 {
    let deviation = @core.fabs(signed[i] - reference[i])
    if deviation > raw {
      raw = deviation
    }
    let scale = 1.0 + @core.fabs(problem.rhs[i]) + magnitude[i]
    let scaled = deviation / scale
    if scaled > worst {
      worst = scaled
    }
  }
  (worst, raw)
}

///|
/// Worst violation of the non-negativity requirement, judged the way the independent
/// checker judges it: `−xⱼ / (1 + |xⱼ|)`, per variable.
///
/// The scale used to be the largest value anywhere in the solution, and that is not
/// the same statement: a basic value of `-7.7e-7` next to an entry of `1e5` measured
/// `7.7e-12` here and passed, while `verify` — which reads each variable against its
/// own size, because that is what a variable's bound means — measured `7.7e-7` and
/// refused the point. A self-check that is looser than the check it stands in for is
/// not a self-check: the kernel reported a branch and bound node of `noswot` as solved
/// while its point sat `7.7e-7` below a lower bound of zero.
fn max_negativity(values : Array[Double]) -> Double {
  let mut worst = 0.0
  for j = 0; j < values.length(); j = j + 1 {
    if values[j] >= 0.0 {
      continue
    }
    let scaled = -values[j] / (1.0 + @core.fabs(values[j]))
    if scaled > worst {
      worst = scaled
    }
  }
  worst
}
