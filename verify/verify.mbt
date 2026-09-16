///|
/// Independent checks on a claimed answer.
///
/// This package answers one question: **is the stated claim true for this model?**
/// It is deliberately not part of the solve path. It depends on `@model` and
/// `@core` and on nothing else — in particular it does not import `@simplex`, so a
/// certificate can only be accepted because the arithmetic in this package says so,
/// never because the solver that produced it also believes it. That is the whole
/// point of a certificate: a wrong answer carrying a confident status is the one
/// outcome the project exists to prevent, and the way to prevent it is to check the
/// answer with code that shares no state with the code that guessed it.
///
/// # The multiplier convention
///
/// Everything here is written in one convention, and a producer of certificates
/// has to use it too (the kernel does; see `docs/roadmap.md` for the mapping).
/// For a row `aᵢ·x rel bᵢ`, define the oriented form
///
/// ```text
///   gᵢ(x) = aᵢ·x − bᵢ     for `≤` rows
///   gᵢ(x) = bᵢ − aᵢ·x     for `≥` rows
///   gᵢ(x) = bᵢ − aᵢ·x     for `=` rows
/// ```
///
/// and let `yᵢ ≥ 0` be the multiplier of `gᵢ` for `≤` / `≥` rows and a free
/// multiplier for `=` rows. The certificate stores exactly these numbers as
/// `duals`. For a minimisation problem the Lagrangian is
///
/// ```text
///   L(x, y) = Σᵢ yᵢ·gᵢ(x) + c·x  =  r·x + D
///   rⱼ = cⱼ + Σ_{≤} yᵢaᵢⱼ − Σ_{≥} yᵢaᵢⱼ − Σ_{=} yᵢaᵢⱼ
///   D  = −Σ_{≤} yᵢbᵢ + Σ_{≥} yᵢbᵢ + Σ_{=} yᵢbᵢ
/// ```
///
/// For a feasible `x` every term `yᵢ·gᵢ(x)` is non-negative, so `c·x ≥ L(x, y)`
/// and therefore
///
/// ```text
///   c·x ≥ min_{l ≤ x ≤ u} L(x, y)
///       = Σⱼ (rⱼ ≥ 0 ? lⱼ·rⱼ : uⱼ·rⱼ) + D   =: lower bound
/// ```
///
/// That bound is the whole verifier: a claimed optimum is accepted when the primal
/// point is feasible, the multipliers have the right signs, the reduced costs are
/// compatible with the bounds (dual feasibility), the complementary pairs vanish,
/// and the bound equals the claimed objective. A minimisation certificate for a
/// maximisation model is obtained by negating the cost vector, which is what the
/// `sense` handling below does — the certificate's `objective` is always in the
/// model's own sense.
///
/// # Infeasibility and unboundedness
///
/// The same bound with `c = 0` is Farkas's lemma: if multipliers with the right
/// signs give a strictly positive lower bound over the whole box, no point in that
/// box satisfies the rows, so the model is infeasible. Unboundedness is checked as a
/// recession direction instead: a feasible point plus a direction that stays
/// feasible forever and keeps improving the objective.

///|
/// Tolerance a violation is judged against unless the caller says otherwise. The
/// same order the rest of the project uses for feasibility, and the same order the
/// callers' claims are stated in.
let default_tolerance : Double = 1.0e-7

///|
/// Collects one measurement.
fn check(
  name : String,
  ok : Bool,
  measured : Double,
  tolerance : Double,
) -> Check {
  { name, ok, measured, tolerance, }
}

///|
/// `true` when every measurement passed.
fn all_ok(checks : Array[Check]) -> Bool {
  for item in checks {
    if !item.ok {
      return false
    }
  }
  true
}

///|
/// The first failure, in words, for a `Verdict`'s reason field.
fn first_failure(checks : Array[Check]) -> String {
  for item in checks {
    if !item.ok {
      return item.name +
        " failed: " +
        item.measured.to_string() +
        " against tolerance " +
        item.tolerance.to_string()
    }
  }
  ""
}

