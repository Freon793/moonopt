///|
/// Turning a finished run into a certificate.
///
/// The kernel works in its own normal form: rows sign-normalized, upper bounds as
/// bounds, slack / surplus / artificial columns for the relations, free variables
/// split in two. A certificate has to be stated against the model the caller handed
/// in, because that is the model a checker has — so this file is the way back, and
/// each step of it is the inverse of a transformation `problem.mbt` documents.
///
/// The row side is where a sign can go wrong: the kernel's dual for a normalized row
/// is not the model row's multiplier until the relation's own sign (a slack column
/// forces one, a surplus the other) and the row's negation are undone. Both of those
/// are folded into `row_dual_factor`, which `assemble` computes next to the
/// normalization that caused them.

///|
/// Number of model rows this kernel problem corresponds to, which is the length of a
/// certificate's `duals`.
fn State::model_row_count(self : State) -> Int {
  let mut count = 0
  for r = 0; r < self.m; r = r + 1 {
    let source = self.problem.row_source[r]
    if source + 1 > count {
      count = source + 1
    }
  }
  count
}

///|
/// The run's dual solution, one entry per model row, in the convention `verify`
/// documents.
///
/// Rows this package invented (the row form of a free variable's upper bound) have no
/// model row to report against: their multipliers are the variable's bound
/// multipliers, and the verifier accounts for a variable's bounds through its reduced
/// costs rather than through a row, so leaving them out is what makes the two agree.
fn State::model_duals(self : State) -> Array[Double] {
  let kernel = self.duals()
  let out : Array[Double] = Array::make(self.model_row_count(), 0.0)
  for r = 0; r < self.m; r = r + 1 {
    let source = self.problem.row_source[r]
    if source < 0 {
      continue
    }
    out[source] = self.problem.row_dual_factor[r] * kernel[r]
  }
  out
}

///|
/// The recession direction of an unbounded verdict, one entry per model variable.
///
/// In kernel columns the direction is a single vector: the entering column moves by
/// `σ` and the basic variable of row `i` moves by `−σ·dᵢ`, every other non-basic
/// column staying put. Model variables are linear combinations of kernel columns, so
/// the model-side direction is the same combination with the constant offsets
/// dropped — a direction has no offset.
fn State::model_ray(self : State) -> Array[Double] {
  if self.ray_column < 0 {
    return []
  }
  let kernel : Array[Double] = Array::make(self.n, 0.0)
  kernel[self.ray_column] = self.ray_sigma
  for i = 0; i < self.m; i = i + 1 {
    let column = self.basis[i]
    kernel[column] = kernel[column] - self.ray_sigma * self.direction_buffer[i]
  }
  let out : Array[Double] = []
  for m = 0; m < self.problem.var_columns.length(); m = m + 1 {
    let acc = @core.CompensatedSum::new()
    for part in self.problem.var_columns[m] {
      let (column, coefficient) = part
      acc.add(coefficient * kernel[column])
    }
    out.push(acc.value())
  }
  out
}
