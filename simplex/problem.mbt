///|
/// Standard-form construction.
///
/// The kernel only understands `min cᵀx, A x = b, l ≤ x ≤ u`. Everything else the
/// model layer allows is mapped onto that here, and each transformation is
/// written down because two of them move the objective constant:
///
/// | model level construct | kernel level transformation |
/// | --- | --- |
/// | `x ≥ lb` with finite `lb` | substitute `x = lb + y` (`y ≥ 0`): the column's coefficients times `lb` are subtracted from the row right hand sides, and `c·lb` is added to the objective constant |
/// | `x ≤ ub` with finite `ub` | **column upper bound** `y ≤ ub − lb` — the kernel's ratio test handles both bounds, so a bound does not cost a row |
/// | `ub < lb` (contradictory bounds) | the old explicit row `Σ sign·y ≤ ub − lb`, whose negative right hand side makes the run report `Infeasible` instead of handing the kernel a negative range |
/// | unbounded below | split `x = p − n` into two non-negative columns with opposite coefficients and costs; if `ub` is finite as well, the pair gets an explicit row `p − n ≤ ub`, because a difference of two columns has no per-column bound |
/// | `a·x ≤ b` | slack column `+1`, non-negative |
/// | `a·x ≥ b` | surplus column `−1` plus an artificial column `+1` |
/// | `a·x = b` | artificial column `+1` |
/// | row with negative right hand side | the whole row is negated and `≤` / `≥` swapped, so every right hand side is non-negative and a slack or artificial basis always exists |
/// | `maximize` | costs and the objective constant are negated; the sign back to the model's sense is kept in `model_sign` |
///
/// Upper bounds used to be rows too, and on `fast0507` that turned 489 model rows
/// into 63 490 kernel rows. The pivot count follows the kernel's row count, not the
/// column count (measured: a covering LP of 20 / 40 / 120 / 240 rows takes
/// 57 / 137 / 632 / 2 220 pivots at any column count), so those 63 009 extra rows
/// were the whole cost of the instance.

