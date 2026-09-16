///|
/// The revised simplex iteration.
///
/// Shape of one iteration: compute the duals `y = c_Bᵀ B⁻¹`, price the
/// non-basic columns with `rⱼ = cⱼ − y·Aⱼ` (walking the sparse column), pick an
/// improving column, form `d = B⁻¹ Aⱼ`, run the ratio test, pivot. The basis
/// inverse is updated by the product-form row operation and rebuilt from the
/// basis columns every `refactorize_every` pivots.
///
/// Termination: no column with a reduced cost below `−tol` means optimal; an
/// entering column with no positive `d` entry means unbounded; hitting the
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
  direction_buffer : Array[Double]
  basic_cost_buffer : Array[Double]
  /// Scratch for the triangular solves. The solvers permute the vector they are
  /// handed, so they need somewhere to do it that is not the caller's buffer.
  solve_scratch : Array[Double]
  /// Values of the basic variables.
  xb : Array[Double]
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
    direction_buffer: Array::make(m, 0.0),
    basic_cost_buffer: Array::make(m, 0.0),
    solve_scratch: Array::make(m, 0.0),
    xb: solve_rhs.copy(),
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
  y
}

///|
/// Reduced cost of a column: `cⱼ − y·Aⱼ`, walking only that column's nonzeros.
///
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
/// Picks the entering column.
///
/// Dantzig (most negative reduced cost) by default, Bland (smallest index) when
/// the run has stalled — Bland's rule is what makes termination certain on
/// degenerate problems, at the price of more iterations.
///
/// Pricing walks the raw CSC arrays: an earlier version asked for a freshly
/// allocated `(row, value)` list per column, which dominated the runtime on the
/// larger instances (a few million short-lived arrays for one solve).
fn State::choose_entering(self : State, duals : Array[Double]) -> Int {
  let threshold = -self.options.reduced_cost_tolerance
  let pointers = self.problem.matrix.col_pointers()
  let rows = self.problem.matrix.row_indices()
  let values = self.problem.matrix.values_view()
  let mut best = -1
  let mut best_reduced = 0.0
  for j = 0; j < self.n; j = j + 1 {
    if self.is_basic[j] || self.forbid[j] {
      continue
    }
    let reduced = self.reduced_cost(j, duals, pointers, rows, values)
    if reduced < threshold {
      if self.bland {
        return j
      }
      if best < 0 || reduced < best_reduced {
        best = j
        best_reduced = reduced
      }
    }
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
      let entry = self.tableau_entry(j, weights)
      if @core.fabs(entry) > tolerance {
        // Rebuild the full direction only for the column that will be pivoted.
        let d = self.direction(j)
        self.pivot(r, j, d)
        break
      }
    }
  }
}

///|
/// Harris two-pass ratio test.
///
/// Pass one takes the smallest ratio over positive `d` entries; pass two picks,
/// among the rows whose ratio is within a *relative* band of that minimum, the one
/// with the largest pivot element. That second pass is what keeps the basis
/// well-conditioned: it prefers a numerically strong pivot over the
/// mathematically exact one.
///
/// The band is deliberately relative (`1e-9·|ratio|`) rather than the feasibility
/// tolerance. A band of `1e-7·(1+|ratio|)` lets the step overshoot by `1e-7·ratio`,
/// and that overshoot is multiplied by the pivot element when the basic values are
/// updated: with ratios and pivots around 1e5, a "tiny" relative allowance became
/// an absolute violation of tens on MIPLIB's noswot.
///
/// Returns the leaving row, or `-1` when no row limits the step (unbounded).
fn State::ratio_test(self : State, d : Array[Double]) -> Int {
  let tolerance = self.options.pivot_tolerance
  let feasibility = self.options.feasibility_tolerance
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
    if d[i] > tolerance && self.xb[i] > -feasibility {
      let ratio = self.xb[i] / d[i]
      if strict_row < 0 || ratio < ratio_min {
        ratio_min = ratio
        strict_row = i
      }
    }
  }
  if strict_row < 0 {
    return -1
  }
  let band = 1.0e-9 * @core.fabs(ratio_min) + tolerance
  let relaxed = ratio_min + band
  let mut leave = -1
  let mut best_pivot = 0.0
  for i = 0; i < self.m; i = i + 1 {
    if d[i] > tolerance && self.xb[i] > -feasibility {
      let ratio = self.xb[i] / d[i]
      if ratio <= relaxed {
        let better = if leave < 0 {
          true
        } else if self.bland {
          self.basis[i] < self.basis[leave]
        } else {
          d[i] > best_pivot
        }
        if better {
          leave = i
          best_pivot = d[i]
        }
      }
    }
  }
  if leave < 0 {
    return strict_row
  }
  // Harris's preference is only safe if the step it implies keeps every basic
  // value feasible. Simulating the step costs one pass over the rows, and it is
  // what stops a "well conditioned" pivot from writing off feasibility: the
  // overshoot of the band is multiplied by the pivot element, so with ratios and
  // rows in the 1e5 range a relative allowance of 1e-9 still moved a basic value
  // by tens on MIPLIB's noswot.
  if leave != strict_row {
    let step = self.xb[leave] / d[leave]
    let mut keeps_feasibility = true
    for i = 0; i < self.m; i = i + 1 {
      if i != leave {
        let candidate = self.xb[i] - d[i] * step
        if candidate < -feasibility * (1.0 + @core.fabs(self.xb[i])) {
          keeps_feasibility = false
        }
      }
    }
    if !keeps_feasibility {
      return strict_row
    }
  }
  leave
}