///|
/// Feasibility of a primal point: the rows with their own relations, and the
/// variable bounds. Used by both the optimality and the unboundedness claims,
/// because both start from a point that has to be feasible.
fn primal_checks(
  model : @model.Model,
  x : Array[Double],
  tolerance : Double,
) -> Array[Check] {
  let rows = row_violation(model, x)
  let bounds = bound_violation(model, x)
  [
    check("row feasibility", rows <= tolerance, rows, tolerance),
    check("variable bounds", bounds <= tolerance, bounds, tolerance),
  ]
}

///|
/// The sign conditions on the row multipliers: non-negative on the oriented form of
/// a `≤` or `≥` row, free on an equality.
fn multiplier_sign_violation(
  model : @model.Model,
  duals : Array[Double],
) -> Double {
  let mut worst = 0.0
  for i = 0; i < model.num_constraints() && i < duals.length(); i = i + 1 {
    if model.constraint(i).rel == @model.Rel::Equal {
      continue
    }
    let raw = @core.fmax(0.0, -duals[i])
    let scaled = raw / (1.0 + @core.fabs(duals[i]))
    if scaled > worst {
      worst = scaled
    }
  }
  worst
}

///|
/// The scale of one reduced cost: what the objective coefficient and the rows say
/// about how big it could legitimately be.
fn reduced_cost_scale(
  model : @model.Model,
  j : Int,
  cost : Array[Double],
  duals : Array[Double],
) -> Double {
  let acc = @core.CompensatedSum::new()
  for i = 0; i < model.num_constraints() && i < duals.length(); i = i + 1 {
    for term in model.constraint(i).terms {
      let (index, coefficient) = term
      if index == j {
        acc.add(@core.fabs(coefficient * duals[i]))
      }
    }
  }
  1.0 + @core.fabs(cost[j]) + acc.value()
}

///|
/// Dual feasibility: a reduced cost pointing at a direction the variable can travel
/// forever gives no finite bound, so it is not a certificate.
fn dual_feasibility_violation(
  model : @model.Model,
  cost : Array[Double],
  duals : Array[Double],
  tolerance : Double,
) -> Double {
  let r = reduced_costs(model, cost, duals)
  let mut worst = 0.0
  for j = 0; j < model.num_vars(); j = j + 1 {
    let variable = model.get_var(j)
    let scale = reduced_cost_scale(model, j, cost, duals)
    if r[j] > tolerance && !has_lower(variable.lb) {
      let scaled = (r[j] - tolerance) / scale
      if scaled > worst {
        worst = scaled
      }
    }
    if r[j] < -tolerance && !has_upper(variable.ub) {
      let scaled = (-r[j] - tolerance) / scale
      if scaled > worst {
        worst = scaled
      }
    }
  }
  worst
}

///|
/// Complementary slackness on the rows: a row with a non-zero multiplier has to be
/// tight, and a tight row may carry any multiplier.
fn row_complementarity_violation(
  model : @model.Model,
  x : Array[Double],
  duals : Array[Double],
  tolerance : Double,
) -> Double {
  let mut worst = 0.0
  for i = 0; i < model.num_constraints() && i < duals.length(); i = i + 1 {
    let constraint = model.constraint(i)
    if constraint.rel == @model.Rel::Equal || @core.fabs(duals[i]) <= tolerance {
      continue
    }
    let lhs = row_dot(model, i, x)
    let slack = match constraint.rel {
      @model.Rel::LessEqual => @core.fmax(0.0, constraint.rhs - lhs)
      @model.Rel::GreaterEqual => @core.fmax(0.0, lhs - constraint.rhs)
      @model.Rel::Equal => 0.0
    }
    let scaled = slack / row_scale(model, i, x)
    if scaled > worst {
      worst = scaled
    }
  }
  worst
}