///|
/// The standard-form problem handed to the kernel.
pub struct KernelProblem {
  nrows : Int
  ncols : Int
  /// Number of leading columns that correspond to model variables; the rest are
  /// slack, surplus and artificial columns.
  structural : Int
  matrix : @core.SparseMatrix
  rhs : Array[Double]
  /// Upper bound of every kernel column, in kernel column order. A column's lower
  /// bound is zero for all of them (the model's lower bounds were absorbed into
  /// `var_offset`), so one array is enough. `@model.infinite_bound` means the column
  /// has no upper bound.
  ///
  /// Bounds live here rather than in extra rows: the ratio test reads them both
  /// ways, and a nonbasic variable may sit at either end of its range.
  upper : Array[Double]
  cost : Array[Double]
  is_artificial : Array[Bool]
  /// Reconstruction of a model variable from kernel columns:
  /// `x_j = var_offset[j] + Σ coefficient · y_column`.
  var_columns : Array[Array[(Int, Double)]]
  var_offset : Array[Double]
  /// `min` sense constant added to the kernel objective.
  objective_constant : Double
  /// Multiplier back to the model's sense: `model objective = model_sign · kernel objective`.
  model_sign : Double
  /// Column that starts basic in each row: the slack of a `≤` row, the
  /// artificial column of a `≥` or `=` row. Every right hand side is
  /// non-negative by construction, so this basis is feasible for Phase I.
  initial_basis : Array[Int]
  /// For each kernel row, the model constraint it came from, or `-1` when this
  /// package invented the row (the row form of a free variable's upper bound, or of
  /// bounds that contradict each other).
  ///
  /// The kernel's duals live on its own rows, so a certificate stated against the
  /// model needs this map: a row that is not a model row has no dual to report.
  row_source : Array[Int]
  /// Multiplier that turns the kernel's dual for that row into a multiplier of the
  /// model row's oriented form, which is the convention certificates use. Zero on an
  /// invented row.
  ///
  /// The kernel works on normalized rows (a `≤` row is a slack, a `≥` row a surplus,
  /// a negative right hand side negates the row), and each of those choices moves a
  /// sign: `y_model = ± y_kernel`. Deriving it here, next to the normalization that
  /// caused it, is the only place it can be got right; a reader of a certificate
  /// should not have to redo it.
  row_dual_factor : Array[Double]
  /// `+1` when the kernel row is the model row, `-1` when it is the model row negated
  /// because its right hand side was negative.
  ///
  /// Not the same number as `row_dual_factor`, which also folds in the relation's own
  /// sign (a slack column moves a dual one way, a surplus the other). That factor is
  /// the right one for the *dual* of a row, because a dual is stated against the row's
  /// oriented form. A row multiplier used as a coefficient *of the model row* — which
  /// is what a cut's witness is, `Σ yᵢ·(row i) = row` — needs this one instead, and
  /// reading the factor above for it would put a sign error into every cut taken from a
  /// `≤` row.
  row_sign : Array[Double]
  /// The **model** relation of each kernel row, before the sign normalisation above.
  ///
  /// A certificate's row multipliers carry a sign condition on a `≤` or `≥` row and none at
  /// all on an equality, so a producer that measures its own multipliers against that
  /// convention has to know which model rows are equalities. `row_dual_factor` cannot
  /// answer it — its magnitude is one on every relation — and recovering the relation from
  /// the slack column the assembly happened to add would be reading one field for another,
  /// which is how a cut witness came to carry a sign error on every `≤` row.
  row_relation : Array[@model.Rel]
  /// The model's own objective coefficients, in the minimisation sense `verify` reads them
  /// in (`sense_sign · c`, the same number `verify`'s `dense_cost` accumulates).
  ///
  /// The kernel's cost vector is not this one: it is stated on kernel columns, carries the
  /// negation of a maximisation and the sign of a free variable's split. A certificate is
  /// judged against the *model's* numbers, so a self-check that stands in for the checker has
  /// to measure them — `simplex/certificate.mbt::duality_gap_violation` does, and this is
  /// where it gets them. Carrying them is the point: re-deriving a model coefficient from the
  /// normalized image means composing sign flips that the model layer already made once, and
  /// a producer that measures a *reconstruction* of the checker's input is measuring a
  /// different thing, which is a mistake this project has made three times.
  model_cost : Array[Double]
  /// The model's variable lower bounds, `lⱼ` — not the kernel's, which are all zero because
  /// the model's were absorbed into `var_offset`.
  ///
  /// The duality gap's box minimum is taken over each variable's *own* range, so recovering
  /// `lⱼ` as `var_offset[j]` is right for an ordinary variable and wrong for a variable the
  /// kernel split in two (where the offset is zero and the bound is a row).
  model_lower : Array[Double]
  /// The model's variable upper bounds, `uⱼ`, with `@model.infinite_bound` where there is
  /// none. `upper` is the kernel's column bound, which is `uⱼ − lⱼ` for an ordinary variable
  /// and absent for a split one; this is the number the checker multiplies a reduced cost by.
  model_upper : Array[Double]
  /// The model's own right hand sides, one per model row, in model row order.
  ///
  /// `rhs` is the normalized kernel right hand side, which has the row's sign and every
  /// variable offset folded into it, so the model's `bᵢ` cannot be read back out of it without
  /// re-summing `Σⱼ aᵢⱼ·lⱼ` in an order the model layer did not use.
  model_rhs : Array[Double]
} derive(Debug)

///|
/// Convenience view of the kernel solution for the first `structural` columns.
pub fn KernelProblem::solution(
  self : KernelProblem,
  kernel_values : Array[Double],
) -> Array[Double] {
  let out : Array[Double] = []
  for j = 0; j < self.var_columns.length(); j = j + 1 {
    let mut value = self.var_offset[j]
    let parts = self.var_columns[j]
    for k = 0; k < parts.length(); k = k + 1 {
      let (column, coefficient) = parts[k]
      value = value + coefficient * kernel_values[column]
    }
    out.push(value)
  }
  out
}

///|
/// `true` when the value is the negative infinity sentinel of the model layer.
fn is_unbounded_below(value : Double) -> Bool {
  value <= -1.0e29
}

///|
/// `true` when the value is the positive infinity sentinel of the model layer.
fn is_unbounded_above(value : Double) -> Bool {
  value >= 1.0e29
}

