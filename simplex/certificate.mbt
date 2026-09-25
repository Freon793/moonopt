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
/// `true` when a model variable has a real lower bound, by the same rule `verify` uses.
///
/// The comparison is `verify`'s, threshold and all, rather than a tolerance of this file's
/// own: a producer that judges "is there a bound here" differently from the checker can put a
/// term into the bound it is about to claim that the checker leaves out, or the reverse, and
/// the two would then be measuring different numbers while both look right.
fn model_has_lower(lb : Double) -> Bool {
  !is_unbounded_below(lb)
}

///|
/// `true` when a model variable has a real upper bound, by the same rule `verify` uses.
fn model_has_upper(ub : Double) -> Bool {
  !is_unbounded_above(ub)
}

///|
/// The model-space reduced cost of one variable and the scale `verify` judges it against,
/// both read out of the kernel column the variable came from.
///
/// `verify` states these over the model's rows, in the model's numbers:
///
///   `rⱼ = cⱼ + Σ_{≤} yᵢaᵢⱼ − Σ_{≥} yᵢaᵢⱼ − Σ_{=} yᵢaᵢⱼ`, accumulated in ascending row
///   order with plain addition, and `scaleⱼ = 1 + |cⱼ| + Σᵢ|aᵢⱼyᵢ|` with compensated
///   summation.
///
/// Both are reproduced here term for term rather than re-derived. The coefficients come out
/// of the kernel's column instead of the model's row: a kernel entry for model variable `j` is
/// `±aᵢⱼ` — the column bound shift contributes a sign, the row's own sign normalisation
/// another, and a free variable's split a third, all of them `±1` — and multiplying a float by
/// `±1` is exact, so the value that comes back is the model's coefficient and not a
/// re-computation of it. The order comes out right too: `normalize_terms` merges a row's terms
/// and sorts them by variable index, one term per variable, so a column's entries are already
/// the model rows in ascending order, which is the order `verify` accumulates in.
///
/// The one place the two can part company is a row that lists the same variable twice: the
/// model layer sums those into one term, while the kernel's CSC packing merges the two entries
/// of the same column-and-row pair, so this adds `yᵢ·(a + b)` where `verify` adds `yᵢ·a +
/// yᵢ·b`. That is a rounding of the last place rather than a different quantity, and it cannot
/// be removed without giving the kernel a second copy of the matrix.
fn State::model_reduced_cost(
  self : State,
  j : Int,
  duals : Array[Double],
) -> (Double, Double) {
  let problem = self.problem
  // Any part of the variable names the same rows with the same magnitudes; the first is the
  // one whose sign the assembly recorded in `var_columns`.
  let (column, part_sign) = problem.var_columns[j][0]
  let mut reduced = problem.model_cost[j]
  let scale_acc = @core.CompensatedSum::new()
  let pointers = problem.matrix.col_pointers()
  let rows = problem.matrix.row_indices()
  let values = problem.matrix.values_view()
  let mut k = pointers[column]
  let end = pointers[column + 1]
  while k < end {
    let row = rows[k]
    let source = problem.row_source[row]
    if source >= 0 && source < duals.length() {
      let coefficient = values[k] * problem.row_sign[row] * part_sign
      // A row with a zero multiplier contributes nothing, which is also how `verify` skips it.
      // The zero is skipped rather than added so that a `-0.0` cannot turn into a `+0.0`.
      if duals[source] != 0.0 {
        let sign = match problem.row_relation[row] {
          @model.Rel::LessEqual => 1.0
          @model.Rel::GreaterEqual => -1.0
          @model.Rel::Equal => -1.0
        }
        reduced = reduced + sign * duals[source] * coefficient
      }
      scale_acc.add(@core.fabs(coefficient * duals[source]))
    }
    k = k + 1
  }
  (reduced, 1.0 + @core.fabs(problem.model_cost[j]) + scale_acc.value())
}

