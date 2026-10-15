///|
/// Runnable example: what a plan someone already has is worth, measured against a bound.
///
/// This is the workflow the package exists for in production settings — an outer heuristic
/// (or a human) produces a plan, and the question is not "is there a better plan" but "how far
/// from optimal could this one be". A bound answers that, and it is a *relaxation* that
/// produces it:
///
///   min 6a + 5b
///   s.t. 4a + 2b >= 5      (demand: pattern A covers 4 units, pattern B covers 2)
///        a, b >= 0 integers
///
/// Pattern A costs 6 per shift and covers 4 units, pattern B costs 5 and covers 2. The
/// relaxation (the same model without integrality) reaches 1.25 shifts of A, which no roster
/// can: 6 * 1.25 = 7.5 is a valid *bound* on any whole plan, and the best whole plan costs 11
/// at (1, 1). A plan of (2, 0) costs 12, so it is at most 4.5 — 60% of the bound — above the
/// best possible, while the bound itself sits 31.8% below the true optimum. Both numbers are
/// printed, because a bound that is reported without its own looseness is a number a reader
/// will over-trust.
///
/// Run with: `moon run examples/schedule_bound`
fn main {
  let model = @model.Model::new(@model.Sense::Minimize)
  let a = model.add_var("a", lb=0.0, is_int=true)
  let b = model.add_var("b", lb=0.0, is_int=true)
  model.set_objective([(a, 6.0), (b, 5.0)])
  model.add_named_constraint(
    [(a, 4.0), (b, 2.0)],
    @model.Rel::GreaterEqual,
    5.0,
    "demand",
  )
  // The plan the outer heuristic handed over.
  let plan : Array[Double] = [2.0, 0.0]
  let bound = @moonopt.solve(@moonopt.relaxation(model))
  let answer = @moonopt.solve(model)
  println("shift cover: min 6a + 5b  s.t.  4a + 2b >= 5,  a and b whole")
  println(
    "  LP bound (relaxation)  : " +
    status_text(bound.status) +
    " " +
    bound.objective.to_string(),
  )
  if answer.status == @moonopt.SolveStatus::Optimal {
    println(
      "  proven optimum         : " +
      answer.objective.to_string() +
      " at (" +
      answer.values[0].to_string() +
      ", " +
      answer.values[1].to_string() +
      ")",
    )
  } else {
    println("  proven optimum         : " + status_text(answer.status))
  }
  let cost = @presolve.objective_value(model, plan)
  let rows = @presolve.max_row_violation(model, plan)
  let bounds = @presolve.max_bound_violation(model, plan)
  println(
    "  the plan you have       : " +
    cost.to_string() +
    " at (" +
    plan[0].to_string() +
    ", " +
    plan[1].to_string() +
    ")",
  )
  println(
    "    feasible              : " +
    (if rows <= 1.0e-9 && bounds <= 1.0e-9 { "yes" } else { "no" }),
  )
  // The gap is the whole point: the plan cannot be better than the bound, so the distance
  // between them is a guarantee about the plan — and it needs no proof of optimality.
  let gap = cost - bound.objective
  println(
    "    gap of that plan      : " +
    gap.to_string() +
    " (" +
    percent(gap, bound.objective) +
    " of the bound)",
  )
  if answer.status == @moonopt.SolveStatus::Optimal {
    let slack = answer.objective - bound.objective
    println(
      "    bound's own looseness : " +
      slack.to_string() +
      " (" +
      percent(slack, answer.objective) +
      " below the optimum)",
    )
  }
}

///|
/// `part / whole` as a percentage, for the two ratios this example prints. `whole` is never
/// zero here (a bound of the zero cost would make the example a different story), but the
/// guard is written anyway rather than assumed away.
fn percent(part : Double, whole : Double) -> String {
  if @core.approx_zero(whole, abs=1.0e-12) {
    "n/a"
  } else {
    (100.0 * part / whole).to_string() + "%"
  }
}

///|
/// Small local helper so the example stays readable.
fn status_text(status : @moonopt.SolveStatus) -> String {
  match status {
    @moonopt.SolveStatus::Optimal => "optimal"
    @moonopt.SolveStatus::Infeasible => "infeasible"
    @moonopt.SolveStatus::Unbounded => "unbounded"
    @moonopt.SolveStatus::NodeLimit => "stopped at the node budget"
    @moonopt.SolveStatus::NotSolved => "not solved"
  }
}
