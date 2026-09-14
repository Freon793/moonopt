///|
/// Sparse linear algebra storage used by the solver kernels.
///
/// The matrix is stored in compressed sparse column (CSC) form because every
/// pricing / basis update step of the revised simplex walks columns, not rows.
///
/// Invariants (enforced at construction, asserted by tests):
/// – `col_ptr` has length `ncols + 1`, starts at 0 and is non-decreasing;
/// – `row_idx` and `values` have the same length (the number of stored entries);
/// – row indices inside one column are strictly increasing;
/// – no structural zeros are stored.

///|
/// A sparse matrix in compressed sparse column form.
pub struct SparseMatrix {
  nrows : Int
  ncols : Int
  col_ptr : Array[Int]
  row_idx : Array[Int]
  values : Array[Double]
} derive(Debug)

///|
/// Builds a matrix from per-column `(row, value)` pairs.
///
/// Entries are sorted by row index, duplicate rows inside a column are summed,
/// and exact zeros are dropped. Passing a row index outside `[0, nrows)` is a
/// programming error and aborts.
pub fn SparseMatrix::from_columns(
  nrows : Int,
  columns : Array[Array[(Int, Double)]],
) -> SparseMatrix {
  if nrows < 0 {
    abort("SparseMatrix::from_columns: nrows must be non-negative")
  }
  let ncols = columns.length()
  let col_ptr : Array[Int] = [0]
  let row_idx : Array[Int] = []
  let values : Array[Double] = []
  for j = 0; j < ncols; j = j + 1 {
    let sorted = sort_entries(columns[j])
    let col_start = row_idx.length()
    for k = 0; k < sorted.length(); k = k + 1 {
      let (r, v) = sorted[k]
      if r < 0 || r >= nrows {
        abort("SparseMatrix::from_columns: row index out of range")
      }
      // Structural zeros are dropped: the stored pattern must stay exact.
      if v != 0.0 {
        if row_idx.length() > col_start && row_idx[row_idx.length() - 1] == r {
          // Same row twice inside *this* column: merge.
          let last = values.length() - 1
          values[last] = values[last] + v
        } else {
          row_idx.push(r)
          values.push(v)
        }
      }
    }
    col_ptr.push(row_idx.length())
  }
  { nrows, ncols, col_ptr, row_idx, values, }
}

///|
/// Builds an all-zero matrix with the given shape.
pub fn SparseMatrix::zeros(nrows : Int, ncols : Int) -> SparseMatrix {
  let col_ptr : Array[Int] = []
  for j = 0; j <= ncols; j = j + 1 {
    col_ptr.push(0)
  }
  { nrows, ncols, col_ptr, row_idx: [], values: [], }
}

///|
/// Number of rows.
pub fn SparseMatrix::nrows(self : SparseMatrix) -> Int {
  self.nrows
}

///|
/// Number of columns.
pub fn SparseMatrix::ncols(self : SparseMatrix) -> Int {
  self.ncols
}

///|
/// Number of stored (non-zero) entries.
pub fn SparseMatrix::nnz(self : SparseMatrix) -> Int {
  self.values.length()
}

///|
/// Number of stored entries in column `j`.
pub fn SparseMatrix::col_nnz(self : SparseMatrix, j : Int) -> Int {
  self.col_ptr[j + 1] - self.col_ptr[j]
}

///|
/// `(row, value)` pairs of column `j`, row index ascending.
pub fn SparseMatrix::column(
  self : SparseMatrix,
  j : Int,
) -> Array[(Int, Double)] {
  let out : Array[(Int, Double)] = []
  for k = self.col_ptr[j]; k < self.col_ptr[j + 1]; k = k + 1 {
    out.push((self.row_idx[k], self.values[k]))
  }
  out
}

///|
/// Entry at `(i, j)`; missing entries read as `0.0`.
pub fn SparseMatrix::get(self : SparseMatrix, i : Int, j : Int) -> Double {
  for k = self.col_ptr[j]; k < self.col_ptr[j + 1]; k = k + 1 {
    if self.row_idx[k] == i {
      return self.values[k]
    }
  }
  0.0
}

///|
/// Transposes the matrix. Row `i` of `self` becomes column `i` of the result, so
/// the result has `ncols` rows and `nrows` columns.
pub fn SparseMatrix::transpose(self : SparseMatrix) -> SparseMatrix {
  let cols : Array[Array[(Int, Double)]] = []
  for i = 0; i < self.nrows; i = i + 1 {
    cols.push([])
  }
  for j = 0; j < self.ncols; j = j + 1 {
    for k = self.col_ptr[j]; k < self.col_ptr[j + 1]; k = k + 1 {
      cols[self.row_idx[k]].push((j, self.values[k]))
    }
  }
  SparseMatrix::from_columns(self.ncols, cols)
}

///|
/// Row-major dense copy. Intended for tests and for the reference solver, not
/// for production paths.
pub fn SparseMatrix::to_dense(self : SparseMatrix) -> Array[Array[Double]] {
  let rows : Array[Array[Double]] = []
  for i = 0; i < self.nrows; i = i + 1 {
    let row : Array[Double] = []
    for j = 0; j < self.ncols; j = j + 1 {
      row.push(0.0)
    }
    rows.push(row)
  }
  for j = 0; j < self.ncols; j = j + 1 {
    for k = self.col_ptr[j]; k < self.col_ptr[j + 1]; k = k + 1 {
      rows[self.row_idx[k]][j] = self.values[k]
    }
  }
  rows
}

///|
/// Matrix–vector product `self * x`.
pub fn SparseMatrix::mul_vec(
  self : SparseMatrix,
  x : Array[Double],
) -> Array[Double] {
  let y : Array[Double] = []
  for i = 0; i < self.nrows; i = i + 1 {
    y.push(0.0)
  }
  for j = 0; j < self.ncols; j = j + 1 {
    let xj = x[j]
    if xj != 0.0 {
      for k = self.col_ptr[j]; k < self.col_ptr[j + 1]; k = k + 1 {
        let i = self.row_idx[k]
        y[i] = y[i] + self.values[k] * xj
      }
    }
  }
  y
}

///|
/// Insertion sort of `(row, value)` pairs by row index.
///
/// Insertion sort is intentional: columns of an LP are short, and this keeps the
/// reference path allocation free and obviously correct.
fn sort_entries(entries : Array[(Int, Double)]) -> Array[(Int, Double)] {
  let out = entries.copy()
  let n = out.length()
  for i = 1; i < n; i = i + 1 {
    let cur = out[i]
    let mut j = i - 1
    while j >= 0 && out[j].0 > cur.0 {
      out[j + 1] = out[j]
      j = j - 1
    }
    out[j + 1] = cur
  }
  out
}
