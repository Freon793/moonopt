///|
/// What one call to `remove_dominated_columns` removed.
///
/// The count is kept apart from the shape test because the two answer different questions
/// and a caller measuring a run needs both: `columns_compared` being zero says the model is
/// not of the class the reduction is proved for (so nothing was looked at), while zero
/// compared and zero removed with a non-zero comparison count says the class matched and the
/// model had nothing to give.
pub(all) struct DominationStats {
  /// Columns removed because a cheaper column's cover contains this one's.
  columns_removed : Int32
  /// Columns examined for domination; zero when the model is not a 0/1 set-covering model.
  columns_compared : Int32
} derive(Debug, Eq)

///|
/// The model class column dominance is proved on: every row is a `>=` row with all-positive
/// coefficients, every variable is a 0/1 integer, and no cost is negative.
///
/// The last condition is about the replacement rather than the model: the proof below raises
/// `x_A` to one and relies on that never *increasing* the objective, which a negative cost
/// would break. All three are checked before the reduction looks at a single pair of columns,
/// because a reduction proved for one class and run on another is how a solver silently
/// changes the answer (`markshare1` became `infeasible` in one node under a screen that did
/// not classify its rows).
fn set_covering_shape(model : @model.Model) -> Bool {
  let n = model.num_vars()
  if n == 0 {
    return false
  }
  for j = 0; j < n; j = j + 1 {
    let variable = model.get_var(j)
    if !variable.is_int {
      return false
    }
    if !@core.approx_eq(variable.lb, 0.0) || !@core.approx_eq(variable.ub, 1.0) {
      return false
    }
  }
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    if constraint.rel != @model.Rel::GreaterEqual {
      return false
    }
    for term in constraint.terms {
      if !@core.approx_positive(term.1) {
        return false
      }
    }
  }
  for term in model.objective() {
    if @core.approx_negative(term.1) {
      return false
    }
  }
  true
}

///|
/// Whether column `a` dominates column `b` on the rows `b` covers.
///
/// Three conditions, walked over `a`'s cover once because both covers are ascending:
///
/// - `a` covers every row `b` covers,
/// - `a`'s coefficient there is at least `b`'s, and
/// - `a` alone satisfies each of those rows (`a_rA ≥ b_r`).
///
/// The third one is the condition a plain "cover is contained" test is missing, and a
/// right-hand side above one is exactly what makes it necessary. With `x_A = x_B = 1`,
/// removing `b` takes `a_rB` out of row `r` and nothing puts it back: `a` was already one, so
/// it contributes nothing new. Only a column that settles the row by itself survives that
/// case. Dropping this test is not a subtle mistake — measured on the corpus it turned
/// `markshare1` from `node-limit obj=80` into `infeasible` in one node, and `pk1` from
/// `node-limit obj=18` into a wrong `optimal obj=726`.
///
/// The comparisons are exact rather than tolerance-based on purpose: a wrong *acceptance*
/// removes integer points from every node below the cut, while a wrong rejection only leaves a
/// column that could have gone. Exact coefficients from the same model compare equal.
fn dominates(
  cover_a : Array[Int32],
  coef_a : Array[Double],
  cover_b : Array[Int32],
  coef_b : Array[Double],
  rhs : Array[Double],
) -> Bool {
  let mut i = 0
  for k = 0; k < cover_a.length(); k = k + 1 {
    if i < cover_b.length() && cover_a[k] == cover_b[i] {
      let value = coef_a[k]
      if value < coef_b[i] || value < rhs[cover_a[k]] {
        return false
      }
      i = i + 1
    }
  }
  i == cover_b.length()
}

