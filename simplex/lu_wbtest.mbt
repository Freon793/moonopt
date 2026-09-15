///|
/// The sparse factorization is checked against the dense inverse the kernel used
/// to carry, on random sparse matrices: the factors have to reproduce the matrix
/// (`P·B = L·U`), both solves have to agree with the dense one, and a singular
/// basis has to be refused rather than factored into something plausible.

///|
/// Deterministic generator, same shape as the other suites so a failing case can be
/// reproduced from its seed.
priv struct LuLcg {
  mut state : Int
}

///|
/// Creates a generator from a seed.
fn LuLcg::new(seed : Int) -> LuLcg {
  { state: seed % 100003, }
}

///|
/// Next raw value in `[0, 100003)`.
fn LuLcg::next(self : LuLcg) -> Int {
  self.state = (self.state * 31 + 17) % 100003
  self.state
}

///|
/// Next value in `[0, bound)`.
fn LuLcg::below(self : LuLcg, bound : Int) -> Int {
  if bound <= 1 {
    0
  } else {
    self.next() % bound
  }
}

///|
/// Sparsity pattern of the test matrices, in percent.
fn LuLcg::percent(self : LuLcg) -> Int {
  self.below(100)
}

///|
/// Builds a random sparse matrix as both a dense copy and sparse columns.
fn random_matrix(
  lcg : LuLcg,
  m : Int,
  density_percent : Int,
) -> (Array[Array[Double]], Array[Array[(Int, Double)]]) {
  let dense : Array[Array[Double]] = []
  let columns : Array[Array[(Int, Double)]] = []
  for column = 0; column < m; column = column + 1 {
    columns.push([])
  }
  for row = 0; row < m; row = row + 1 {
    let line : Array[Double] = []
    for column = 0; column < m; column = column + 1 {
      let value = if row < column && row == column - 1 {
        // A guaranteed sub-diagonal keeps the matrix non-singular often enough for
        // the pivoting to be exercised rather than refused.
        Double::from_int(1 + lcg.below(9))
      } else if lcg.percent() < density_percent {
        Double::from_int(1 + lcg.below(9))
      } else {
        0.0
      }
      line.push(value)
      if value != 0.0 {
        columns[column].push((row, value))
      }
    }
    dense.push(line)
  }
  (dense, columns)
}

///|
/// One entry of `L·U`, computed straight from the stored views.
fn factor_entry(lu : BasisLu, row : Int, column : Int) -> Double {
  let mut total = 0.0
  // L[row][k]: the unit diagonal at k == row, otherwise whatever `l_rows[row]` has.
  for entry in lu.l_rows[row] {
    let (k, coefficient) = entry
    total = total + coefficient * upper_entry(lu, k, column)
  }
  total = total + upper_entry(lu, row, column)
  total
}

///|
/// `U[row][column]`, zero outside the triangle the factors cover.
fn upper_entry(lu : BasisLu, row : Int, column : Int) -> Double {
  if column < row {
    return 0.0
  }
  for entry in lu.u_rows[row] {
    let (k, coefficient) = entry
    if k == column {
      return coefficient
    }
  }
  0.0
}

///|
/// Matrix-vector product against sparse columns.
fn multiply_columns(
  columns : Array[Array[(Int, Double)]],
  m : Int,
  x : Array[Double],
) -> Array[Double] {
  let out : Array[Double] = Array::make(m, 0.0)
  for column = 0; column < m; column = column + 1 {
    for entry in columns[column] {
      let (row, value) = entry
      out[row] = out[row] + value * x[column]
    }
  }
  out
}

///|
/// Transposed matrix-vector product against sparse columns.
fn multiply_columns_transpose(
  columns : Array[Array[(Int, Double)]],
  m : Int,
  y : Array[Double],
) -> Array[Double] {
  let out : Array[Double] = Array::make(m, 0.0)
  for column = 0; column < m; column = column + 1 {
    let mut total = 0.0
    for entry in columns[column] {
      let (row, value) = entry
      total = total + value * y[row]
    }
    out[column] = total
  }
  out
}

