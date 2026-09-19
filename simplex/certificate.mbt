///|
/// Turning a finished run into a certificate.
///
/// The kernel works in its own normal form: rows sign-normalized, upper bounds as
/// bounds, slack / surplus / artificial columns for the relations, free variables
/// split in two. A certificate has to be stated against the model the caller handed
/// in, because that is the model a checker has — so this file is the way back, and
/// each step of it is the inverse of a transformation `problem.mbt` documents.
///
/// The row side is where a sign can go wrong: the kernel's dual for a normalized row
/// is not the model row's multiplier until the relation's own sign (a slack column
/// forces one, a surplus the other) and the row's negation are undone. Both of those
/// are folded into `row_dual_factor`, which `assemble` computes next to the
/// normalization that caused them.

///|
/// The basis the run is standing on, in the form a later run can start from.
fn State::basis_snapshot(self : State) -> SimplexBasis {
  {
    nrows: self.m,
    ncols: self.n,
    basis: self.basis.copy(),
    at_upper: self.at_upper.copy(),
  }
}

///|
/// Number of model rows this kernel problem corresponds to, which is the length of a
/// certificate's `duals`.
fn State::model_row_count(self : State) -> Int {
  let mut count = 0
  for r = 0; r < self.m; r = r + 1 {
    let source = self.problem.row_source[r]
    if source + 1 > count {
      count = source + 1
    }
  }
  count
}

///|
/// The run's dual solution, one entry per model row, in the convention `verify`
/// documents.
///
/// Rows this package invented (the row form of a free variable's upper bound) have no
/// model row to report against: their multipliers are the variable's bound
/// multipliers, and the verifier accounts for a variable's bounds through its reduced
/// costs rather than through a row, so leaving them out is what makes the two agree.
fn State::model_duals(self : State) -> Array[Double] {
  self.model_row_multipliers(self.duals())
}

///|
/// Maps a vector of kernel-row multipliers onto the model's rows, in the convention
/// `verify` documents.
///
/// Used for both halves of a certificate: the dual solution of an optimal run, and the
/// Farkas ray of an infeasible one. They are different vectors of the same space — one
/// proves optimality, the other proves that no point is feasible — and they need the
/// same sign bookkeeping, which is why this is one function.
fn State::model_row_multipliers(
  self : State,
  kernel : Array[Double],
) -> Array[Double] {
  let out : Array[Double] = Array::make(self.model_row_count(), 0.0)
  for r = 0; r < self.m; r = r + 1 {
    let source = self.problem.row_source[r]
    if source < 0 {
      continue
    }
    out[source] = self.problem.row_dual_factor[r] * kernel[r]
  }
  out
}