///|
/// Remove every 0/1 set-covering column whose cover is contained in a cheaper column's.
///
/// # The reduction
///
/// For a model `min cᵀx` subject to `Ax ≥ b`, `x ∈ {0,1}ⁿ`, a column `B` can be fixed to zero
/// when some column `A` has `c_A ≤ c_B`, covers every row `B` covers with at least `B`'s
/// coefficient, and settles each of those rows on its own. The witness is a rewrite of any
/// feasible point `x` with `x_B = 1`: set `x_B ← 0` and `x_A ← 1`, leaving everything else.
/// Row `r` then loses `a_rB` and gains `a_rA·(1 − x_A)`, which is non-negative, and where
/// `A` was already one the row is still satisfied because `A` alone carries it. The objective
/// does not rise, because `A` costs no more than `B` and no cost is negative. So every
/// integer point of the original has a point of no greater objective with `x_B = 0`, and the
/// optimal value is unchanged: fixing `B` at zero is exact, not a relaxation.
///
/// The three conditions are not interchangeable and the middle one is what makes the pair
/// argument work at all: containment alone says nothing about *how much* of the row `A`
/// covers.
///
/// # What is returned
///
/// The reduced model, the *original* indices of the removed columns in ascending order (a
/// caller mapping a solution back puts zero in those slots), and what it did. A model that is
/// not of the class above, or one with nothing to give, comes back unchanged with the model
/// it was handed.
///
/// # Why this is not a relaxation
///
/// The caller's answer must be an answer to the model the caller wrote, so the reduced model
/// is not returned as an answer by itself: `mip/search.mbt` solves it and maps the point back,
/// and the mapped point is checked against the *original* model before it is reported.
pub fn remove_dominated_columns(
  model : @model.Model,
) -> (@model.Model, Array[Int32], DominationStats) {
  let n = model.num_vars()
  let m = model.num_constraints()
  let nothing : DominationStats = { columns_removed: 0, columns_compared: 0, }
  if !set_covering_shape(model) {
    return (model, [], nothing)
  }
  // Cost per column. A column the objective does not mention costs nothing, which is a legal
  // cost here (the shape test only forbids negative ones).
  let cost : Array[Double] = []
  for j = 0; j < n; j = j + 1 {
    cost.push(0.0)
  }
  for term in @model.normalize_terms(model.objective()) {
    let (j, value) = term
    cost[j] = cost[j] + value
  }
  // The rows each column covers with its coefficient there, and the columns each row has.
  // Both sides are built in ascending order (rows by the outer loop, columns by
  // `normalize_terms` keeping the model's own order), which is what lets `dominates` walk a
  // cover once instead of searching it.
  let rhs : Array[Double] = []
  let col_rows : Array[Array[Int32]] = []
  let col_coef : Array[Array[Double]] = []
  let row_cols : Array[Array[Int32]] = []
  for i = 0; i < m; i = i + 1 {
    rhs.push(0.0)
    row_cols.push([])
  }
  for j = 0; j < n; j = j + 1 {
    col_rows.push([])
    col_coef.push([])
  }
  for i = 0; i < m; i = i + 1 {
    let constraint = model.constraint(i)
    rhs[i] = constraint.rhs
    for term in @model.normalize_terms(constraint.terms) {
      let (j, value) = term
      col_rows[j].push(i)
      col_coef[j].push(value)
      row_cols[i].push(j)
    }
  }
  let removed : Array[Bool] = []
  for j = 0; j < n; j = j + 1 {
    removed.push(false)
  }
  let mut compared = 0
  let mut removed_count = 0
  for b = 0; b < n; b = b + 1 {
    let cover_b = col_rows[b]
    if cover_b.length() == 0 {
      continue
    }
    // The row of `b` with the fewest columns: every dominator of `b` must appear in all of
    // `b`'s rows, so restricting the search to this one loses nothing and is what keeps the
    // scan from being quadratic in the column count.
    let mut probe = cover_b[0]
    for k = 1; k < cover_b.length(); k = k + 1 {
      if row_cols[cover_b[k]].length() < row_cols[probe].length() {
        probe = cover_b[k]
      }
    }
    compared = compared + 1
    let cost_b = cost[b]
    let mut dominator = -1
    for a in row_cols[probe] {
      if a == b {
        continue
      }
      let cost_a = cost[a]
      if cost_a > cost_b {
        continue
      }
      let cover_a = col_rows[a]
      if cover_a.length() < cover_b.length() {
        continue
      }
      // The order is strict, so a group of same-cost columns with the same cover keeps
      // exactly one representative instead of deleting itself: a cheaper column always
      // dominates, while an equal-cost one needs a strictly larger cover or a smaller index.
      // Without this a screen deletes both halves of every duplicate pair.
      let cheaper = cost_a < cost_b
      if !cheaper && !(cover_a.length() > cover_b.length() || a < b) {
        continue
      }
      if !dominates(cover_a, col_coef[a], cover_b, col_coef[b], rhs) {
        continue
      }
      dominator = a
      break
    }
    if dominator >= 0 {
      removed[b] = true
      removed_count = removed_count + 1
    }
  }
  if removed_count == 0 {
    return (model, [], { columns_removed: 0, columns_compared: compared, })
  }
  // The kept columns, and where each one lands in the reduced model.
  let new_index : Array[Int32] = []
  let mut kept = 0
  for j = 0; j < n; j = j + 1 {
    if removed[j] {
      new_index.push(-1)
    } else {
      new_index.push(kept)
      kept = kept + 1
    }
  }
  let out = @model.Model::new(model.sense())
  for j = 0; j < n; j = j + 1 {
    if removed[j] {
      continue
    }
    let variable = model.get_var(j)
    out.add_var(
      variable.name,
      lb=variable.lb,
      ub=variable.ub,
      is_int=variable.is_int,
    )
    |> ignore
  }
  let objective : Array[(Int32, Double)] = []
  for term in @model.normalize_terms(model.objective()) {
    let (j, value) = term
    if new_index[j] >= 0 {
      objective.push((new_index[j], value))
    }
  }
  out.set_objective(objective)
  for i = 0; i < m; i = i + 1 {
    let constraint = model.constraint(i)
    let terms : Array[(Int32, Double)] = []
    for term in @model.normalize_terms(constraint.terms) {
      let (j, value) = term
      if new_index[j] >= 0 {
        terms.push((new_index[j], value))
      }
    }
    out.add_named_constraint(
      terms,
      constraint.rel,
      constraint.rhs,
      constraint.name,
    )
  }
  let removed_indices : Array[Int32] = []
  for j = 0; j < n; j = j + 1 {
    if removed[j] {
      removed_indices.push(j)
    }
  }
  (
    out,
    removed_indices,
    { columns_removed: removed_count, columns_compared: compared, },
  )
}
