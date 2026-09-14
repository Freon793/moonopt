///|
/// Numeric helpers shared by every other package in this module.
///
/// Rules for this project:
/// – never compare floats with `==` unless the values are integers by construction;
/// – every "is this zero / is this positive" decision goes through a tolerance;
/// – accumulating many terms goes through `CompensatedSum`.
///
/// The tolerance formula used everywhere is the usual mixed one:
///
///   |a - b| <= rel * max(|a|, |b|) + abs
///
/// A pure relative tolerance would treat two tiny numbers as unequal; a pure
/// absolute tolerance would treat two huge numbers as equal. The mixed form is
/// scale aware and degenerate-free.

///|
/// Relative part of the default comparison tolerance.
pub let default_rel_tolerance : Double = 1.0e-9

///|
/// Absolute part of the default comparison tolerance.
pub let default_abs_tolerance : Double = 1.0e-12

///|
/// Absolute value of a `Double` without depending on the standard library
/// float helpers, so this package stays dependency free.
pub fn fabs(x : Double) -> Double {
  if x < 0.0 {
    -x
  } else {
    x
  }
}

///|
/// Larger of two `Double` values.
pub fn fmax(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// Smaller of two `Double` values.
pub fn fmin(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// Returns `true` when `x` is NaN.
///
/// A NaN is the only value that is not equal to itself.
pub fn is_nan(x : Double) -> Bool {
  x != x
}

///|
/// Returns `true` when `x` is neither NaN nor an infinity.
///
/// `x - x` is `0.0` for every finite value and NaN for `±inf` and NaN.
pub fn is_finite(x : Double) -> Bool {
  x - x == 0.0
}

///|
/// Scale-aware equality test with an explicit tolerance.
pub fn approx_eq(
  a : Double,
  b : Double,
  rel? : Double = default_rel_tolerance,
  abs? : Double = default_abs_tolerance,
) -> Bool {
  if is_nan(a) || is_nan(b) {
    return false
  }
  if a == b {
    // Covers the case where both are the same infinity.
    return true
  }
  fabs(a - b) <= rel * fmax(fabs(a), fabs(b)) + abs
}

///|
/// Returns `true` when `x` counts as zero at the given absolute tolerance.
pub fn approx_zero(x : Double, abs? : Double = default_abs_tolerance) -> Bool {
  fabs(x) <= abs
}

///|
/// Returns `true` when `x` counts as strictly positive at the given tolerance.
pub fn approx_positive(
  x : Double,
  abs? : Double = default_abs_tolerance,
) -> Bool {
  x > abs
}

///|
/// Returns `true` when `x` counts as strictly negative at the given tolerance.
pub fn approx_negative(
  x : Double,
  abs? : Double = default_abs_tolerance,
) -> Bool {
  x < -abs
}

///|
/// Neumaier compensated summation.
///
/// Plain `+=` loses low order bits when a large accumulator receives many small
/// terms, which is exactly the pattern of a simplex pivot row. The compensated
/// form keeps a second accumulator holding the rounding error.
pub struct CompensatedSum {
  mut total : Double
  mut correction : Double
}

///|
/// Creates an empty accumulator.
pub fn CompensatedSum::new() -> CompensatedSum {
  { total: 0.0, correction: 0.0, }
}

///|
/// Adds one term, preserving the bits that a plain addition would drop.
pub fn CompensatedSum::add(self : CompensatedSum, x : Double) -> Unit {
  let t = self.total + x
  if fabs(self.total) >= fabs(x) {
    self.correction = self.correction + (self.total - t + x)
  } else {
    self.correction = self.correction + (x - t + self.total)
  }
  self.total = t
}

///|
/// Current compensated value of the accumulated terms.
pub fn CompensatedSum::value(self : CompensatedSum) -> Double {
  self.total + self.correction
}

///|
/// Sums an array with compensation.
pub fn sum_compensated(xs : Array[Double]) -> Double {
  let acc = CompensatedSum::new()
  for i = 0; i < xs.length(); i = i + 1 {
    acc.add(xs[i])
  }
  acc.value()
}

///|
/// Dot product with compensation. The second argument is guarded: a shorter
/// `ys` simply contributes nothing for the missing tail.
pub fn dot_compensated(xs : Array[Double], ys : Array[Double]) -> Double {
  let acc = CompensatedSum::new()
  let n = fmin_int(xs.length(), ys.length())
  for i = 0; i < n; i = i + 1 {
    acc.add(xs[i] * ys[i])
  }
  acc.value()
}

///|
/// Smaller of two integers (kept local to stay dependency free).
pub fn fmin_int(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// Larger of two integers.
pub fn fmax_int(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}
