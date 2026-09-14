///|
/// Reference implementation: dense two-phase tableau simplex.
///
/// THIS IS NOT THE SHIPPED SOLVER. It exists so that the sparse revised simplex
/// (package `simplex`, a later milestone) has an independent, deliberately naive
/// implementation to be tested against — a differential oracle. Keeping it dense
/// and simple is the point: it is short enough to audit by reading, and it is
/// obviously correct in the cases it supports.
///
/// Supported model class:
///
///   maximize c岬€x   subject to   a岬⑨祤x {鈮? 鈮? =} b岬?   x 鈮?0
///
/// Rows are normalised so the right hand side is non-negative; `鈮 and `=`
/// rows receive surplus / artificial columns and are handled by a Phase I
/// objective. The reference path never exploits sparsity: the tableau is a full
/// `m 脳 (ncol + 1)` dense matrix and the objective row is rebuilt from scratch
/// on every iteration (O(m路ncol) per pivot). That is fine for the small models
/// used in tests, and it removes a whole class of sign bookkeeping bugs.

///|
/// Outcome of the reference solver.
pub(all) enum OracleStatus {
  Optimal
  Infeasible
  Unbounded
  IterationLimit
} derive(Debug, Eq)

///|
/// Reference solver result. `values` is empty unless the status is `Optimal`.
pub struct OracleResult {
  status : OracleStatus
  values : Array[Double]
  objective : Double
  iterations : Int
} derive(Debug)

///|
/// Reduced cost above which a column counts as improving.
let enter_tolerance : Double = 1.0e-9

///|
/// Tableau entry above which a column counts as a legal pivot direction.
let pivot_tolerance : Double = 1.0e-11

///|
/// Artificial variable sum above which Phase I declares infeasibility.
let phase1_tolerance : Double = 1.0e-7

