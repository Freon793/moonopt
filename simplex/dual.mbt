///|
/// Bounded-variable dual simplex, used to reoptimize from a basis.
///
/// The primal method needs a *feasible* basis and works to restore optimality; this
/// one needs an *optimal* basis — dual feasible — and works to restore feasibility.
/// That is what makes it the right reoptimization tool after a bound change:
/// tightening a bound leaves every reduced cost alone (they depend on the basis and
/// the objective, not on the bounds), so the previous optimal basis is still dual
/// feasible, and the only thing wrong with it is that some basic value now sits
/// outside its bound.
///
/// One iteration: pick a basic variable outside its bounds, take the corresponding row
/// of `B⁻¹`, and choose the non-basic column that lets that variable come back while
/// keeping the others dual feasible. The choice is the classical dual ratio test —
/// smallest `|rⱼ / αⱼ|`, then, among the columns within a relative band of it, the
/// largest `|αⱼ|` so the pivot is not a numerically weak one.
///
/// Two of this kernel's own choices carry over: the step is computed here and handed
/// to `pivot` (a leaving variable's resting bound decides how its step reads), and a
/// column whose own range is too short to fix the row is flipped to its other bound
/// with no basis change, which is the dual counterpart of the primal flip.
///
/// Codes: `0` optimal, `1` infeasible, `2` iteration limit, `3` numerical failure.

///|
/// The column the dual ratio test picked, with what the pivot needs.
priv struct DualCandidate {
  column : Int
  /// Movement the entering variable has to make, signed: positive at a lower bound,
  /// negative at an upper one.
  movement : Double
}

///|
/// The basic variable furthest outside its bounds, or `-1` when every basic value is
/// feasible — which is where the dual simplex stops.
///
/// The most violated row is the classical choice and it needs no extra state: the
/// alternative, a steepest-edge rule, is an optimization this kernel has no
/// measurement for yet.
fn State::dual_leaving_row(self : State) -> Int {
  let upper = self.problem.upper
  let mut worst = self.options.feasibility_tolerance
  let mut row = -1
  for i = 0; i < self.m; i = i + 1 {
    let value = self.xb[i]
    let cap = upper[self.basis[i]]
    let mut violation = 0.0
    if value < 0.0 {
      violation = -value
    }
    if kernel_has_upper(cap) && value > cap {
      if value - cap > violation {
        violation = value - cap
      }
    }
    if violation > worst {
      worst = violation
      row = i
    }
  }
  row
}

///|
/// `true` when every non-basic column's reduced cost is compatible with the bound it
/// rests at, which is the property the dual simplex needs and the primal one does not.
///
/// A column whose range has collapsed cannot move in either direction, so no sign is
/// required of it: that is the state a branch and bound leaves a variable in when it
/// fixes it, and demanding `rⱼ = 0` there would throw away exactly the warm start this
/// exists for.
fn State::dual_feasible(self : State, tolerance : Double) -> Bool {
  let duals = self.duals()
  let pointers = self.problem.matrix.col_pointers()
  let rows = self.problem.matrix.row_indices()
  let values = self.problem.matrix.values_view()
  let upper = self.problem.upper
  for j = 0; j < self.n; j = j + 1 {
    if self.is_basic[j] || self.forbid[j] {
      continue
    }
    let cap = upper[j]
    if kernel_has_upper(cap) && cap <= 0.0 {
      continue
    }
    let reduced = self.reduced_cost(j, duals, pointers, rows, values)
    let scale = self.reduced_cost_scale(j, pointers, rows, values)
    // At its upper bound the variable may only decrease, so its reduced cost may not
    // be positive; at its lower bound the opposite.
    if self.at_upper[j] {
      if reduced > tolerance * scale {
        return false
      }
    } else if reduced < -tolerance * scale {
      return false
    }
  }
  true
}