///|
/// Worst violation of the sign convention a certificate's row multipliers are read in, and
/// the model row it belongs to — measured with the formula `verify` uses, at the scale
/// `verify` uses.
///
/// This is the self-check the dual half of an optimality proof was missing. The kernel
/// decides it is optimal from reduced costs, which is a statement about the basis and needs
/// no sign convention at all; the certificate it then writes is read through a *different*
/// rule — a multiplier is non-negative on a `≤` or `≥` row and free on an equality — and
/// nothing measured whether the vector about to be written satisfies it. A degenerate
/// optimum has a whole face of optimal multipliers, and the point in it a simplex lands on
/// can be a few parts in `1e7` outside the convention while every other measurement agrees:
/// a branch and bound node of `blend2` (node 30782, depth 60) was reported optimal with a
/// multiplier `1.6827437132678818e-7` the wrong side of the boundary, which the independent
/// checker refused; clamping it there (see `mip/duals.mbt`) moved the failure rather than
/// removing it, because the multiplier was not free to discard.
///
/// The measurement is deliberately *the same expression* as `verify`'s check —
/// `raw · row_scale / cost_scale`, `raw = max(0, −yᵢ)`, `row_scale` the largest coefficient
/// of the row floored at one, `cost_scale` the largest objective coefficient floored at one,
/// equality rows skipped — because a self-check that stands in for another check has to
/// measure what that check measures. Being stricter refuses certificates the checker would
/// have accepted, and being looser is not a check at all; both mistakes have been made in
/// this project and are documented where they happened (`max_negativity` here, the row scale
/// in `mip/duals.mbt`).
///
/// Two things make the kernel's own data enough to evaluate it. The multipliers are the
/// model ones (`model_duals`), so the vector measured is the vector that gets written. The
/// row scale is read off the kernel row: a model row's coefficient enters the kernel row
/// once per kernel column of that variable with the same magnitude (a split variable
/// contributes `+a` and `−a`), and the sign normalisation negates a whole row, so the
/// largest magnitude is the model row's own. The slack and artificial columns add a `±1`
/// entry to their row, which cannot move a number that is floored at one.
///
/// A row can only be in violation if its multiplier is *negative*, and at an optimum almost
/// none are — the kernel's own convention makes a `≤` row's multiplier come out
/// non-positive and a `≥` row's non-negative, so a negative one is the round-off anomaly
/// this check is about. The matrix is therefore only scanned when there is something to
/// measure, and the state a solve is normally in — every multiplier in order — costs one
/// pass over the rows and no allocation. That saving is exact rather than statistical: a row
/// whose multiplier is non-negative contributes zero to the maximum by definition. What is
/// *not* established is that it shows up on a clock. Repeated runs of one `flugpl` command
/// (12 455 relaxations, no cuts) spread over `1.22`–`1.34` s on this machine, and moving the
/// check between the two forms moved that number inside the same spread, so the cost of
/// either form is below what this measurement can resolve — the row-first form is kept
/// because it is the one whose cost follows the suspicious rows instead of the matrix.
fn State::max_dual_sign_violation(
  self : State,
  duals : Array[Double],
) -> (Double, Int) {
  let problem = self.problem
  let mut suspect = false
  for r = 0; r < problem.nrows; r = r + 1 {
    if self.row_multiplier_is_negative(duals, r) {
      suspect = true
    }
  }
  if !suspect {
    return (0.0, -1)
  }
  // `verify`'s `cost_scale`: the largest objective coefficient of the model, floored at
  // one. The kernel's cost carries the negation of a maximisation, which no magnitude sees.
  let mut cost_scale = 1.0
  for j = 0; j < problem.structural; j = j + 1 {
    let magnitude = @core.fabs(problem.cost[j])
    if magnitude > cost_scale {
      cost_scale = magnitude
    }
  }
  // `verify`'s `row_sign_scale`: the largest coefficient of the row, floored at one. The
  // matrix is column major, so the per-row maxima come out of one pass over its entries.
  let row_scale : Array[Double] = Array::make(problem.nrows, 0.0)
  let pointers = problem.matrix.col_pointers()
  let rows = problem.matrix.row_indices()
  let coefficients = problem.matrix.values_view()
  for j = 0; j < problem.ncols; j = j + 1 {
    let mut k = pointers[j]
    let end = pointers[j + 1]
    while k < end {
      let magnitude = @core.fabs(coefficients[k])
      let row = rows[k]
      if magnitude > row_scale[row] {
        row_scale[row] = magnitude
      }
      k = k + 1
    }
  }
  let mut worst = 0.0
  let mut worst_row = -1
  for r = 0; r < problem.nrows; r = r + 1 {
    if !self.row_multiplier_is_negative(duals, r) {
      continue
    }
    let source = problem.row_source[r]
    let scaled = -duals[source] * @core.fmax(1.0, row_scale[r]) / cost_scale
    if scaled > worst {
      worst = scaled
      worst_row = source
    }
  }
  (worst, worst_row)
}

///|
/// `true` when kernel row `r` carries a model multiplier the convention does not allow:
/// the oriented form of a `≤` or `≥` row takes a non-negative multiplier, and an equality
/// row takes any.
///
/// The predicate is also what keeps `max_dual_sign_violation` cheap: a row that is not a
/// model row, is an equality, or has a non-negative multiplier cannot contribute a
/// violation at all, so a run whose multipliers are all in order never looks at the matrix.
fn State::row_multiplier_is_negative(
  self : State,
  duals : Array[Double],
  r : Int,
) -> Bool {
  let source = self.problem.row_source[r]
  if source < 0 || source >= duals.length() {
    false
  } else if self.problem.row_relation[r] == @model.Rel::Equal {
    false
  } else {
    duals[source] < 0.0
  }
}

///|
/// The recession direction of an unbounded verdict, one entry per model variable.
///
/// In kernel columns the direction is a single vector: the entering column moves by
/// `σ` and the basic variable of row `i` moves by `−σ·dᵢ`, every other non-basic
/// column staying put. Model variables are linear combinations of kernel columns, so
/// the model-side direction is the same combination with the constant offsets
/// dropped — a direction has no offset.
fn State::model_ray(self : State) -> Array[Double] {
  if self.ray_column < 0 {
    return []
  }
  let kernel : Array[Double] = Array::make(self.n, 0.0)
  kernel[self.ray_column] = self.ray_sigma
  for i = 0; i < self.m; i = i + 1 {
    let column = self.basis[i]
    kernel[column] = kernel[column] - self.ray_sigma * self.direction_buffer[i]
  }
  let out : Array[Double] = []
  for m = 0; m < self.problem.var_columns.length(); m = m + 1 {
    let acc = @core.CompensatedSum::new()
    for part in self.problem.var_columns[m] {
      let (column, coefficient) = part
      acc.add(coefficient * kernel[column])
    }
    out.push(acc.value())
  }
  out
}