///|
/// Solves the reference problem described in the package comment.
///
/// `objective` has length `num_vars`; each entry of `rows` is
/// `(row coefficients, relation, right hand side)` with row coefficients of
/// length `num_vars`.
pub fn solve_standard(
  num_vars : Int,
  objective : Array[Double],
  rows : Array[(Array[Double], @model.Rel, Double)],
  max_iterations? : Int = 10000,
) -> OracleResult {
  let m = rows.length()
  // Phase 0: normalise every row so its right hand side is non-negative. A `<=`
  // row with a negative right hand side becomes a `>=` row, and vice versa, so
  // that a starting basis always exists.
  let rel : Array[@model.Rel] = []
  let coeff : Array[Array[Double]] = []
  let rhs : Array[Double] = []
  for i = 0; i < m; i = i + 1 {
    let (row_coeff, row_rel, row_rhs) = rows[i]
    let c = row_coeff.copy()
    let mut s = row_rel
    let mut b = row_rhs
    if b < 0.0 {
      for j = 0; j < num_vars; j = j + 1 {
        c[j] = -c[j]
      }
      b = -b
      s = match s {
        @model.Rel::LessEqual => @model.Rel::GreaterEqual
        @model.Rel::GreaterEqual => @model.Rel::LessEqual
        @model.Rel::Equal => @model.Rel::Equal
      }
    }
    rel.push(s)
    coeff.push(c)
    rhs.push(b)
  }
  // Phase 0b: allocate the extra columns (slack / surplus / artificial).
  let slack_col : Array[Int] = []
  let surplus_col : Array[Int] = []
  let artificial_col : Array[Int] = []
  let mut ncol = num_vars
  for i = 0; i < m; i = i + 1 {
    match rel[i] {
      @model.Rel::LessEqual => {
        slack_col.push(ncol)
        surplus_col.push(-1)
        artificial_col.push(-1)
        ncol = ncol + 1
      }
      @model.Rel::GreaterEqual => {
        slack_col.push(-1)
        surplus_col.push(ncol)
        artificial_col.push(ncol + 1)
        ncol = ncol + 2
      }
      @model.Rel::Equal => {
        slack_col.push(-1)
        surplus_col.push(-1)
        artificial_col.push(ncol)
        ncol = ncol + 1
      }
    }
  }
  let width = ncol + 1
  let is_artificial : Array[Bool] = []
  for j = 0; j < ncol; j = j + 1 {
    is_artificial.push(false)
  }
  for i = 0; i < m; i = i + 1 {
    if artificial_col[i] >= 0 {
      is_artificial[artificial_col[i]] = true
    }
  }
  // Phase 0c: fill the tableau.
  let tableau : Array[Array[Double]] = []
  for i = 0; i < m; i = i + 1 {
    let row : Array[Double] = []
    for j = 0; j < width; j = j + 1 {
      row.push(0.0)
    }
    for j = 0; j < num_vars; j = j + 1 {
      row[j] = coeff[i][j]
    }
    if slack_col[i] >= 0 {
      row[slack_col[i]] = 1.0
    }
    if surplus_col[i] >= 0 {
      row[surplus_col[i]] = -1.0
    }
    if artificial_col[i] >= 0 {
      row[artificial_col[i]] = 1.0
    }
    row[ncol] = rhs[i]
    tableau.push(row)
  }
  let basis : Array[Int] = []
  for i = 0; i < m; i = i + 1 {
    if artificial_col[i] >= 0 {
      basis.push(artificial_col[i])
    } else if slack_col[i] >= 0 {
      basis.push(slack_col[i])
    } else {
      basis.push(-1)
    }
  }
  // Phase I: maximise the negative sum of artificial variables, i.e. minimise
  // the total infeasibility of the starting basis.
  let cost1 : Array[Double] = []
  for j = 0; j < ncol; j = j + 1 {
    cost1.push(if is_artificial[j] { -1.0 } else { 0.0 })
  }
  let forbid : Array[Bool] = []
  for j = 0; j < ncol; j = j + 1 {
    forbid.push(false)
  }
  let (code1, iterations1) = iterate(
    tableau, basis, cost1, ncol, forbid, max_iterations,
  )
  if code1 != 0 {
    return {
      status: IterationLimit,
      values: [],
      objective: 0.0,
      iterations: iterations1,
    }
  }
  let mut artificial_sum = 0.0
  for i = 0; i < m; i = i + 1 {
    if is_artificial[basis[i]] {
      artificial_sum = artificial_sum + tableau[i][ncol]
    }
  }
  if artificial_sum > phase1_tolerance {
    return {
      status: Infeasible,
      values: [],
      objective: 0.0,
      iterations: iterations1,
    }
  }
  // Drive any artificial variable that is still basic (at value zero, which
  // means the row is redundant) out of the basis, so that Phase II cannot
  // accidentally move it to a positive value.
  for i = 0; i < m; i = i + 1 {
    if is_artificial[basis[i]] {
      for j = 0; j < ncol; j = j + 1 {
        if !is_artificial[j] && @core.fabs(tableau[i][j]) > 1.0e-9 {
          pivot_at(tableau, basis, i, j, width)
          break
        }
      }
    }
  }
  // Phase II: optimise the real objective. Artificial columns are forbidden as
  // entering columns; they can only stay basic at value zero.
  let cost2 : Array[Double] = []
  for j = 0; j < ncol; j = j + 1 {
    cost2.push(if j < num_vars { objective[j] } else { 0.0 })
  }
  let forbid2 = is_artificial.copy()
  let (code2, iterations2) = iterate(
    tableau, basis, cost2, ncol, forbid2, max_iterations,
  )
  let total_iterations = iterations1 + iterations2
  if code2 == 1 {
    return {
      status: Unbounded,
      values: [],
      objective: 0.0,
      iterations: total_iterations,
    }
  }
  if code2 == 2 {
    return {
      status: IterationLimit,
      values: [],
      objective: 0.0,
      iterations: total_iterations,
    }
  }
  let values : Array[Double] = []
  for j = 0; j < num_vars; j = j + 1 {
    values.push(0.0)
  }
  for i = 0; i < m; i = i + 1 {
    let b = basis[i]
    if b >= 0 && b < num_vars {
      values[b] = tableau[i][ncol]
    }
  }
  let objective_value = objective_of(tableau, basis, cost2, ncol)
  {
    status: Optimal,
    values,
    objective: objective_value,
    iterations: total_iterations,
  }
}

