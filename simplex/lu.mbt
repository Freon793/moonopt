///|
/// Sparse LU of the basis: `P·B = L·U`, with row pivoting and the columns kept in
/// basis order.
///
/// The kernel used to invert the basis densely, and that is what capped the problem
/// size: an `m x m` inverse costs `m²` doubles, so MIPLIB's fast0507 (63 490 kernel
/// rows) would have asked for 30 GB, and the row gate had to refuse it. The factors
/// instead cost `O(nnz(B) + fill)`, and every solve the simplex needs becomes a
/// triangular solve against them: `B x = b` and `Bᵀ y = c` for the direction, the
/// duals and a row of `B⁻¹`.
///
/// The factorization is left-looking with a dense accumulator: column `k` is
/// scattered into a work vector, the earlier columns of `L` are subtracted from it
/// in order, the first `k` entries that survive are column `k` of `U`, and the rest
/// become column `k` of `L` once divided by the pivot. Row pivoting picks the
/// largest magnitude left in the column, with entries below a relative threshold
/// dropped as noise; if nothing usable is left the basis is singular and the caller
/// is told so instead of being handed factors that are not.
///
/// Both row and column views of `L` and `U` are kept. The forward and backward
/// solves walk rows; the transposed solves walk columns, and building both layouts
/// once is cheaper and far easier to check than transposing on the fly.

///|
/// A factorized basis.
priv struct BasisLu {
  m : Int
  /// `row_at[position]` is the original row now sitting at that position.
  row_at : Array[Int]
  l_rows : Array[Array[(Int, Double)]]
  u_rows : Array[Array[(Int, Double)]]
  l_columns : Array[Array[(Int, Double)]]
  u_columns : Array[Array[(Int, Double)]]
}

///|
/// Factors a basis given one sparse column per basis position.
///
/// `tolerance` is relative to the largest magnitude left in the column being
/// eliminated. Returns `None` when no pivot clears it, which is what a singular
/// basis looks like from here, and also when the factors would exceed
/// `entry_budget`: fill is the one thing about a sparse factorization that cannot
/// be predicted from the row count, and a dense-in-disguise basis would otherwise
/// allocate without limit — the same failure mode the dense inverse had, only
/// harder to see coming.
fn factorize_basis(
  columns : Array[Array[(Int, Double)]],
  m : Int,
  tolerance : Double,
  entry_budget : Int,
) -> BasisLu? {
  let row_at : Array[Int] = []
  let position_of : Array[Int] = []
  for i = 0; i < m; i = i + 1 {
    row_at.push(i)
    position_of.push(i)
  }
  let work : Array[Double] = Array::make(m, 0.0)
  // `L`'s entries are recorded against the **original row**, not the position they
  // happen to occupy. A row pivot in a later step swaps two positions, and a
  // position-numbered column would silently point at the wrong row afterwards —
  // that is exactly the bug this shape avoids. The position is looked up when the
  // entry is used (`position_of`, always current) and the solve views are built
  // once at the end, when every swap has happened.
  let l_entries : Array[Array[(Int, Double)]] = []
  let u_columns : Array[Array[(Int, Double)]] = []
  let mut entries = 0
  for k = 0; k < m; k = k + 1 {
    for entry in columns[k] {
      let (row, value) = entry
      let position = position_of[row]
      work[position] = work[position] + value
    }
    // Left-looking update: subtract the effect of the steps already taken, in the
    // order they were taken. After this, entries below `k` are exactly the column
    // of `U` and entries from `k` on are the column of `L` waiting to be divided.
    let upper : Array[(Int, Double)] = []
    for j = 0; j < k; j = j + 1 {
      let multiplier = work[j]
      if multiplier != 0.0 {
        upper.push((j, multiplier))
        for entry in l_entries[j] {
          let (row, value) = entry
          let position = position_of[row]
          work[position] = work[position] - value * multiplier
        }
        work[j] = 0.0
      }
    }
    let mut column_max = 0.0
    for position = k; position < m; position = position + 1 {
      let magnitude = @core.fabs(work[position])
      if magnitude > column_max {
        column_max = magnitude
      }
    }
    if column_max <= 0.0 {
      return None
    }
    let cutoff = column_max * tolerance
    let mut pivot_position = -1
    let mut pivot_magnitude = 0.0
    for position = k; position < m; position = position + 1 {
      let magnitude = @core.fabs(work[position])
      if magnitude >= cutoff && magnitude > pivot_magnitude {
        pivot_position = position
        pivot_magnitude = magnitude
      }
    }
    if pivot_position < 0 {
      return None
    }
    if pivot_position != k {
      let swapped = row_at[k]
      row_at[k] = row_at[pivot_position]
      row_at[pivot_position] = swapped
      position_of[row_at[k]] = k
      position_of[row_at[pivot_position]] = pivot_position
      let value = work[k]
      work[k] = work[pivot_position]
      work[pivot_position] = value
    }
    let pivot = work[k]
    let lower : Array[(Int, Double)] = []
    for position = k; position < m; position = position + 1 {
      let value = work[position]
      work[position] = 0.0
      if value != 0.0 {
        if position == k {
          upper.push((position, value))
        } else {
          lower.push((row_at[position], value / pivot))
        }
      }
    }
    l_entries.push(lower)
    u_columns.push(upper)
    entries = entries + lower.length() + upper.length()
    if entries > entry_budget {
      return None
    }
  }
  let l_rows : Array[Array[(Int, Double)]] = []
  let l_columns : Array[Array[(Int, Double)]] = []
  let u_rows : Array[Array[(Int, Double)]] = []
  for position = 0; position < m; position = position + 1 {
    l_rows.push([])
    l_columns.push([])
    u_rows.push([])
  }
  for k = 0; k < m; k = k + 1 {
    for entry in l_entries[k] {
      let (row, value) = entry
      let position = position_of[row]
      l_columns[k].push((position, value))
      l_rows[position].push((k, value))
    }
    for entry in u_columns[k] {
      let (position, value) = entry
      u_rows[position].push((k, value))
    }
  }
  Some({ m, row_at, l_rows, u_rows, l_columns, u_columns, })
}