///|
/// `true` when a kernel column has an upper bound this kernel has to respect.
/// Shared with the iteration loop, which asks the same question of every column it
/// prices and of every basic column it limits.
fn kernel_has_upper(value : Double) -> Bool {
  !is_unbounded_above(value)
}

///|
/// The multiplier that turns the kernel's dual for a row into a multiplier of the
/// model row's oriented form (the convention `verify` documents), or zero when the
/// row is not a model row.
///
/// `sign` is `-1` when the kernel row is the negation of the model row. Starting from
/// the identity that makes both sides describe the same reduced costs,
/// `cⱼ − y_kernel·(sign·aᵢⱼ) = cⱼ + y_model·aᵢⱼ` for a `≤` model row and
/// `cⱼ − y_model·aᵢⱼ` for a `≥` or `=` model row, gives the table below. The kernel's
/// convention for its own rows (a slack forces `y ≤ 0` on a `≤` row, a surplus
/// `y ≥ 0` on a `≥` one) is what makes the two agree rather than cancel.
fn dual_factor(source : Int, rel : @model.Rel, sign : Double) -> Double {
  if source < 0 {
    0.0
  } else {
    match rel {
      @model.Rel::LessEqual => -sign
      @model.Rel::GreaterEqual => sign
      @model.Rel::Equal => sign
    }
  }
}

///|
/// Builds the kernel problem for `min cᵀx` subject to `rows` and `x ≥ 0`.
///
/// This is the shape the reference solver in `oracle` accepts as well, which is
/// what makes differential testing between the two possible.
pub fn KernelProblem::from_standard(
  num_vars : Int,
  cost : Array[Double],
  rows : Array[(Array[Double], @model.Rel, Double)],
) -> KernelProblem {
  // Model variables are the first `num_vars` columns, one column each.
  let var_columns : Array[Array[(Int, Double)]] = []
  let var_offset : Array[Double] = []
  let structural_upper : Array[Double] = []
  // The standard form has no model layer of its own: its variables are non-negative with no
  // upper bound, so the model `verify` is handed for a result of this entry point is exactly
  // that. (`oracle/dense_tableau.mbt` solves the same shape, which is what makes the two
  // comparable.)
  let model_lower : Array[Double] = []
  let model_upper : Array[Double] = []
  for j = 0; j < num_vars; j = j + 1 {
    var_columns.push([(j, 1.0)])
    var_offset.push(0.0)
    structural_upper.push(@model.infinite_bound)
    model_lower.push(0.0)
    model_upper.push(@model.infinite_bound)
  }
  let row_entries : Array[Array[(Int, Double)]] = []
  let row_rels : Array[@model.Rel] = []
  let row_rhs : Array[Double] = []
  // The standard-form entry point has no model rows: its rows *are* the caller's.
  let row_sources : Array[Int] = []
  for i = 0; i < rows.length(); i = i + 1 {
    let (coefficients, rel, rhs) = rows[i]
    let entries : Array[(Int, Double)] = []
    for j = 0; j < num_vars && j < coefficients.length(); j = j + 1 {
      if coefficients[j] != 0.0 {
        entries.push((j, coefficients[j]))
      }
    }
    row_entries.push(entries)
    row_rels.push(rel)
    row_rhs.push(rhs)
    row_sources.push(i)
  }
  assemble(
    num_vars, cost, 0.0, 1.0, var_columns, var_offset, structural_upper, row_entries,
    row_rels, row_rhs, row_sources, cost, model_lower, model_upper, row_rhs,
  )
}

///|
/// Builds the kernel problem for a model, applying the transformations listed in
/// the package comment. Returns the reason when the model uses something the
/// kernel deliberately does not accept (integer variables until the branch and
/// bound stage).
pub fn KernelProblem::from_model(
  model : @model.Model,
) -> Result[KernelProblem, String] {
  from_model_with(model, false)
}