///|
/// Scale of one column's reduced cost: the objective coefficient plus what the
/// multipliers can contribute, so a sign decision is judged against the numbers it
/// came from.
fn State::reduced_cost_scale(
  self : State,
  column : Int,
  pointers : ArrayView[Int],
  rows : ArrayView[Int],
  values : ArrayView[Double],
) -> Double {
  let duals = self.duals_buffer
  let mut acc = 0.0
  let mut k = pointers[column]
  let end = pointers[column + 1]
  while k < end {
    acc = acc + @core.fabs(duals[rows[k]] * values[k])
    k = k + 1
  }
  1.0 + @core.fabs(self.cost[column]) + acc
}

///|
/// The dual ratio test: which non-basic column brings the leaving row back, and how
/// far it moves.
///
/// `delta` is the signed change the leaving variable needs (`> 0` when it sits below
/// its lower bound). Moving column `j` by `t` moves that basic value by `−t·α`, so the
/// movement that fixes the row exactly is `t = −delta / α`; a column only qualifies if
/// it can move that way at all, which for a variable at its upper bound means `t < 0`
/// and at its lower bound `t > 0`.
///
/// The ratio `|rⱼ / αⱼ|` is the dual step: the first column whose reduced cost would
/// cross zero limits it. Pass one takes the strict minimum, pass two prefers a large
/// `|αⱼ|` among the columns within a relative band of it — the same shape as the
/// primal ratio test, for the same reason.
fn State::dual_candidate(
  self : State,
  delta : Double,
  weights : Array[Double],
  duals : Array[Double],
) -> DualCandidate {
  let tolerance = self.options.pivot_tolerance
  let pointers = self.problem.matrix.col_pointers()
  let rows = self.problem.matrix.row_indices()
  let values = self.problem.matrix.values_view()
  let upper = self.problem.upper
  let mut ratio_min = 0.0
  let mut found = false
  for j = 0; j < self.n; j = j + 1 {
    if self.is_basic[j] || self.forbid[j] {
      continue
    }
    let cap = upper[j]
    if kernel_has_upper(cap) && cap <= 0.0 {
      continue
    }
    let alpha = self.tableau_entry(j, weights)
    if @core.fabs(alpha) <= tolerance {
      continue
    }
    let movement = -delta / alpha
    if movement > 0.0 {
      if self.at_upper[j] {
        continue
      }
    } else if !self.at_upper[j] {
      continue
    }
    let reduced = self.reduced_cost(j, duals, pointers, rows, values)
    let ratio = @core.fabs(reduced / alpha)
    if !found || ratio < ratio_min {
      ratio_min = ratio
      found = true
    }
  }
  if !found {
    return { column: -1, movement: 0.0, }
  }
  let band = 1.0e-9 * @core.fabs(ratio_min) + tolerance
  let relaxed = ratio_min + band
  let mut chosen = -1
  let mut best_alpha = 0.0
  let mut chosen_alpha = 0.0
  for j = 0; j < self.n; j = j + 1 {
    if self.is_basic[j] || self.forbid[j] {
      continue
    }
    let cap = upper[j]
    if kernel_has_upper(cap) && cap <= 0.0 {
      continue
    }
    let alpha = self.tableau_entry(j, weights)
    if @core.fabs(alpha) <= tolerance {
      continue
    }
    let movement = -delta / alpha
    if movement > 0.0 {
      if self.at_upper[j] {
        continue
      }
    } else if !self.at_upper[j] {
      continue
    }
    let reduced = self.reduced_cost(j, duals, pointers, rows, values)
    let ratio = @core.fabs(reduced / alpha)
    if ratio <= relaxed && (chosen < 0 || @core.fabs(alpha) > best_alpha) {
      chosen = j
      best_alpha = @core.fabs(alpha)
      chosen_alpha = alpha
    }
  }
  if chosen < 0 {
    return { column: -1, movement: 0.0, }
  }
  { column: chosen, movement: -delta / chosen_alpha, }
}