///|
/// Solves `B x = b` in place, using `work` as scratch.
///
/// `b` is permuted into `work` first, so the caller's vector is only overwritten at
/// the end: the simplex passes its own direction buffer here, and the buffers are
/// reused every iteration on purpose.
fn BasisLu::solve_into(
  self : BasisLu,
  b : Array[Double],
  work : Array[Double],
) -> Unit {
  let m = self.m
  for position = 0; position < m; position = position + 1 {
    work[position] = b[self.row_at[position]]
  }
  // Forward solve `L y = P b`: `L` is unit lower triangular, and `l_rows[p]` holds
  // the entries of row `p` with column index below `p`.
  for p = 0; p < m; p = p + 1 {
    let mut value = work[p]
    for entry in self.l_rows[p] {
      let (j, coefficient) = entry
      value = value - coefficient * work[j]
    }
    work[p] = value
  }
  // Backward solve `U x = y`.
  let mut p = m - 1
  while p >= 0 {
    let mut value = 0.0
    let mut diagonal = 1.0
    for entry in self.u_rows[p] {
      let (k, coefficient) = entry
      if k == p {
        diagonal = coefficient
      } else {
        value = value + coefficient * work[k]
      }
    }
    work[p] = (work[p] - value) / diagonal
    p = p - 1
  }
  for position = 0; position < m; position = position + 1 {
    b[position] = work[position]
  }
}

///|
/// Solves `Bᵀ y = c` in place, using `work` as scratch.
///
/// This is what the duals and a row of `B⁻¹` need, and it is the transposed walk:
/// first `Uᵀ w = c` through the columns of `U`, then `Lᵀ v = w` through the columns
/// of `L`, then the row permutation is undone.
fn BasisLu::solve_transpose_into(
  self : BasisLu,
  c : Array[Double],
  work : Array[Double],
) -> Unit {
  let m = self.m
  // Forward solve `Uᵀ w = c`: column `k` of `U` gives `w[k]`.
  for k = 0; k < m; k = k + 1 {
    let mut value = c[k]
    let mut diagonal = 1.0
    for entry in self.u_columns[k] {
      let (row, coefficient) = entry
      if row == k {
        diagonal = coefficient
      } else {
        value = value - coefficient * work[row]
      }
    }
    work[k] = value / diagonal
  }
  // Backward solve `Lᵀ v = w`.
  let mut k = m - 1
  while k >= 0 {
    let mut value = work[k]
    for entry in self.l_columns[k] {
      let (position, coefficient) = entry
      value = value - coefficient * work[position]
    }
    work[k] = value
    k = k - 1
  }
  for position = 0; position < m; position = position + 1 {
    c[self.row_at[position]] = work[position]
  }
}
