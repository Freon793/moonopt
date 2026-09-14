///|
/// Blackbox tests: they only see the public surface of `core`, which is what a
/// downstream package would use.
test "public numeric helpers are usable from outside" {
  assert_true(@core.approx_eq(@core.fabs(-2.0), 2.0))
  assert_eq(@core.fmin(1.0, 2.0), 1.0)
  assert_eq(@core.fmax(1.0, 2.0), 2.0)
  assert_eq(@core.fmin_int(1, 2), 1)
  assert_eq(@core.fmax_int(1, 2), 2)
  assert_eq(@core.default_rel_tolerance, 1.0e-9)
  assert_eq(@core.default_abs_tolerance, 1.0e-12)
}

///|
test "public sparse matrix round trip" {
  // A 2x1 matrix; its transpose is 1x2.
  let m = @core.SparseMatrix::from_columns(2, [[(1, 1.5)]])
  assert_eq(m.nrows(), 2)
  assert_eq(m.ncols(), 1)
  assert_eq(m.nnz(), 1)
  assert_eq(m.get(1, 0), 1.5)
  let t = m.transpose()
  assert_eq(t.nrows(), 1)
  assert_eq(t.ncols(), 2)
  assert_eq(t.get(0, 1), 1.5)
  assert_eq(t.get(0, 0), 0.0)
}