///|
/// Complementary slackness on the variables: a column with a non-zero reduced cost
/// has to sit on the bound that reduced cost points at.
fn variable_complementarity_violation(
  model : @model.Model,
  x : Array[Double],
  cost : Array[Double],
  duals : Array[Double],
  tolerance : Double,
) -> Double {
  let r = reduced_costs(model, cost, duals)
  let mut worst = 0.0
  for j = 0; j < model.num_vars(); j = j + 1 {
    if @core.fabs(r[j]) <= tolerance {
      continue
    }
    let variable = model.get_var(j)
    let scale = 1.0 + @core.fabs(x[j])
    if r[j] > 0.0 {
      if !has_lower(variable.lb) {
        continue
      }
      let raw = @core.fmax(0.0, x[j] - variable.lb)
      if raw / scale > worst {
        worst = raw / scale
      }
    } else {
      if !has_upper(variable.ub) {
        continue
      }
      let raw = @core.fmax(0.0, variable.ub - x[j])
      if raw / scale > worst {
        worst = raw / scale
      }
    }
  }
  worst
}

///|
/// Builds the `Verdict` from the measurements: accepted when every one passed.
fn conclude(claim : Claim, checks : Array[Check]) -> Verdict {
  let accepted = all_ok(checks)
  {
    accepted,
    claim,
    checks,
    reason: if accepted {
      ""
    } else {
      first_failure(checks)
    },
  }
}

///|
/// Dimensions are checked before anything else: a certificate whose arrays are not
/// the shape of the model is not a certificate of anything, and every array access
/// after this point would be guessing.
fn shape_checks(
  model : @model.Model,
  certificate : Certificate,
  checks : Array[Check],
) -> Bool {
  let n = model.num_vars()
  let m = model.num_constraints()
  let mut ok = true
  match certificate.claim {
    Claim::Optimal => {
      checks.push(
        check(
          "values dimension",
          certificate.values.length() == n,
          certificate.values.length().to_double(),
          0.0,
        ),
      )
      checks.push(
        check(
          "duals dimension",
          certificate.duals.length() == m,
          certificate.duals.length().to_double(),
          0.0,
        ),
      )
      ok = certificate.values.length() == n && certificate.duals.length() == m
    }
    Claim::Infeasible => {
      checks.push(
        check(
          "duals dimension",
          certificate.duals.length() == m,
          certificate.duals.length().to_double(),
          0.0,
        ),
      )
      ok = certificate.duals.length() == m
    }
    Claim::Unbounded => {
      checks.push(
        check(
          "values dimension",
          certificate.values.length() == n,
          certificate.values.length().to_double(),
          0.0,
        ),
      )
      checks.push(
        check(
          "ray dimension",
          certificate.ray.length() == n,
          certificate.ray.length().to_double(),
          0.0,
        ),
      )
      ok = certificate.values.length() == n && certificate.ray.length() == n
    }
  }
  ok
}