///|
/// Objective value of the current basis: `危 cost[basis岬 路 x_B(i)`.
fn objective_of(
  tableau : Array[Array[Double]],
  basis : Array[Int],
  cost : Array[Double],
  ncol : Int,
) -> Double {
  let acc = @core.CompensatedSum::new()
  for i = 0; i < basis.length(); i = i + 1 {
    acc.add(cost[basis[i]] * tableau[i][ncol])
  }
  acc.value()
}

///|
/// Decides whether `ratio` should replace the current best ratio in the ratio
/// test. A candidate wins when it is meaningfully smaller, or when it is equal
/// within tolerance and belongs to a smaller basic variable index — the second
/// half of Bland's rule.
fn better_ratio(
  ratio : Double,
  best : Double,
  candidate_basis : Int,
  best_basis : Int,
) -> Bool {
  let tol = 1.0e-9 * @core.fmax(@core.fabs(ratio), @core.fabs(best)) + 1.0e-12
  if ratio < best - tol {
    true
  } else if ratio <= best + tol && candidate_basis < best_basis {
    true
  } else {
    false
  }
}

///|
/// Pivots the tableau on `(row, col)` and updates the basis.
fn pivot_at(
  tableau : Array[Array[Double]],
  basis : Array[Int],
  row : Int,
  col : Int,
  width : Int,
) -> Unit {
  let pivot = tableau[row][col]
  for j = 0; j < width; j = j + 1 {
    tableau[row][j] = tableau[row][j] / pivot
  }
  for i = 0; i < tableau.length(); i = i + 1 {
    if i != row {
      let factor = tableau[i][col]
      if factor != 0.0 {
        for j = 0; j < width; j = j + 1 {
          tableau[i][j] = tableau[i][j] - factor * tableau[row][j]
        }
      }
    }
  }
  basis[row] = col
}

///|
/// Runs the tableau simplex to optimality.
///
/// Pivoting rule is Bland's rule (smallest improving column index), which
/// guarantees termination on degenerate problems at the cost of more
/// iterations. Ties in the ratio test are broken by the smallest basic variable
/// index, which is the other half of Bland's rule.
///
/// Returns `(code, iterations)` with code `0` = optimal, `1` = unbounded,
/// `2` = iteration limit reached.
fn iterate(
  tableau : Array[Array[Double]],
  basis : Array[Int],
  cost : Array[Double],
  ncol : Int,
  forbid : Array[Bool],
  max_iterations : Int,
) -> (Int, Int) {
  let m = tableau.length()
  let width = ncol + 1
  let mut iterations = 0
  while iterations < max_iterations {
    // Rebuild the reduced cost row from scratch: z獗?= 危 cost[basis岬路T[i][j].
    let reduced : Array[Double] = []
    for j = 0; j < width; j = j + 1 {
      reduced.push(0.0)
    }
    for i = 0; i < m; i = i + 1 {
      let cb = cost[basis[i]]
      if cb != 0.0 {
        for j = 0; j < width; j = j + 1 {
          reduced[j] = reduced[j] + cb * tableau[i][j]
        }
      }
    }
    // Optimality test for a maximisation: the tableau is optimal when every
    // reduced cost zⱼ − cⱼ is non-negative; an improving column has a negative
    // one. Bland's rule takes the *smallest* such index, which guarantees
    // termination on degenerate problems.
    let mut enter = -1
    for j = 0; j < ncol; j = j + 1 {
      let rc = reduced[j] - cost[j]
      if !forbid[j] && rc < -enter_tolerance && enter < 0 {
        enter = j
      }
    }
    if enter < 0 {
      return (0, iterations)
    }
    // Ratio test. Ties are broken by the smallest basic variable index, which
    // together with Bland's entering rule guarantees termination.
    let mut leave = -1
    let mut best = 0.0
    for i = 0; i < m; i = i + 1 {
      let a = tableau[i][enter]
      if a > pivot_tolerance {
        let ratio = tableau[i][ncol] / a
        if leave < 0 || better_ratio(ratio, best, basis[i], basis[leave]) {
          leave = i
          best = ratio
        }
      }
    }
    if leave < 0 {
      return (1, iterations)
    }
    pivot_at(tableau, basis, leave, enter, width)
    iterations = iterations + 1
  }
  (2, iterations)
}
