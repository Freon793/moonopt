///|
test "csc construction sorts rows, merges duplicates and drops zeros" {
  let m = SparseMatrix::from_columns(3, [
    [(2, 1.0), (0, 2.0), (2, 3.0), (1, 0.0)],
    [],
    [(1, -1.0)],
  ])
  assert_eq(m.nrows(), 3)
  assert_eq(m.ncols(), 3)
  assert_eq(m.nnz(), 3)
  assert_eq(m.col_nnz(0), 2)
  assert_eq(m.col_nnz(1), 0)
  let c0 = m.column(0)
  assert_eq(c0.length(), 2)
  assert_eq(c0[0], (0, 2.0))
  assert_eq(c0[1], (2, 4.0))
  assert_eq(m.get(1, 2), -1.0)
  assert_eq(m.get(0, 1), 0.0)
  assert_eq(m.get(2, 2), 0.0)
}

///|
test "csc zeros constructor has the requested shape" {
  let z = SparseMatrix::zeros(2, 3)
  assert_eq(z.nrows(), 2)
  assert_eq(z.ncols(), 3)
  assert_eq(z.nnz(), 0)
  assert_eq(z.col_nnz(2), 0)
}

///|
test "transpose moves entries to the other axis" {
  // 2x2: row0 = [1, 0], row1 = [2, 3]
  let m = SparseMatrix::from_columns(2, [[(0, 1.0), (1, 2.0)], [(1, 3.0)]])
  let t = m.transpose()
  assert_eq(t.nrows(), 2)
  assert_eq(t.ncols(), 2)
  assert_eq(t.nnz(), 3)
  // Transposed: row0 = [1, 2], row1 = [0, 3]
  assert_eq(t.get(0, 0), 1.0)
  assert_eq(t.get(0, 1), 2.0)
  assert_eq(t.get(1, 0), 0.0)
  assert_eq(t.get(1, 1), 3.0)
}

///|
test "mul_vec only visits stored entries" {
  let m = SparseMatrix::from_columns(3, [[(0, 2.0)], [(0, 1.0), (2, -1.0)]])
  let y = m.mul_vec([3.0, 4.0])
  assert_eq(y.length(), 3)
  assert_eq(y[0], 10.0)
  assert_eq(y[1], 0.0)
  assert_eq(y[2], -4.0)
}

///|
test "to_dense agrees with get" {
  let m = SparseMatrix::from_columns(2, [[(1, 5.0)], [(0, -2.0), (1, 1.0)]])
  let d = m.to_dense()
  assert_eq(d.length(), 2)
  assert_eq(d[0].length(), 2)
  assert_eq(d[0][0], 0.0)
  assert_eq(d[0][1], -2.0)
  assert_eq(d[1][0], 5.0)
  assert_eq(d[1][1], 1.0)
}
