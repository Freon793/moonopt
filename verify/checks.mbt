///|
/// The measurements behind a verdict.
///
/// Everything here works from the model and the certificate's arrays, never from
/// anything the solver kept. The tolerances are scaled the same way the rest of the
/// project scales them — a violation is judged against the size of the numbers in
/// the row or the column it belongs to — but the arithmetic is written here, so a
/// reader can check it without reading the kernel.

///|
/// `true` when a variable has a real lower bound.
fn has_lower(lb : Double) -> Bool {
  lb > -1.0e29
}

///|
/// `true` when a variable has a real upper bound.
fn has_upper(ub : Double) -> Bool {
  ub < 1.0e29
}

///|
/// The sign that turns the model's own objective into the minimisation these checks
/// are written in.
fn sense_sign(model : @model.Model) -> Double {
  match model.sense() {
    @model.Sense::Minimize => 1.0
    @model.Sense::Maximize => -1.0
  }
}

///|
/// Dense minimisation-sense cost vector: `sense_sign · c`, with one entry per
/// variable so the checks can index it.
fn dense_cost(model : @model.Model) -> Array[Double] {
  let sign = sense_sign(model)
  let cost : Array[Double] = Array::make(model.num_vars(), 0.0)
  for term in model.objective() {
    let (index, coefficient) = term
    if index >= 0 && index < cost.length() {
      cost[index] = cost[index] + sign * coefficient
    }
  }
  cost
}

///|
/// `aᵢ·x` with compensated summation.
fn row_dot(model : @model.Model, row : Int, x : Array[Double]) -> Double {
  let terms = model.constraint(row).terms
  let acc = @core.CompensatedSum::new()
  for term in terms {
    let (index, coefficient) = term
    if index >= 0 && index < x.length() {
      acc.add(coefficient * x[index])
    }
  }
  acc.value()
}

///|
/// The scale of a row: the right hand side plus what the terms contribute, so a
/// residual can be judged against the numbers it came from.
fn row_scale(model : @model.Model, row : Int, x : Array[Double]) -> Double {
  let terms = model.constraint(row).terms
  let acc = @core.CompensatedSum::new()
  for term in terms {
    let (index, coefficient) = term
    if index >= 0 && index < x.length() {
      acc.add(@core.fabs(coefficient * x[index]))
    }
  }
  1.0 + @core.fabs(model.constraint(row).rhs) + acc.value()
}

///|
/// The largest scaled violation of the rows, respecting each row's relation.
fn row_violation(model : @model.Model, x : Array[Double]) -> Double {
  let mut worst = 0.0
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    let lhs = row_dot(model, i, x)
    let raw = match constraint.rel {
      @model.Rel::LessEqual => @core.fmax(0.0, lhs - constraint.rhs)
      @model.Rel::GreaterEqual => @core.fmax(0.0, constraint.rhs - lhs)
      @model.Rel::Equal => @core.fabs(lhs - constraint.rhs)
    }
    let scaled = raw / row_scale(model, i, x)
    if scaled > worst {
      worst = scaled
    }
  }
  worst
}

///|
/// The largest scaled violation of the variable bounds.
fn bound_violation(model : @model.Model, x : Array[Double]) -> Double {
  let mut worst = 0.0
  for j = 0; j < model.num_vars() && j < x.length(); j = j + 1 {
    let variable = model.get_var(j)
    let scale = 1.0 + @core.fabs(x[j])
    if has_lower(variable.lb) {
      let raw = @core.fmax(0.0, variable.lb - x[j])
      if raw / scale > worst {
        worst = raw / scale
      }
    }
    if has_upper(variable.ub) {
      let raw = @core.fmax(0.0, x[j] - variable.ub)
      if raw / scale > worst {
        worst = raw / scale
      }
    }
  }
  worst
}

///|
/// Reduced costs `rⱼ = cⱼ + Σ_{≤} yᵢaᵢⱼ − Σ_{≥} yᵢaᵢⱼ − Σ_{=} yᵢaᵢⱼ`, in the
/// minimisation sense.
fn reduced_costs(
  model : @model.Model,
  cost : Array[Double],
  duals : Array[Double],
) -> Array[Double] {
  let r : Array[Double] = Array::make(model.num_vars(), 0.0)
  for j = 0; j < model.num_vars(); j = j + 1 {
    r[j] = cost[j]
  }
  for i = 0; i < model.num_constraints() && i < duals.length(); i = i + 1 {
    let constraint = model.constraint(i)
    let sign = match constraint.rel {
      @model.Rel::LessEqual => 1.0
      @model.Rel::GreaterEqual => -1.0
      @model.Rel::Equal => -1.0
    }
    if duals[i] != 0.0 {
      for term in constraint.terms {
        let (index, coefficient) = term
        if index >= 0 && index < r.length() {
          r[index] = r[index] + sign * duals[i] * coefficient
        }
      }
    }
  }
  r
}

///|
/// The constant part of the Lagrangian, `D = −Σ_{≤} yᵢbᵢ + Σ_{≥} yᵢbᵢ + Σ_{=} yᵢbᵢ`.
fn lagrangian_constant(model : @model.Model, duals : Array[Double]) -> Double {
  let acc = @core.CompensatedSum::new()
  for i = 0; i < model.num_constraints() && i < duals.length(); i = i + 1 {
    let constraint = model.constraint(i)
    let sign = match constraint.rel {
      @model.Rel::LessEqual => -1.0
      @model.Rel::GreaterEqual => 1.0
      @model.Rel::Equal => 1.0
    }
    acc.add(sign * duals[i] * constraint.rhs)
  }
  acc.value()
}

///|
/// `min_{l ≤ x ≤ u} r·x`, or the "no finite bound" sentinel when a reduced cost
/// points in a direction the variable can travel forever.
///
/// A reduced cost is judged against the same tolerance the dual feasibility check
/// uses, and for the same reason: a multiplier that is round-off small points nowhere,
/// and calling it a direction to infinity would refuse a certificate whose every other
/// measurement agrees. Getting these two out of step is how the first run of this
/// verifier rejected an optimal solve of a real instance.
fn box_minimum(
  model : @model.Model,
  cost : Array[Double],
  duals : Array[Double],
  r : Array[Double],
  tolerance : Double,
) -> Double {
  let acc = @core.CompensatedSum::new()
  for j = 0; j < model.num_vars() && j < r.length(); j = j + 1 {
    let scale = reduced_cost_scale(model, j, cost, duals)
    if r[j] > tolerance * scale {
      let variable = model.get_var(j)
      if !has_lower(variable.lb) {
        return -1.0e300
      }
      acc.add(variable.lb * r[j])
    } else if r[j] < -tolerance * scale {
      let variable = model.get_var(j)
      if !has_upper(variable.ub) {
        return -1.0e300
      }
      acc.add(variable.ub * r[j])
    }
  }
  acc.value()
}

///|
/// `true` when the number is the "no finite bound" sentinel.
fn is_no_bound(value : Double) -> Bool {
  value <= -1.0e299
}

///|
/// The lower bound the multipliers give on the minimisation objective — the number
/// the whole optimality check turns on. See the package doc for the derivation.
fn lower_bound(
  model : @model.Model,
  cost : Array[Double],
  duals : Array[Double],
  tolerance : Double,
) -> Double {
  let r = reduced_costs(model, cost, duals)
  let box = box_minimum(model, cost, duals, r, tolerance)
  if is_no_bound(box) {
    box
  } else {
    box + lagrangian_constant(model, duals)
  }
}
