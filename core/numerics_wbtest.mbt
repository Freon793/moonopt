///|
test "approx_eq is scale aware" {
  assert_true(approx_eq(1.0, 1.0))
  assert_true(approx_eq(1.0, 1.0 + 1.0e-12))
  assert_eq(approx_eq(1.0, 1.0 + 1.0e-6), false)
  // The mixed tolerance is absolute at the low end: 1e-30 is zero at 1e-12.
  assert_true(approx_eq(1.0e-30, 0.0))
  assert_eq(approx_eq(1.0e-6, 0.0), false)
  assert_true(approx_eq(1.0e18, 1.0e18 + 1.0e3))
}

///|
test "zero and sign predicates use a tolerance" {
  assert_true(approx_zero(0.0))
  assert_true(approx_zero(1.0e-15))
  assert_eq(approx_zero(1.0e-6), false)
  assert_true(approx_positive(1.0e-6))
  assert_eq(approx_positive(-1.0e-6), false)
  assert_true(approx_negative(-1.0e-6))
  assert_eq(approx_negative(1.0e-6), false)
}

///|
test "nan and infinity detection" {
  let inf = 1.0e308 * 10.0
  assert_eq(is_nan(inf), false)
  assert_eq(is_finite(inf), false)
  assert_eq(is_finite(1.0), true)
  assert_eq(is_nan(inf - inf), true)
  assert_eq(is_finite(inf - inf), false)
  assert_eq(approx_eq(inf, inf), true)
  assert_eq(approx_eq(inf, inf - inf), false)
}

///|
test "compensated summation keeps terms a plain loop loses" {
  let xs : Array[Double] = [1.0e16, 1.0, 1.0, -1.0e16]
  let mut plain = 0.0
  for i = 0; i < xs.length(); i = i + 1 {
    plain = plain + xs[i]
  }
  assert_eq(plain, 0.0)
  assert_eq(sum_compensated(xs), 2.0)
}

///|
test "compensated dot product" {
  let xs : Array[Double] = [3.0, 4.0, 0.0]
  let ys : Array[Double] = [2.0, -1.0, 100.0]
  assert_eq(dot_compensated(xs, ys), 2.0)
  // A short second array contributes nothing rather than failing.
  assert_eq(dot_compensated(xs, [2.0]), 6.0)
}