///|
/// Updates the basis inverse and the basic values for a pivot on `(row, column)`.
fn State::pivot(
  self : State,
  row : Int,
  column : Int,
  d : Array[Double],
) -> Unit {
  let pivot = d[row]
  // Basic values: the entering variable takes the ratio, the others move along d.
  let entering_value = self.xb[row] / pivot
  for i = 0; i < self.m; i = i + 1 {
    if i != row {
      self.xb[i] = self.xb[i] - d[i] * entering_value
      // Absorb the drift the ratio test always leaves behind.
      if self.xb[i] < 0.0 && self.xb[i] > -self.options.feasibility_tolerance {
        self.xb[i] = 0.0
      }
    }
  }
  self.xb[row] = entering_value
  // Product-form update: the pivot becomes one sparse eta instead of an O(m²)
  // row operation on an explicit inverse.
  self.etas.push(Eta::from_direction(row, d))
  self.is_basic[self.basis[row]] = false
  self.basis[row] = column
  self.is_basic[column] = true
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
      // solved against.
      for i = 0; i < m; i = i + 1 {
        self.xb[i] = self.solve_rhs[i]
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
    let d = self.direction(entering)
    let mut leaving = self.ratio_test(d)
    if leaving < 0 {
      return 1
    }
    // Pivot stability. The ratio test picks the leaving row from the tableau
    // direction, so a pivot that is negligible compared with the rest of the
    // direction means the direction itself is unreliable — the product-form
    // updates have drifted away from the true basis inverse. Pivoting there
    // produces a basis that is singular or nearly so, and the next
    // refactorization then fails on it. Rebuilding the inverse and redoing the
    // choice costs one factorization; the pivot that comes out of the rebuilt
    // inverse is accepted even if it is still small, because at that point the
    // direction is as accurate as this code can make it.
    if self.weak_pivot(d, leaving) {
      if self.refactorize() {
        let retried = self.ratio_test(self.direction(entering))
        if retried < 0 {
          return 1
        }
        leaving = retried
      }
    }
    self.pivot(leaving, entering, d)
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
/// Kernel column values of the current basis (nonbasic columns are zero, and
/// tiny negative values are clamped so the caller never sees `-1e-17`).
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
        message: "basis became numerically singular during Phase I",
      }
    }
    // Feasibility is decided by measuring, not by trusting the bookkeeping. The
    // scaled residual carries the decision: the artificial sum is reported for
    // diagnosis, but scaled it would say the same thing less precisely.
    let phase1_values = state.values()
    let (phase1_scaled, phase1_raw) = max_scaled_residual(
      problem, phase1_values, false,
    )
    let artificial_sum = state.artificial_sum()
    if phase1_scaled > options.feasibility_tolerance {
      return {
        status: Infeasible,
        values: [],
        objective: 0.0,
        iterations: state.iterations,
        message: "no feasible point exists (scaled row residual " +
        phase1_scaled.to_string() +
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
    return {
      status: Unbounded,
      values: [],
      objective: 0.0,
      iterations: state.iterations,
      message: "the objective is unbounded on the feasible set",
    }
  }
  if code == 2 {
    return {
      status: IterationLimit,
      values: [],
      objective: 0.0,
      iterations: state.iterations,
      message: "iteration limit reached before optimality was proven",
    }
  }
  if code == 3 {
    return {
      status: NumericalFailure,
      values: [],
      objective: 0.0,
      iterations: state.iterations,
      message: "basis became numerically singular",
    }
  }
  let mut kernel_values = state.values()
  // Final self-check: never report an optimum for a point that does not satisfy
  // the rows or the non-negativity requirement, judged against the scale of the
  // numbers involved (see max_scaled_residual).
  let tolerance = options.feasibility_tolerance
  let measured = max_scaled_residual(problem, kernel_values, false)
  let mut scaled_residual = measured.0
  let mut raw_residual = measured.1
  let mut negativity = max_negativity(kernel_values)
  if scaled_residual > tolerance || negativity > tolerance {
    // The product-form updates are exact in exact arithmetic but accumulate
    // round-off; folding them into a fresh factorization often restores the last
    // digits. Only a violation that survives that is a numerical failure.
    if state.refactorize() {
      kernel_values = state.values()
      let (retry_scaled, retry_raw) = max_scaled_residual(
        problem, kernel_values, false,
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
      iterations: state.iterations,
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
    iterations: state.iterations,
    message: "",
  }
}

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
/// Artificial columns are excluded on purpose: an artificial variable sitting in
/// the basis would absorb exactly the amount by which its row is violated, so
/// including them would make the check vacuous. Slacks and surplus columns are
/// real columns and stay in the measurement.
fn max_scaled_residual(
  problem : KernelProblem,
  values : Array[Double],
  include_artificial : Bool,
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
    let deviation = @core.fabs(signed[i] - problem.rhs[i])
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
/// Worst violation of the non-negativity requirement, scaled by the magnitude of
/// the solution so a `-1e-12` next to values of size 1e6 counts as rounded off.
fn max_negativity(values : Array[Double]) -> Double {
  let mut worst = 0.0
  let mut scale = 1.0
  for j = 0; j < values.length(); j = j + 1 {
    let magnitude = @core.fabs(values[j])
    if magnitude > scale {
      scale = magnitude
    }
    if values[j] < 0.0 && -values[j] > worst {
      worst = -values[j]
    }
  }
  worst / scale
}