///|
/// Reoptimizes from `basis` with the dual simplex.
///
/// Returns `None` when the basis cannot be used: a shape that does not match this
/// problem, a basis that is not dual feasible (the property the dual simplex needs —
/// a different objective, or a bound that collapsed a column's range on the wrong side,
/// can take it away), or a numerical failure. The caller runs the cold path then, so
/// the warm start is a speedup and never a different answer.
fn solve_from_basis(
  problem : KernelProblem,
  options : SimplexOptions,
  basis : SimplexBasis,
) -> SimplexResult? {
  if basis.nrows != problem.nrows ||
    basis.ncols != problem.ncols ||
    basis.basis.length() != problem.nrows ||
    basis.at_upper.length() != problem.ncols {
    return None
  }
  let state = State::new_with_basis(problem, options, basis)
  if !state.factorized {
    return None
  }
  if !state.dual_feasible(options.feasibility_tolerance) {
    return None
  }
  let code = state.dual_iterate()
  if code == 0 {
    // The dual simplex's correctness argument rests on the basis staying dual feasible
    // while it repairs feasibility. That invariant is maintained by the ratio test, but
    // it is also the one thing whose loss would let the run report a primal-feasible
    // point that is not optimal — so it is checked once at the end, for the price of one
    // pass over the columns, and a failure hands the problem to the cold path rather than
    // reporting an answer nothing can justify.
    if !state.dual_feasible(options.feasibility_tolerance) {
      return None
    }
    return Some(state.finish_optimal())
  }
  if code == 1 {
    // No column can bring an infeasible row back: the model has no feasible point.
    // The dual solution at that point is what proves it, and it is the same Farkas ray
    // shape the cold path reports.
    return Some({
      status: Infeasible,
      values: [],
      objective: 0.0,
      iterations: state.iterations,
      duals: state.farkas_ray(),
      ray: [],
      basis: None,
      message: "no feasible point exists (no column can bring an infeasible row back)",
    })
  }
  // An iteration limit or a numerical failure is not a basis worth reporting as an
  // answer; the cold path gets its own attempt at the problem.
  None
}

///|
/// Runs the dual simplex to primal feasibility.
fn State::dual_iterate(self : State) -> Int {
  if !self.factorized {
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
    let row = self.dual_leaving_row()
    if row < 0 {
      return 0
    }
    let upper = self.problem.upper
    let cap = upper[self.basis[row]]
    let below = self.xb[row] < 0.0
    // Signed: how much the leaving value has to move to reach the bound it missed.
    let delta = if below { -self.xb[row] } else { cap - self.xb[row] }
    // The entering column is chosen with row `row` of the basis inverse as the weight
    // vector, so the tableau entry costs the column's nonzeros and not a full solve.
    let weights = self.inverse_row(row)
    let duals = self.duals()
    let candidate = self.dual_candidate(delta, weights, duals)
    if candidate.column < 0 {
      // Nothing can bring this row back, which is the dual simplex's own statement of
      // infeasibility: no point satisfies the rows. The row that failed is the proof —
      // see `farkas_ray` — and the sign that makes its inner product with the right
      // hand side positive is the sign of the bound the value missed.
      self.dual_ray_row = row
      self.dual_ray_sign = if below { -1.0 } else { 1.0 }
      return 1
    }
    let column = candidate.column
    let movement = candidate.movement
    let d = self.direction(column)
    // No bound flip here, unlike the primal simplex: a flip moves a variable from one
    // bound to the other while leaving its reduced cost where it was, and dual
    // feasibility requires the sign of that reduced cost to match the bound the
    // variable rests at. Flipping would therefore break the property this method
    // maintains — and since the dual simplex is allowed to be *primal* infeasible while
    // it works, the entering variable may overshoot its own bound and be brought back
    // by a later iteration. (The measurement that found this: a warm start on dcmulti
    // claimed optimality 18 units above the cold answer, and the verifier refused its
    // certificate on exactly the flipped variable's sign.)
    self.enter_sigma = if movement > 0.0 { 1.0 } else { -1.0 }
    self.pivot(row, column, d, @core.fabs(movement))
  }
  2
}