///|
/// Optimality: a feasible point, multipliers with the right signs, reduced costs
/// compatible with the bounds, complementary pairs that vanish, and a bound that
/// meets the point.
fn verify_optimal(
  model : @model.Model,
  certificate : Certificate,
  tolerance : Double,
) -> Verdict {
  let checks : Array[Check] = []
  if !shape_checks(model, certificate, checks) {
    return conclude(Claim::Optimal, checks)
  }
  let x = certificate.values
  let y = certificate.duals
  let cost = dense_cost(model)
  for item in primal_checks(model, x, tolerance) {
    checks.push(item)
  }
  let signs = multiplier_sign_violation(model, y)
  checks.push(check("dual signs", signs <= tolerance, signs, tolerance))
  let duals_ok = dual_feasibility_violation(model, cost, y, tolerance)
  checks.push(
    check("dual feasibility", duals_ok <= tolerance, duals_ok, tolerance),
  )
  let rows_complementary = row_complementarity_violation(model, x, y, tolerance)
  checks.push(
    check(
      "complementarity (rows)",
      rows_complementary <= tolerance,
      rows_complementary,
      tolerance,
    ),
  )
  let columns_complementary = variable_complementarity_violation(
    model, x, cost, y, tolerance,
  )
  checks.push(
    check(
      "complementarity (columns)",
      columns_complementary <= tolerance,
      columns_complementary,
      tolerance,
    ),
  )
  // The sharpest single statement: the objective at the point equals the best bound
  // the multipliers can prove. Everything above is what makes that bound valid.
  let acc = @core.CompensatedSum::new()
  for j = 0; j < model.num_vars(); j = j + 1 {
    acc.add(cost[j] * x[j])
  }
  let primal = acc.value()
  let bound = lower_bound(model, cost, y, tolerance)
  if is_no_bound(bound) {
    checks.push(check("duality gap", false, 1.0e300, tolerance))
  } else {
    let gap = @core.fabs(primal - bound) /
      (1.0 + @core.fabs(primal) + @core.fabs(bound))
    checks.push(check("duality gap", gap <= tolerance, gap, tolerance))
  }
  let sign = sense_sign(model)
  let claimed = certificate.objective
  let recomputed = sign * primal
  let objective_gap = @core.fabs(claimed - recomputed) /
    (1.0 + @core.fabs(claimed))
  checks.push(
    check(
      "claimed objective",
      objective_gap <= tolerance,
      objective_gap,
      tolerance,
    ),
  )
  conclude(Claim::Optimal, checks)
}

///|
/// Infeasibility, by Farkas's lemma on the same bound with a zero cost vector: the
/// multipliers have to make the Lagrangian strictly positive over the whole box,
/// which no point satisfying every row could do.
fn verify_infeasible(
  model : @model.Model,
  certificate : Certificate,
  tolerance : Double,
) -> Verdict {
  let checks : Array[Check] = []
  if !shape_checks(model, certificate, checks) {
    return conclude(Claim::Infeasible, checks)
  }
  let y = certificate.duals
  let signs = multiplier_sign_violation(model, y)
  checks.push(check("ray signs", signs <= tolerance, signs, tolerance))
  let zero_cost : Array[Double] = Array::make(model.num_vars(), 0.0)
  let r = reduced_costs(model, zero_cost, y)
  // A reduced cost the box cannot absorb makes the "minimum over the box" infinite
  // in the wrong direction, which is not a proof of anything.
  let mut unabsorbed = 0.0
  for j = 0; j < model.num_vars(); j = j + 1 {
    let variable = model.get_var(j)
    let scale = reduced_cost_scale(model, j, zero_cost, y)
    if r[j] > tolerance && !has_lower(variable.lb) {
      let scaled = r[j] / scale
      if scaled > unabsorbed {
        unabsorbed = scaled
      }
    }
    if r[j] < -tolerance && !has_upper(variable.ub) {
      let scaled = -r[j] / scale
      if scaled > unabsorbed {
        unabsorbed = scaled
      }
    }
  }
  checks.push(
    check(
      "ray is absorbed by the box",
      unabsorbed <= tolerance,
      unabsorbed,
      tolerance,
    ),
  )
  let constant = lagrangian_constant(model, y)
  let box = box_minimum(model, zero_cost, y, r, tolerance)
  let margin = if is_no_bound(box) { box } else { box + constant }
  let scale = 1.0 + @core.fabs(constant)
  if is_no_bound(margin) {
    checks.push(check("farkas margin", false, 1.0e300, tolerance))
  } else {
    // Strictly positive, not merely non-negative: a zero margin is the trivial
    // combination that proves nothing.
    let scaled = margin / scale
    checks.push(check("farkas margin", scaled > tolerance, scaled, tolerance))
  }
  conclude(Claim::Infeasible, checks)
}