///|
/// Same as `from_model`, with the option of treating integer variables as
/// continuous: the LP relaxation of a mixed integer model.
pub fn from_model_with(
  model : @model.Model,
  relax_integrality : Bool,
) -> Result[KernelProblem, String] {
  let nvars = model.num_vars()
  // The multiplier that turns the model's sense into the minimisation the kernel solves, and
  // the same number `verify`'s `sense_sign` returns: a certificate is stated in the model's
  // sense, so both halves of it need this one.
  let model_sign = if model.sense() == @model.Sense::Maximize {
    -1.0
  } else {
    1.0
  }
  // Pass 1: decide a kernel representation for every model variable.
  let var_columns : Array[Array[(Int, Double)]] = []
  let var_offset : Array[Double] = []
  // Upper bound of each structural column, in column order. Only the explicit row
  // case (below) leaves it at infinity.
  let structural_upper : Array[Double] = []
  // The model's own bounds, kept next to the kernel's, because the duality gap is stated
  // over the model's box: a reduced cost points at `lⱼ` or at `uⱼ`, and for a split
  // variable neither is a kernel column bound or an offset.
  let model_lower : Array[Double] = []
  let model_upper : Array[Double] = []
  let mut next_column = 0
  // Row form of an upper bound, used only where a column bound cannot express it:
  // a split pair `p − n ≤ ub`, or bounds that contradict each other.
  let bound_rows : Array[(Array[(Int, Double)], Double)] = []
  for j = 0; j < nvars; j = j + 1 {
    let variable = model.get_var(j)
    model_lower.push(variable.lb)
    model_upper.push(variable.ub)
    if variable.is_int && !relax_integrality {
      return Err(
        "integer variables are not supported by the linear kernel (planned for the branch and bound stage); use SimplexOptions::relaxed() for the LP relaxation",
      )
    }
    if is_unbounded_below(variable.lb) {
      // Split into a positive and a negative part: x = p - n, p, n >= 0.
      let positive = next_column
      let negative = next_column + 1
      next_column = next_column + 2
      var_columns.push([(positive, 1.0), (negative, -1.0)])
      var_offset.push(0.0)
      structural_upper.push(@model.infinite_bound)
      structural_upper.push(@model.infinite_bound)
      if !is_unbounded_above(variable.ub) {
        // A difference of two columns has no per-column bound, so this one stays a
        // row. Splits are the rare case; bounds are the common one.
        bound_rows.push(([(positive, 1.0), (negative, -1.0)], variable.ub))
      }
    } else {
      let column = next_column
      next_column = next_column + 1
      var_columns.push([(column, 1.0)])
      var_offset.push(variable.lb)
      if is_unbounded_above(variable.ub) {
        structural_upper.push(@model.infinite_bound)
      } else if variable.ub >= variable.lb {
        // The ordinary case: `x ≤ ub` becomes the column bound `y ≤ ub − lb`.
        structural_upper.push(variable.ub - variable.lb)
      } else {
        // Contradictory bounds are not a negative range to hand the kernel — they
        // are an infeasibility to prove. Keeping the row form means the run still
        // reports it, with the same right hand side it always did.
        structural_upper.push(@model.infinite_bound)
        bound_rows.push(([(column, 1.0)], variable.ub - variable.lb))
      }
    }
  }
  let structural = next_column
  // Pass 2: rows in kernel-column space. A model row `Σ aⱼ xⱼ rel b` becomes
  // `Σ aⱼ (offsetⱼ + Σ sign·y) rel b`, so the offsets move to the right hand
  // side and each variable contributes one entry per kernel column.
  let row_entries : Array[Array[(Int, Double)]] = []
  let row_rels : Array[@model.Rel] = []
  let row_rhs : Array[Double] = []
  // Which model row each kernel row came from; the rows this package adds below are
  // not model rows and get -1.
  let row_sources : Array[Int] = []
  // The model's own right hand sides, the numbers a certificate's multipliers are paired
  // with. `row_rhs` below is the kernel's: the same row with every variable offset already
  // moved to the other side, which is not a number the checker ever sees.
  let model_rhs : Array[Double] = []
  let mut objective_constant = 0.0
  // The model's objective in the minimisation sense `verify` reads it in. Accumulated in the
  // model's own term order, which is the order `verify`'s `dense_cost` accumulates in, so the
  // two agree digit for digit rather than to within a re-summation.
  let model_cost : Array[Double] = Array::make(nvars, 0.0)
  let model_objective = model.objective()
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    let entries : Array[(Int, Double)] = []
    let mut adjusted_rhs = constraint.rhs
    for k = 0; k < constraint.terms.length(); k = k + 1 {
      let (variable_index, coefficient) = constraint.terms[k]
      if variable_index < 0 || variable_index >= nvars {
        return Err(
          "constraint " +
          constraint.name +
          " refers to a variable that does not exist",
        )
      }
      adjusted_rhs = adjusted_rhs - coefficient * var_offset[variable_index]
      let parts = var_columns[variable_index]
      for p = 0; p < parts.length(); p = p + 1 {
        let (column, sign) = parts[p]
        entries.push((column, coefficient * sign))
      }
    }
    row_entries.push(entries)
    row_rels.push(constraint.rel)
    row_sources.push(i)
    model_rhs.push(constraint.rhs)
    row_rhs.push(adjusted_rhs)
  }
  for k = 0; k < model_objective.length(); k = k + 1 {
    let (variable_index, coefficient) = model_objective[k]
    objective_constant = objective_constant +
      coefficient * var_offset[variable_index]
    model_cost[variable_index] = model_cost[variable_index] +
      model_sign * coefficient
  }
  for b = 0; b < bound_rows.length(); b = b + 1 {
    let (entries, ub) = bound_rows[b]
    row_entries.push(entries)
    row_rels.push(@model.Rel::LessEqual)
    row_rhs.push(ub)
    row_sources.push(-1)
  }
  // Pass 3: objective in kernel columns, negated for a maximisation.
  let kernel_cost : Array[Double] = Array::make(structural, 0.0)
  for k = 0; k < model_objective.length(); k = k + 1 {
    let (variable_index, coefficient) = model_objective[k]
    let parts = var_columns[variable_index]
    for p = 0; p < parts.length(); p = p + 1 {
      let (column, sign) = parts[p]
      kernel_cost[column] = kernel_cost[column] +
        model_sign * coefficient * sign
    }
  }
  Ok(
    assemble(
      structural,
      kernel_cost,
      model_sign * objective_constant,
      model_sign,
      var_columns,
      var_offset,
      structural_upper,
      row_entries,
      row_rels,
      row_rhs,
      row_sources,
      model_cost,
      model_lower,
      model_upper,
      model_rhs,
    ),
  )
}

