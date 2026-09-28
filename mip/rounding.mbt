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
/// One *sampled* rounding of a relaxation's point: every integer goes up with the probability of its
/// own fractional part and down otherwise, which is the unbiased way to draw a whole point from a
/// fractional one.
///
/// The three deterministic roundings are three points of a space with one point per assignment of the
/// integers that are not whole yet — at the sixteen fractional integers `gt2`'s root relaxation has,
/// that is 65 536 points, and offering the same three of them at every node is not looking at the
/// space. A sample costs one scan of the model and no relaxation at all, so a run with no point can
/// afford one at every node it stands on: over twenty thousand nodes that is twenty thousand
/// different points.
///
/// The stream is an explicit `state` carried by the caller rather than a global: samples have to differ
/// from each other, and the arithmetic stays exact in every target (`Int64` against a power of two, so
/// no double rounding and no target-dependent result).
fn sampled_candidate(
  model : @model.Model,
  values : Array[Double],
  state : Int,
) -> (Array[Double], Int) {
  let point = values.copy()
  let mut seed : Int64 = state.to_int64()
  for j = 0; j < model.num_vars() && j < point.length(); j = j + 1 {
    let variable = model.get_var(j)
    if !variable.is_int {
      continue
    }
    seed = (seed * 1103515245L + 12345L) % 2147483648L
    let draw = (seed % 65536L).to_double() / 65536.0
    let below = floor_of(values[j])
    let target = if draw < values[j] - below { below + 1.0 } else { below }
    let mut value = target
    if has_lower_bound(variable.lb) && value < variable.lb {
      value = ceil_of(variable.lb)
    }
    if has_upper_bound(variable.ub) && value > variable.ub {
      value = floor_of(variable.ub)
    }
    point[j] = value
  }
  (point, seed.to_int())
}

///|
/// The node's model with every integer variable fixed at the value a rounding gave it.
///
/// This is the model a repair solves: the integers are decided, and the question is whether the
/// continuous variables can complete them. It is a model like any other — the checker can judge a
/// relaxation of it, which is what makes the repair a *solve* rather than a second rounding.
fn fixed_integer_model(
  problem : @model.Model,
  point : Array[Double],
) -> @model.Model {
  let fixed = problem.clone()
  for j = 0; j < fixed.num_vars() && j < point.length(); j = j + 1 {
    if fixed.get_var(j).is_int {
      fixed.set_var_bounds(j, point[j], point[j])
    }
  }
  fixed
}

///|
/// The node's model with its objective replaced by "move the integers toward this whole point".
///
/// This is the projection step of a feasibility pump, in the form that costs no rows: the L1
/// distance to a whole point is not written down, it is *pulled* — each integer variable whose
/// rounding went up gets a coefficient that pays the relaxation to raise it, each one that went down
/// gets the mirror image. The relaxation is then asked for the point nearest that rounding rather
/// than for the cheapest one, which is the question a pump asks when the rounding itself is refused
/// by the model.
///
/// Nothing about the rows changes, which is what makes it affordable here: the kernel's cost follows
/// its row count (each finite bound is a row), so a projection written with a penalty variable and a
/// row per integer would double the model the relaxation has to solve.
fn rounded_objective_model(
  problem : @model.Model,
  values : Array[Double],
  point : Array[Double],
  sign : Double,
) -> @model.Model {
  let model = problem.clone()
  let terms : Array[(Int, Double)] = []
  for j = 0; j < model.num_vars() && j < point.length(); j = j + 1 {
    if model.get_var(j).is_int {
      // `sign` is the model's sense (`-1` for a maximisation): to pull a variable up in a
      // minimisation the objective pays `-1·x`, and the mirror image in a maximisation.
      terms.push((j, if point[j] > values[j] { -sign } else { sign }))
    }
  }
  model.set_objective(terms)
  model
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
  let (point, violation) = least_violating_rounding(
    model, values, tolerance, sign,
  )
  if point.length() == 0 || violation > 0.0 {
    []
  } else {
    point
  }
}

///|
/// The rounding that comes *closest* to satisfying the model, feasible or not, with the violation it
/// leaves behind.
///
/// The search needs this second answer as well as the first: a rounding that is nearly feasible is
/// where a repair starts, and repairing it is a solve rather than a rounding. Which of the three is
/// nearest is a different question from which of them is acceptable, and the measurements differ —
/// on `flugpl` the nearest rounding leaves the rows 0.2% short, and no single variable mends that.
fn least_violating_rounding(
  model : @model.Model,
  values : Array[Double],
  tolerance : Double,
  sign : Double,
) -> (Array[Double], Double) {
  if values.length() != model.num_vars() {
    return ([], 1.0e300)
  }
  let mut best : Array[Double] = []
  let mut best_violation = 1.0e300
  let mut best_value = 0.0
  for direction in [0, 1, -1] {
    let point = rounded_candidate(model, values, direction)
    let violation = point_violation(model, point, tolerance)
    let value = point_objective(model, point)
    if best.length() == 0 ||
      violation < best_violation ||
      (violation == best_violation && sign * value < sign * best_value) {
      best = point
      best_violation = violation
      best_value = value
    }
  }
  (best, best_violation)
}