///|
/// Unboundedness: a feasible point plus a direction that stays feasible whatever
/// multiple of it is added, and improves the objective strictly.
fn verify_unbounded(
  model : @model.Model,
  certificate : Certificate,
  tolerance : Double,
) -> Verdict {
  let checks : Array[Check] = []
  if !shape_checks(model, certificate, checks) {
    return conclude(Claim::Unbounded, checks)
  }
  let x = certificate.values
  let d = certificate.ray
  for item in primal_checks(model, x, tolerance) {
    checks.push(item)
  }
  // The rows may not block the direction.
  let mut row_block = 0.0
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    let slope = row_dot(model, i, d)
    let scale = 1.0 + @core.fabs(slope)
    let raw = match constraint.rel {
      @model.Rel::LessEqual => @core.fmax(0.0, slope)
      @model.Rel::GreaterEqual => @core.fmax(0.0, -slope)
      @model.Rel::Equal => @core.fabs(slope)
    }
    if raw / scale > row_block {
      row_block = raw / scale
    }
  }
  checks.push(
    check(
      "rows do not block the ray",
      row_block <= tolerance,
      row_block,
      tolerance,
    ),
  )
  // Neither may the bounds: a variable can only travel in the direction it has room
  // in, and a variable with two bounds cannot travel at all.
  let mut bound_block = 0.0
  for j = 0; j < model.num_vars(); j = j + 1 {
    let variable = model.get_var(j)
    let scale = 1.0 + @core.fabs(d[j])
    let raw = if has_lower(variable.lb) && has_upper(variable.ub) {
      @core.fabs(d[j])
    } else if has_lower(variable.lb) && !has_upper(variable.ub) {
      @core.fmax(0.0, -d[j])
    } else if !has_lower(variable.lb) && has_upper(variable.ub) {
      @core.fmax(0.0, d[j])
    } else {
      0.0
    }
    if raw / scale > bound_block {
      bound_block = raw / scale
    }
  }
  checks.push(
    check(
      "bounds do not block the ray",
      bound_block <= tolerance,
      bound_block,
      tolerance,
    ),
  )
  let mut magnitude = 0.0
  for j = 0; j < model.num_vars(); j = j + 1 {
    if @core.fabs(d[j]) > magnitude {
      magnitude = @core.fabs(d[j])
    }
  }
  // The direction has to be a direction: a zero vector satisfies every condition
  // above and proves nothing.
  checks.push(
    check(
      "ray magnitude (must exceed the tolerance)",
      magnitude > tolerance,
      magnitude,
      tolerance,
    ),
  )
  let cost = dense_cost(model)
  let acc = @core.CompensatedSum::new()
  let abs_acc = @core.CompensatedSum::new()
  for j = 0; j < model.num_vars(); j = j + 1 {
    acc.add(cost[j] * d[j])
    abs_acc.add(@core.fabs(cost[j] * d[j]))
  }
  let rate = acc.value()
  let scaled_rate = rate / (1.0 + abs_acc.value())
  checks.push(
    check(
      "objective improves along the ray",
      scaled_rate < -tolerance,
      scaled_rate,
      tolerance,
    ),
  )
  conclude(Claim::Unbounded, checks)
}

///|
/// Checks whatever `certificate` claims about `model`.
///
/// Returns a verdict carrying every measurement, so a refusal says how far off the
/// claim was. Nothing in this package imports the solver: an accepted certificate is
/// accepted because the arithmetic here says so.
pub fn verify(
  model : @model.Model,
  certificate : Certificate,
  tolerance? : Double = default_tolerance,
) -> Verdict {
  match certificate.claim {
    Claim::Optimal => verify_optimal(model, certificate, tolerance)
    Claim::Infeasible => verify_infeasible(model, certificate, tolerance)
    Claim::Unbounded => verify_unbounded(model, certificate, tolerance)
  }
}
