///|
/// Postsolve: turn a solution of the reduced model back into a solution of the
/// original one.
///
/// The map is exact by construction: an eliminated variable was fixed at a value
/// that satisfies every row it appeared in (that is why the substitution was
/// allowed), and a surviving variable is the kernel's own value. Reconstruction
/// therefore never has to guess, and the tests check the result against the
/// original rows rather than trusting that argument.

///|
/// Rebuilds every original variable from a solution of the reduced model.
///
/// `values` is indexed by the reduced model's variables and may be empty when the
/// reduction eliminated all of them. The result is indexed by the original
/// variables.
pub fn ReducedModel::reconstruct(
  self : ReducedModel,
  values : Array[Double],
) -> Array[Double] {
  let out : Array[Double] = []
  for form in self.forms {
    match form {
      Fixed(value) => out.push(value)
      Linear(constant, terms) => {
        let mut value = constant
        for term in terms {
          let (k, coefficient) = term
          value = value + coefficient * values[k]
        }
        out.push(value)
      }
    }
  }
  out
}

///|
/// Largest violation of the model's own rows by `values`, scaled per row the same
/// way the kernel's self-check scales its residuals: a violation is only a
/// violation relative to the size of the numbers in that row.
///
/// This is the check the tests use on reconstructed solutions, and it is
/// deliberately independent of the reduction's bookkeeping.
pub fn max_row_violation(
  model : @model.Model,
  values : Array[Double],
) -> Double {
  let mut worst = 0.0
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    let mut activity = 0.0
    let mut scale = 1.0 + @core.fabs(constraint.rhs)
    for term in constraint.terms {
      let (j, coefficient) = term
      if j >= 0 && j < values.length() {
        activity = activity + coefficient * values[j]
        scale = scale + @core.fabs(coefficient * values[j])
      }
    }
    let violation = match constraint.rel {
      @model.Rel::LessEqual => activity - constraint.rhs
      @model.Rel::GreaterEqual => constraint.rhs - activity
      @model.Rel::Equal => @core.fabs(activity - constraint.rhs)
    }
    let scaled = if violation > 0.0 { violation / scale } else { 0.0 }
    if scaled > worst {
      worst = scaled
    }
  }
  worst
}

///|
/// Largest violation of the variables' own bounds by `values`, scaled the same
/// way. A reconstructed solution has to satisfy the bounds too, not just the rows.
pub fn max_bound_violation(
  model : @model.Model,
  values : Array[Double],
) -> Double {
  let mut worst = 0.0
  let n = model.num_vars()
  for j = 0; j < n && j < values.length(); j = j + 1 {
    let variable = model.get_var(j)
    let value = values[j]
    let scale = 1.0 + @core.fabs(value)
    let below = variable.lb - value
    let above = value - variable.ub
    let violation = @core.fmax(below, above)
    if violation > 0.0 {
      let scaled = violation / scale
      if scaled > worst {
        worst = scaled
      }
    }
  }
  worst
}
