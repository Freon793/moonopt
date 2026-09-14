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
/// Mutable state of one run.
priv struct State {
  problem : KernelProblem
  options : SimplexOptions
  m : Int
  n : Int
  /// Dense basis inverse. Replaced wholesale by refactorization.
  mut inv : Array[Array[Double]]
  /// Values of the basic variables.
  xb : Array[Double]
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
  let inv : Array[Array[Double]] = []
  for i = 0; i < m; i = i + 1 {
    let row : Array[Double] = []
    for k = 0; k < m; k = k + 1 {
      row.push(if i == k { 1.0 } else { 0.0 })
    }
    inv.push(row)
  }
  let basis : Array[Int] = []
  let is_basic : Array[Bool] = Array::make(n, false)
  for i = 0; i < m; i = i + 1 {
    let column = problem.initial_basis[i]
    basis.push(column)
    is_basic[column] = true
  }
  {
    problem,
    options,
    m,
    n,
    inv,
    xb: problem.rhs.copy(),
    basis,
    is_basic,
    cost: problem.cost.copy(),
    forbid: problem.is_artificial.copy(),
    iterations: 0,
    bland: false,
    stalled: 0,
    best_objective: 0.0,
    saw_objective: false,
  }
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
/// Duals `yᵀ = c_Bᵀ B⁻¹`, computed row by row of the inverse.
fn State::duals(self : State) -> Array[Double] {
  let y : Array[Double] = Array::make(self.m, 0.0)
  for k = 0; k < self.m; k = k + 1 {
    let basic_cost = self.cost[self.basis[k]]
    if basic_cost != 0.0 {
      let inverse_row = self.inv[k]
      for i = 0; i < self.m; i = i + 1 {
        y[i] = y[i] + basic_cost * inverse_row[i]
      }
    }
  }
  y
}

///|
/// Reduced cost of a column: `cⱼ − y·Aⱼ`, walking only that column's nonzeros.
fn State::reduced_cost(
  self : State,
  column : Int,
  duals : Array[Double],
) -> Double {
  let acc = @core.CompensatedSum::new()
  let entries = self.problem.matrix.column(column)
  for e = 0; e < entries.length(); e = e + 1 {
    let (row, value) = entries[e]
    acc.add(duals[row] * value)
  }
  self.cost[column] - acc.value()
}

///|
/// Picks the entering column.
///
/// Dantzig (most negative reduced cost) by default, Bland (smallest index) when
/// the run has stalled — Bland's rule is what makes termination certain on
/// degenerate problems, at the price of more iterations.
fn State::choose_entering(self : State, duals : Array[Double]) -> Int {
  let threshold = -self.options.reduced_cost_tolerance
  let mut best = -1
  let mut best_reduced = 0.0
  for j = 0; j < self.n; j = j + 1 {
    if self.is_basic[j] || self.forbid[j] {
      continue
    }
    let reduced = self.reduced_cost(j, duals)
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
/// `d = B⁻¹ Aⱼ` for the entering column.
fn State::direction(self : State, column : Int) -> Array[Double] {
  let d : Array[Double] = Array::make(self.m, 0.0)
  let entries = self.problem.matrix.column(column)
  for e = 0; e < entries.length(); e = e + 1 {
    let (row, value) = entries[e]
    if value != 0.0 {
      for i = 0; i < self.m; i = i + 1 {
        d[i] = d[i] + self.inv[i][row] * value
      }
    }
  }
  d
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
  for r = 0; r < self.m; r = r + 1 {
    if !self.problem.is_artificial[self.basis[r]] {
      continue
    }
    for j = 0; j < self.n; j = j + 1 {
      if self.is_basic[j] || self.problem.is_artificial[j] {
        continue
      }
      let d = self.direction(j)
      if @core.fabs(d[r]) > self.options.pivot_tolerance {
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
/// among the rows within the feasibility tolerance of that ratio, the one with
/// the largest pivot element. That second pass is what keeps the basis
/// well-conditioned: it prefers a numerically strong pivot over the
/// mathematically exact one.
///
/// Returns the leaving row, or `-1` when no row limits the step (unbounded).
fn State::ratio_test(self : State, d : Array[Double]) -> Int {
  let tolerance = self.options.pivot_tolerance
  // A basic variable that drifted slightly negative counts as zero, and it may
  // not limit the step: letting it do so takes the step backwards and leaves a
  // basis that is infeasible by far more than the round-off it started from.
  for i = 0; i < self.m; i = i + 1 {
    if self.xb[i] < 0.0 && self.xb[i] > -self.options.feasibility_tolerance {
      self.xb[i] = 0.0
    }
  }
  let mut ratio_max = 0.0
  let mut found = false
  for i = 0; i < self.m; i = i + 1 {
    if d[i] > tolerance && self.xb[i] > -self.options.feasibility_tolerance {
      let ratio = self.xb[i] / d[i]
      if !found || ratio < ratio_max {
        ratio_max = ratio
        found = true
      }
    }
  }
  if !found {
    return -1
  }
  let relaxed = ratio_max +
    self.options.feasibility_tolerance * (1.0 + @core.fabs(ratio_max))
  let mut leave = -1
  let mut best_pivot = 0.0
  for i = 0; i < self.m; i = i + 1 {
    if d[i] > tolerance && self.xb[i] > -self.options.feasibility_tolerance {
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
    return -1
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
  // Product form update of B⁻¹.
  let pivot_row = self.inv[row]
  for k = 0; k < self.m; k = k + 1 {
    pivot_row[k] = pivot_row[k] / pivot
  }
  for i = 0; i < self.m; i = i + 1 {
    if i != row {
      let factor = d[i]
      if factor != 0.0 {
        let target = self.inv[i]
        for k = 0; k < self.m; k = k + 1 {
          target[k] = target[k] - factor * pivot_row[k]
        }
      }
    }
  }
  self.is_basic[self.basis[row]] = false
  self.basis[row] = column
  self.is_basic[column] = true
  self.iterations = self.iterations + 1
}

///|
/// Rebuilds the basis inverse from the basis columns and recomputes the basic
/// values. Returns `false` when the basis is numerically singular, which means
/// the run has to stop rather than continue on garbage.
fn State::refactorize(self : State) -> Bool {
  let m = self.m
  let dense : Array[Array[Double]] = []
  for i = 0; i < m; i = i + 1 {
    dense.push(Array::make(m, 0.0))
  }
  for i = 0; i < m; i = i + 1 {
    let entries = self.problem.matrix.column(self.basis[i])
    for e = 0; e < entries.length(); e = e + 1 {
      let (row, value) = entries[e]
      dense[row][i] = value
    }
  }
  match invert(dense, m) {
    None => false
    Some(fresh) => {
      self.inv = fresh
      for i = 0; i < m; i = i + 1 {
        let acc = @core.CompensatedSum::new()
        for k = 0; k < m; k = k + 1 {
          acc.add(fresh[i][k] * self.problem.rhs[k])
        }
        self.xb[i] = acc.value()
      }
      true
    }
  }
}

///|
/// Gauss-Jordan inversion with partial pivoting.
fn invert(matrix : Array[Array[Double]], m : Int) -> Array[Array[Double]]? {
  let width = 2 * m
  let augmented : Array[Array[Double]] = []
  for i = 0; i < m; i = i + 1 {
    let row : Array[Double] = Array::make(width, 0.0)
    for k = 0; k < m; k = k + 1 {
      row[k] = matrix[i][k]
    }
    row[m + i] = 1.0
    augmented.push(row)
  }
  for col = 0; col < m; col = col + 1 {
    let mut best = col
    let mut best_absolute = @core.fabs(augmented[col][col])
    for i = col + 1; i < m; i = i + 1 {
      let candidate = @core.fabs(augmented[i][col])
      if candidate > best_absolute {
        best = i
        best_absolute = candidate
      }
    }
    if best_absolute < 1.0e-12 {
      return None
    }
    if best != col {
      let swap = augmented[best]
      augmented[best] = augmented[col]
      augmented[col] = swap
    }
    let pivot = augmented[col][col]
    for k = 0; k < width; k = k + 1 {
      augmented[col][k] = augmented[col][k] / pivot
    }
    for i = 0; i < m; i = i + 1 {
      if i != col {
        let factor = augmented[i][col]
        if factor != 0.0 {
          for k = 0; k < width; k = k + 1 {
            augmented[i][k] = augmented[i][k] - factor * augmented[col][k]
          }
        }
      }
    }
  }
  let inverse : Array[Array[Double]] = []
  for i = 0; i < m; i = i + 1 {
    let row : Array[Double] = []
    for k = 0; k < m; k = k + 1 {
      row.push(augmented[i][m + k])
    }
    inverse.push(row)
  }
  Some(inverse)
}

///|
/// Runs the current phase to optimality.
///
/// Codes: `0` optimal, `1` unbounded, `2` iteration limit, `3` numerical
/// failure (singular refactorization).
fn State::iterate(self : State) -> Int {
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
    let leaving = self.ratio_test(d)
    if leaving < 0 {
      return 1
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
      if self.stalled > 2 * self.m + 50 {
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
fn solve_problem(
  problem : KernelProblem,
  options : SimplexOptions,
) -> SimplexResult {
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
        message: "iteration limit reached during Phase I",
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
    // Feasibility is decided by measuring, not by trusting the bookkeeping: the
    // artificial sum is the total row infeasibility, and the residual check
    // repeats it independently on the real columns.
    let phase1_values = state.values()
    let phase1_residual = max_residual(problem, phase1_values, false)
    let artificial_sum = state.artificial_sum()
    let feasibility_limit = options.feasibility_tolerance *
      (1.0 + @core.fabs(problem.objective_constant))
    if phase1_residual > feasibility_limit || artificial_sum > feasibility_limit {
      return {
        status: Infeasible,
        values: [],
        objective: 0.0,
        iterations: state.iterations,
        message: "no feasible point exists (row residual " +
        phase1_residual.to_string() +
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
  let kernel_values = state.values()
  // Final self-check: never report an optimum for a point that does not satisfy
  // the rows or the non-negativity requirement. If this fires, the run is
  // reported as a numerical failure instead of as a plausible answer.
  let residual = max_residual(problem, kernel_values, false)
  let negativity = max_negativity(kernel_values)
  let limit = options.feasibility_tolerance *
    (1.0 + @core.fabs(problem.objective_constant))
  if residual > limit || negativity > limit {
    return {
      status: NumericalFailure,
      values: [],
      objective: 0.0,
      iterations: state.iterations,
      message: "the resulting basis is not feasible (row residual " +
      residual.to_string() +
      ", negative value " +
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
/// Largest violation of the row residuals `|A x − b|` over the *real* columns.
///
/// Artificial columns are excluded on purpose: an artificial variable sitting in
/// the basis would absorb exactly the amount by which its row is violated, so
/// including them would make the check vacuous. Slacks and surplus columns are
/// real columns and stay in the measurement.
fn max_residual(
  problem : KernelProblem,
  values : Array[Double],
  include_artificial : Bool,
) -> Double {
  let residual : Array[Double] = Array::make(problem.nrows, 0.0)
  for j = 0; j < problem.ncols; j = j + 1 {
    if !include_artificial && problem.is_artificial[j] {
      continue
    }
    let value = values[j]
    if value != 0.0 {
      let entries = problem.matrix.column(j)
      for e = 0; e < entries.length(); e = e + 1 {
        let (row, coefficient) = entries[e]
        residual[row] = residual[row] + coefficient * value
      }
    }
  }
  let mut worst = 0.0
  for i = 0; i < problem.nrows; i = i + 1 {
    let deviation = @core.fabs(residual[i] - problem.rhs[i])
    if deviation > worst {
      worst = deviation
    }
  }
  worst
}

///|
/// Worst violation of the non-negativity requirement.
fn max_negativity(values : Array[Double]) -> Double {
  let mut worst = 0.0
  for j = 0; j < values.length(); j = j + 1 {
    if values[j] < 0.0 && -values[j] > worst {
      worst = -values[j]
    }
  }
  worst
}