///|
/// The duality gap this run's multipliers give — `|primal − L| / (1 + |primal| + |L|)`, with
/// `L` the Lagrangian bound of `min cᵀx` over the box the variables live in — together with
/// the two numbers it is made of.
///
/// This is the third of the three measurements an optimality proof consists of, and the last
/// one the kernel was not making. The residual check says the point satisfies the rows; the
/// sign check says the multipliers can be read in the convention a certificate is written in;
/// neither says the *bound those multipliers prove* meets the *objective that point has*, and
/// that equality is the whole content of an optimality claim. A basis can satisfy the first
/// two and miss the third: on MIPLIB's `noswot`, node 6454 of a branch and bound run, the
/// multipliers of a 182 row relaxation proved a bound `1.2169280658914303e-7` short of the
/// objective the relaxation claimed, against a tolerance of `1e-7` — a certificate that is
/// *nearly* a proof, which the independent checker refused and which therefore stopped the
/// whole search. Measuring it here is the same argument that put the residual and sign checks
/// here: a producer that has not measured what it is about to claim cannot tell a run with
/// nothing to say from one with something wrong to say, and only the kernel can repair the
/// digits (`refactorize`) before it gives up on the relaxation.
///
/// Every operand is the model's own, carried through the standard-form construction rather
/// than reconstructed from it (`KernelProblem::model_cost`, `model_lower`, `model_upper`,
/// `model_rhs`), which is what makes this *the same measurement* as the checker's rather than a
/// second opinion about it. The tolerance is the run's feasibility tolerance, the number the
/// callers of this kernel hand the checker for the same purpose.
///
/// The "no finite bound" answer is the checker's too: a reduced cost that points at a
/// direction the variable can travel forever gives no bound, and the gap is reported as the
/// sentinel `1e300` that fails any tolerance rather than as a number that might pass one.
fn State::duality_gap_violation(
  self : State,
  model_values : Array[Double],
  duals : Array[Double],
) -> (Double, Double, Double) {
  let problem = self.problem
  let tolerance = self.options.feasibility_tolerance
  let nvars = problem.var_columns.length()
  // `primal = Σⱼ costⱼ·xⱼ`, in the minimisation sense, over the model's variables.
  let primal_acc = @core.CompensatedSum::new()
  for j = 0; j < nvars && j < model_values.length(); j = j + 1 {
    primal_acc.add(problem.model_cost[j] * model_values[j])
  }
  let primal = primal_acc.value()
  // `D = −Σ_{≤} yᵢbᵢ + Σ_{≥} yᵢbᵢ + Σ_{=} yᵢbᵢ`, in model row order.
  let constant_acc = @core.CompensatedSum::new()
  for row = 0; row < problem.nrows; row = row + 1 {
    let source = problem.row_source[row]
    if source >= 0 &&
      source < duals.length() &&
      source < problem.model_rhs.length() {
      let sign = match problem.row_relation[row] {
        @model.Rel::LessEqual => -1.0
        @model.Rel::GreaterEqual => 1.0
        @model.Rel::Equal => 1.0
      }
      constant_acc.add(sign * duals[source] * problem.model_rhs[source])
    }
  }
  // `Σⱼ min over [lⱼ, uⱼ] of rⱼ·xⱼ`. The direction is decided at the tolerance; the value
  // follows the bound that direction points at, whenever there is one — a reduced cost inside
  // the band is round-off as a direction and still worth `|bound| · |rⱼ|` as a number.
  let box_acc = @core.CompensatedSum::new()
  let mut unbounded = false
  for j = 0; j < nvars; j = j + 1 {
    let (reduced, scale) = self.model_reduced_cost(j, duals)
    if reduced > tolerance * scale {
      if !model_has_lower(problem.model_lower[j]) {
        unbounded = true
        break
      }
      box_acc.add(problem.model_lower[j] * reduced)
    } else if reduced < -tolerance * scale {
      if !model_has_upper(problem.model_upper[j]) {
        unbounded = true
        break
      }
      box_acc.add(problem.model_upper[j] * reduced)
    } else if reduced > 0.0 {
      if model_has_lower(problem.model_lower[j]) {
        box_acc.add(problem.model_lower[j] * reduced)
      }
    } else if reduced < 0.0 {
      if model_has_upper(problem.model_upper[j]) {
        box_acc.add(problem.model_upper[j] * reduced)
      }
    }
  }
  if unbounded {
    return (1.0e300, primal, -1.0e300)
  }
  let bound = box_acc.value() + constant_acc.value()
  let gap = @core.fabs(primal - bound) /
    (1.0 + @core.fabs(primal) + @core.fabs(bound))
  (gap, primal, bound)
}

///|
/// Whether a Phase I optimum may be read as an infeasibility proof.
///
/// Phase I minimises the artificial sum subject to `A x + a = b`, so at its optimum the
/// artificials are exactly what makes the rows hold: for a row the point violates by `v`, the
/// artificial in it is `v`. The total artificial value therefore cannot be *smaller* than the
/// largest violation it is supposed to be explaining — `Σ a ≥ max v` is what the two
/// measurements have to satisfy before one of them can be read as a proof by the other.
///
/// That is not a formality. On MIPLIB's `noswot`, node 1558 (a 212 row relaxation) measured a
/// raw row violation of `1.94e-6` while Phase I's artificials totalled `1.2e-11` — five orders
/// of magnitude apart, about the same rows — and the dual solution offered as the Farkas ray
/// for it certified nothing at all: the independent checker measured a margin of exactly zero.
/// A point Phase I satisfied to eleven digits is not a point that violates the rows, so there
/// is no certificate to write; a producer that writes one anyway hands the checker a claim it
/// has to refuse, which stops a search that had nothing wrong with it.
///
/// `infeasibility_margin` is the same factor the residual test uses, on purpose: the two
/// measurements come out of the same arithmetic and have to be judged on that footing rather
/// than against a constant of their own.
fn infeasibility_is_certified(
  artificial_sum : Double,
  raw_residual : Double,
) -> Bool {
  artificial_sum * infeasibility_margin >= raw_residual
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