///|
/// Shared assembly: normalises row signs, adds slack / surplus / artificial
/// columns, and packs the matrix in CSC form.
///
/// `structural_upper` gives the upper bound of each structural column; the columns
/// this function adds (slacks, surpluses, artificials) are all unbounded above,
/// which is what a slack variable is.
///
/// The four `model_*` parameters are the model layer's own numbers, carried through
/// unchanged because a certificate is stated against the model and never against this
/// normal form. They are documented field by field on `KernelProblem`.
fn assemble(
  structural : Int,
  structural_cost : Array[Double],
  objective_constant : Double,
  model_sign : Double,
  var_columns : Array[Array[(Int, Double)]],
  var_offset : Array[Double],
  structural_upper : Array[Double],
  row_entries : Array[Array[(Int, Double)]],
  row_rels : Array[@model.Rel],
  row_rhs : Array[Double],
  row_sources : Array[Int],
  model_cost : Array[Double],
  model_lower : Array[Double],
  model_upper : Array[Double],
  model_rhs : Array[Double],
) -> KernelProblem {
  let m = row_entries.length()
  // Row sign normalisation: every right hand side becomes non-negative, which is
  // what guarantees a starting basis of slacks and artificials. The sign is kept so a
  // dual solution can be mapped back: a negated row's multiplier is the negation of
  // the model row's.
  let rels : Array[@model.Rel] = []
  let rhs : Array[Double] = []
  let rows : Array[Array[(Int, Double)]] = []
  let dual_factors : Array[Double] = []
  let signs : Array[Double] = []
  for i = 0; i < m; i = i + 1 {
    let rel = row_rels[i]
    let value = row_rhs[i]
    if value < 0.0 {
      let flipped = row_entries[i]
      let negated : Array[(Int, Double)] = []
      for k = 0; k < flipped.length(); k = k + 1 {
        let (column, coefficient) = flipped[k]
        negated.push((column, -coefficient))
      }
      rows.push(negated)
      rhs.push(-value)
      dual_factors.push(dual_factor(row_sources[i], rel, -1.0))
      signs.push(-1.0)
      rels.push(
        match rel {
          @model.Rel::LessEqual => @model.Rel::GreaterEqual
          @model.Rel::GreaterEqual => @model.Rel::LessEqual
          @model.Rel::Equal => @model.Rel::Equal
        },
      )
    } else {
      rows.push(row_entries[i])
      rhs.push(value)
      dual_factors.push(dual_factor(row_sources[i], rel, 1.0))
      signs.push(1.0)
      rels.push(rel)
    }
  }
  // Extra columns: one per row (slack) plus surplus and artificial where needed.
  let extra_columns : Array[Array[(Int, Double)]] = []
  let extra_cost : Array[Double] = []
  let extra_artificial : Array[Bool] = []
  // For each row: the column that starts basic (slack, or artificial when the
  // row is an equality or a `≥` row) and the surplus column where one exists.
  let initial_basis_column : Array[Int] = []
  for i = 0; i < m; i = i + 1 {
    let rel = rels[i]
    if rel == @model.Rel::LessEqual {
      initial_basis_column.push(structural + extra_columns.length())
      extra_columns.push([(i, 1.0)])
      extra_cost.push(0.0)
      extra_artificial.push(false)
    } else if rel == @model.Rel::GreaterEqual {
      extra_columns.push([(i, -1.0)])
      extra_cost.push(0.0)
      extra_artificial.push(false)
      initial_basis_column.push(structural + extra_columns.length())
      extra_columns.push([(i, 1.0)])
      extra_cost.push(0.0)
      extra_artificial.push(true)
    } else {
      initial_basis_column.push(structural + extra_columns.length())
      extra_columns.push([(i, 1.0)])
      extra_cost.push(0.0)
      extra_artificial.push(true)
    }
  }
  // Column major packing: structural columns come from the row lists.
  let ncols = structural + extra_columns.length()
  let columns : Array[Array[(Int, Double)]] = []
  for index = 0; index < ncols; index = index + 1 {
    columns.push([])
  }
  for i = 0; i < m; i = i + 1 {
    let entries = rows[i]
    for k = 0; k < entries.length(); k = k + 1 {
      let (column, coefficient) = entries[k]
      columns[column].push((i, coefficient))
    }
  }
  for k = 0; k < extra_columns.length(); k = k + 1 {
    let entries = extra_columns[k]
    for p = 0; p < entries.length(); p = p + 1 {
      let (row, coefficient) = entries[p]
      columns[structural + k].push((row, coefficient))
    }
  }
  let cost : Array[Double] = []
  let is_artificial : Array[Bool] = []
  for j = 0; j < structural; j = j + 1 {
    cost.push(structural_cost[j])
    is_artificial.push(false)
  }
  for k = 0; k < extra_columns.length(); k = k + 1 {
    cost.push(extra_cost[k])
    is_artificial.push(extra_artificial[k])
  }
  // Bounds in kernel column order: the structural ones the caller supplied, then
  // one unbounded entry per column added above.
  let upper : Array[Double] = []
  for j = 0; j < structural; j = j + 1 {
    upper.push(structural_upper[j])
  }
  for k = 0; k < extra_columns.length(); k = k + 1 {
    upper.push(@model.infinite_bound)
  }
  {
    nrows: m,
    ncols,
    structural,
    matrix: @core.SparseMatrix::from_columns(m, columns),
    rhs,
    upper,
    cost,
    is_artificial,
    var_columns,
    var_offset,
    objective_constant,
    model_sign,
    initial_basis: initial_basis_column,
    row_source: row_sources,
    row_dual_factor: dual_factors,
    row_sign: signs,
    row_relation: row_rels,
    model_cost,
    model_lower,
    model_upper,
    model_rhs,
  }
}

///|
/// Column index of the slack (or surplus, for `≥` rows) of row `i`. Used by the
/// kernel to pick a starting basis.
pub fn KernelProblem::slack_row_map(self : KernelProblem) -> Array[Int] {
  let m = self.nrows
  let map : Array[Int] = Array::make(m, -1)
  for j = self.structural; j < self.ncols; j = j + 1 {
    let entries = self.matrix.column(j)
    if entries.length() == 1 && !self.is_artificial[j] {
      map[entries[0].0] = j
    }
  }
  map
}