///|
/// Dense Gauss-Jordan inverse, kept here as the reference the sparse factors are
/// compared against. It lives in the test file on purpose: the kernel itself no
/// longer carries a dense inverse, and a reference that ships with the solver is
/// not much of a reference.
fn dense_inverse(
  matrix : Array[Array[Double]],
  m : Int,
) -> Array[Array[Double]]? {
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
  for column = 0; column < m; column = column + 1 {
    let mut best = column
    let mut best_absolute = @core.fabs(augmented[column][column])
    for i = column + 1; i < m; i = i + 1 {
      let candidate = @core.fabs(augmented[i][column])
      if candidate > best_absolute {
        best = i
        best_absolute = candidate
      }
    }
    if best_absolute < 1.0e-12 {
      return None
    }
    if best != column {
      let swapped = augmented[best]
      augmented[best] = augmented[column]
      augmented[column] = swapped
    }
    let pivot = augmented[column][column]
    for k = 0; k < width; k = k + 1 {
      augmented[column][k] = augmented[column][k] / pivot
    }
    for i = 0; i < m; i = i + 1 {
      if i != column {
        let factor = augmented[i][column]
        if factor != 0.0 {
          for k = 0; k < width; k = k + 1 {
            augmented[i][k] = augmented[i][k] - factor * augmented[column][k]
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
/// The factors have to reproduce the matrix they came from, row permutation and
/// all: `(P·B)[p][j] == (L·U)[p][j]`.
test "the factors reproduce the permuted matrix" {
  let lcg = LuLcg::new(20260915)
  let m = 24
  let (dense, columns) = random_matrix(lcg, m, 35)
  let lu = match factorize_basis(columns, m, 1.0e-9, 1000000) {
    Some(factors) => factors
    None => fail("a non-singular test matrix was refused")
  }
  for row = 0; row < m; row = row + 1 {
    for column = 0; column < m; column = column + 1 {
      let permuted = dense[lu.row_at[row]][column]
      let from_factors = factor_entry(lu, row, column)
      assert_true(
        @core.approx_eq(permuted, from_factors, rel=1.0e-8, abs=1.0e-8),
      )
    }
  }
}

///|
/// Both solves have to agree with the dense inverse the kernel used to build.
test "both solves agree with the dense inverse" {
  let lcg = LuLcg::new(424242)
  for sample = 0; sample < 12; sample = sample + 1 {
    let m = 6 + lcg.below(20)
    let (dense, columns) = random_matrix(lcg, m, 30)
    let lu = match factorize_basis(columns, m, 1.0e-9, 1000000) {
      Some(factors) => factors
      None => continue
    }
    let inverse = match dense_inverse(dense, m) {
      Some(matrix) => matrix
      None => continue
    }
    let rhs : Array[Double] = []
    for i = 0; i < m; i = i + 1 {
      rhs.push(Double::from_int(1 + lcg.below(9)))
    }
    let by_lu = rhs.copy()
    let scratch : Array[Double] = Array::make(m, 0.0)
    lu.solve_into(by_lu, scratch)
    let by_dense : Array[Double] = Array::make(m, 0.0)
    for i = 0; i < m; i = i + 1 {
      let acc = @core.CompensatedSum::new()
      for k = 0; k < m; k = k + 1 {
        acc.add(inverse[i][k] * rhs[k])
      }
      by_dense[i] = acc.value()
    }
    for i = 0; i < m; i = i + 1 {
      assert_true(
        @core.approx_eq(by_lu[i], by_dense[i], rel=1.0e-7, abs=1.0e-7),
      )
    }
    // The transposed solve, the same way: `B⁻ᵀ c` against the dense transpose.
    let transposed = rhs.copy()
    let scratch_transpose : Array[Double] = Array::make(m, 0.0)
    lu.solve_transpose_into(transposed, scratch_transpose)
    let by_dense_transpose : Array[Double] = Array::make(m, 0.0)
    for j = 0; j < m; j = j + 1 {
      let acc = @core.CompensatedSum::new()
      for k = 0; k < m; k = k + 1 {
        acc.add(inverse[k][j] * rhs[k])
      }
      by_dense_transpose[j] = acc.value()
    }
    for j = 0; j < m; j = j + 1 {
      assert_true(
        @core.approx_eq(
          transposed[j],
          by_dense_transpose[j],
          rel=1.0e-7,
          abs=1.0e-7,
        ),
      )
    }
    // The defining property, checked without any reference: `B·x` has to give the
    // right hand side back.
    let residual = multiply_columns(columns, m, by_lu)
    for i = 0; i < m; i = i + 1 {
      assert_true(@core.approx_eq(residual[i], rhs[i], rel=1.0e-7, abs=1.0e-7))
    }
    let residual_transpose = multiply_columns_transpose(columns, m, transposed)
    for i = 0; i < m; i = i + 1 {
      assert_true(
        @core.approx_eq(residual_transpose[i], rhs[i], rel=1.0e-7, abs=1.0e-7),
      )
    }
  }
}

///|
/// A basis that is singular has to be refused: factors that are not a
/// factorization are worse than an honest failure, because the simplex would keep
/// pivoting on them.
test "a singular basis is refused" {
  let m = 4
  let columns : Array[Array[(Int, Double)]] = [
    [(0, 1.0)],
    [],
    [(1, 1.0)],
    [(2, 1.0)],
  ]
  assert_true(factorize_basis(columns, m, 1.0e-9, 1000000) is None)
}

///|
/// And the point of the whole exercise: the factors stay sparse. A banded basis
/// costs linear space instead of `m²`, which is what lets the row ceiling move.
test "the factors stay sparse on a banded basis" {
  let m = 400
  let columns : Array[Array[(Int, Double)]] = []
  for column = 0; column < m; column = column + 1 {
    let entries : Array[(Int, Double)] = []
    entries.push((column, 2.0))
    if column + 1 < m {
      entries.push((column + 1, 1.0))
    }
    if column > 0 {
      entries.push((column - 1, 1.0))
    }
    columns.push(entries)
  }
  let lu = match factorize_basis(columns, m, 1.0e-9, 1000000) {
    Some(factors) => factors
    None => fail("a banded basis was refused")
  }
  let mut entries = 0
  for k = 0; k < m; k = k + 1 {
    entries = entries + lu.l_columns[k].length() + lu.u_columns[k].length()
  }
  // Dense would be 160 000 entries; a tridiagonal basis fills a little more than
  // its own size and nowhere near a dense matrix.
  assert_true(entries < m * m / 8)
}
