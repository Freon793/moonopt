///|
/// Standard-form construction.
///
/// The kernel only understands `min cᵀx, A x = b, x ≥ 0`. Everything else the
/// model layer allows is mapped onto that here, and each transformation is
/// written down because two of them move the objective constant:
///
/// | model level construct | kernel level transformation |
/// | --- | --- |
/// | `x ≥ lb` with finite `lb` | substitute `x = lb + y` (`y ≥ 0`): the column's coefficients times `lb` are subtracted from the row right hand sides, and `c·lb` is added to the objective constant |
/// | unbounded below | split `x = p − n` into two non-negative columns with opposite coefficients and costs |
/// | `x ≤ ub` with finite `ub` | add an explicit row `Σ sign·y ≤ ub − offset` |
/// | `a·x ≤ b` | slack column `+1`, non-negative |
/// | `a·x ≥ b` | surplus column `−1` plus an artificial column `+1` |
/// | `a·x = b` | artificial column `+1` |
/// | row with negative right hand side | the whole row is negated and `≤` / `≥` swapped, so every right hand side is non-negative and a slack or artificial basis always exists |
/// | `maximize` | costs and the objective constant are negated; the sign back to the model's sense is kept in `model_sign` |
///
/// Free-variable splits and bound rows are the honest cost of not having
/// bounded-variable pivoting yet: they are exact, but they grow the matrix. A
/// bounded-variable ratio test (bound flipping) removes the bound rows later.

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
  for j = 0; j < num_vars; j = j + 1 {
    var_columns.push([(j, 1.0)])
    var_offset.push(0.0)
  }
  let row_entries : Array[Array[(Int, Double)]] = []
  let row_rels : Array[@model.Rel] = []
  let row_rhs : Array[Double] = []
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
  }
  assemble(
    num_vars, cost, 0.0, 1.0, var_columns, var_offset, row_entries, row_rels, row_rhs,
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
  // Pass 1: decide a kernel representation for every model variable.
  let var_columns : Array[Array[(Int, Double)]] = []
  let var_offset : Array[Double] = []
  let mut next_column = 0
  // Bound rows are collected as (linear form over kernel columns, ub).
  let bound_rows : Array[(Array[(Int, Double)], Double)] = []
  for j = 0; j < nvars; j = j + 1 {
    let variable = model.get_var(j)
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
      if !is_unbounded_above(variable.ub) {
        bound_rows.push(([(positive, 1.0), (negative, -1.0)], variable.ub))
      }
    } else {
      let column = next_column
      next_column = next_column + 1
      var_columns.push([(column, 1.0)])
      var_offset.push(variable.lb)
      if !is_unbounded_above(variable.ub) {
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
  let mut objective_constant = 0.0
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
    row_rhs.push(adjusted_rhs)
  }
  for k = 0; k < model_objective.length(); k = k + 1 {
    let (variable_index, coefficient) = model_objective[k]
    objective_constant = objective_constant +
      coefficient * var_offset[variable_index]
  }
  for b = 0; b < bound_rows.length(); b = b + 1 {
    let (entries, ub) = bound_rows[b]
    row_entries.push(entries)
    row_rels.push(@model.Rel::LessEqual)
    row_rhs.push(ub)
  }
  // Pass 3: objective in kernel columns, negated for a maximisation.
  let kernel_cost : Array[Double] = Array::make(structural, 0.0)
  let model_sign = if model.sense() == @model.Sense::Maximize {
    -1.0
  } else {
    1.0
  }
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
      row_entries,
      row_rels,
      row_rhs,
    ),
  )
}

///|
/// Shared assembly: normalises row signs, adds slack / surplus / artificial
/// columns, and packs the matrix in CSC form.
fn assemble(
  structural : Int,
  structural_cost : Array[Double],
  objective_constant : Double,
  model_sign : Double,
  var_columns : Array[Array[(Int, Double)]],
  var_offset : Array[Double],
  row_entries : Array[Array[(Int, Double)]],
  row_rels : Array[@model.Rel],
  row_rhs : Array[Double],
) -> KernelProblem {
  let m = row_entries.length()
  // Row sign normalisation: every right hand side becomes non-negative, which is
  // what guarantees a starting basis of slacks and artificials.
  let rels : Array[@model.Rel] = []
  let rhs : Array[Double] = []
  let rows : Array[Array[(Int, Double)]] = []
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
  {
    nrows: m,
    ncols,
    structural,
    matrix: @core.SparseMatrix::from_columns(m, columns),
    rhs,
    cost,
    is_artificial,
    var_columns,
    var_offset,
    objective_constant,
    model_sign,
    initial_basis: initial_basis_column,
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
