///|
/// A whole point read out of a relaxation by rounding it — a primal heuristic that spends no
/// relaxation at all.
///
/// The search's other primal mechanism is the dive (`dive_for_incumbent`), which re-solves for every
/// variable it fixes, so what it can buy is bounded by the node budget it spends. Rounding is the
/// opposite trade: the node's relaxation is already solved, the integer variables are already
/// fractional, and moving them to a whole number costs one pass over the model to see whether the
/// point that comes out satisfies it. Nothing here solves anything.
///
/// What it is for is the state the reports show on `flugpl` and `dcmulti`: a run with no integer
/// point at all, where the bound prunes nothing because there is nothing to prune against.
/// `flugpl` finds its first point between 9000 and 12000 of the 13806 relaxations its proof costs,
/// and the whole of that stretch is spent without pruning.
///
/// Three roundings are checked rather than one assumed: to the nearer whole number, up, and down,
/// each clamped into the whole range the variable's own bounds leave. A covering model (`Σ a x ≥ b`
/// with `a ≥ 0`) is repaired by rounding up, a packing model by rounding down, and a general model is
/// either or neither — and the check is cheap enough that guessing is not needed. The best feasible
/// one is offered.
///
/// An incumbent is a feasibility claim, so it is judged by the same measurement the independent
/// checker makes: rows against `1 + |bᵢ| + Σⱼ|aᵢⱼxⱼ|`, bounds and whole numbers against `1 + |xⱼ|`.
/// A producer that judges feasibility by a rule of its own is how this project has, three times,
/// ended up with two measurements of the same thing.

///|
/// `aᵢ·x`, compensated, over the row's stored terms.
fn point_row_dot(
  model : @model.Model,
  row : Int,
  point : Array[Double],
) -> Double {
  let acc = @core.CompensatedSum::new()
  for term in model.constraint(row).terms {
    let (index, coefficient) = term
    if index >= 0 && index < point.length() {
      acc.add(coefficient * point[index])
    }
  }
  acc.value()
}

///|
/// The largest scaled violation of the rows, the bounds, and the whole-number requirement — the
/// number `verify/checks.mbt` computes for the first two, in the same units, and zero when the point
/// satisfies the model.
fn point_violation(
  model : @model.Model,
  point : Array[Double],
  tolerance : Double,
) -> Double {
  let mut worst = 0.0
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    let lhs = point_row_dot(model, i, point)
    let raw = match constraint.rel {
      @model.Rel::LessEqual => @core.fmax(0.0, lhs - constraint.rhs)
      @model.Rel::GreaterEqual => @core.fmax(0.0, constraint.rhs - lhs)
      @model.Rel::Equal => @core.fabs(lhs - constraint.rhs)
    }
    let scale_acc = @core.CompensatedSum::new()
    for term in constraint.terms {
      let (index, coefficient) = term
      if index >= 0 && index < point.length() {
        scale_acc.add(@core.fabs(coefficient * point[index]))
      }
    }
    let scaled = raw / (1.0 + @core.fabs(constraint.rhs) + scale_acc.value())
    if scaled > worst {
      worst = scaled
    }
  }
  for j = 0; j < model.num_vars() && j < point.length(); j = j + 1 {
    let variable = model.get_var(j)
    let scale = 1.0 + @core.fabs(point[j])
    if has_lower_bound(variable.lb) {
      let scaled = @core.fmax(0.0, variable.lb - point[j]) / scale
      if scaled > worst {
        worst = scaled
      }
    }
    if has_upper_bound(variable.ub) {
      let scaled = @core.fmax(0.0, point[j] - variable.ub) / scale
      if scaled > worst {
        worst = scaled
      }
    }
    // The whole-number requirement, judged the way the search judges it when it decides a node is
    // still fractional (`fractional_count`) rather than by a rule of its own.
    if variable.is_int {
      let distance = @core.fabs(point[j] - round_of(point[j]))
      if distance > worst {
        worst = distance
      }
    }
  }
  if worst < tolerance {
    0.0
  } else {
    worst
  }
}

///|
/// The objective a point has, in the model's own sense.
fn point_objective(model : @model.Model, point : Array[Double]) -> Double {
  let acc = @core.CompensatedSum::new()
  for term in model.objective() {
    let (index, coefficient) = term
    if index >= 0 && index < point.length() {
      acc.add(coefficient * point[index])
    }
  }
  acc.value()
}

///|
/// One rounding of a relaxation's point, clamped into the whole range each integer variable's own
/// bounds leave. `direction` is `-1` for `⌊x⌋`, `1` for `⌈x⌉` and `0` for the nearer whole number.
fn rounded_candidate(
  model : @model.Model,
  values : Array[Double],
  direction : Int,
) -> Array[Double] {
  let point = values.copy()
  for j = 0; j < model.num_vars() && j < point.length(); j = j + 1 {
    let variable = model.get_var(j)
    if !variable.is_int {
      continue
    }
    let target = if direction > 0 {
      ceil_of(values[j])
    } else if direction < 0 {
      floor_of(values[j])
    } else {
      round_of(values[j])
    }
    let mut value = target
    if has_lower_bound(variable.lb) && value < variable.lb {
      value = ceil_of(variable.lb)
    }
    if has_upper_bound(variable.ub) && value > variable.ub {
      value = floor_of(variable.ub)
    }
    point[j] = value
  }
  point
}

///|
/// The best whole point one of the three roundings reaches, or `[]` when none of them satisfies the
/// model. `sign` is the model's sense (`-1` for a maximisation), so "better" is one comparison for
/// both senses — the same convention the search's incumbent update uses.
fn rounded_point(
  model : @model.Model,
  values : Array[Double],
  tolerance : Double,
  sign : Double,
) -> Array[Double] {
  if values.length() != model.num_vars() {
    return []
  }
  let mut best : Array[Double] = []
  let mut best_value = 0.0
  for direction in [0, 1, -1] {
    let point = rounded_candidate(model, values, direction)
    if point_violation(model, point, tolerance) > 0.0 {
      continue
    }
    let value = point_objective(model, point)
    if best.length() == 0 || sign * value < sign * best_value {
      best = point
      best_value = value
    }
  }
  best
}
