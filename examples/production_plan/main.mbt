///|
/// Runnable example: a two-product production plan.
///
///   max 5x + 4y
///   s.t. 6x + 4y <= 24    (machine hours available)
///        x + 2y <= 6     (labour hours available)
///        x, y >= 0
///
/// The optimum is 21 at (3, 1.5), which is not a vertex of the bounding box,
/// so it exercises a real two-row pivot rather than a trivial case.
///
/// Run with: `moon run examples/production_plan`
fn main {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x")
  let y = m.add_var("y")
  m.set_objective([(x, 5.0), (y, 4.0)])
  m.add_named_constraint(
    [(x, 6.0), (y, 4.0)],
    @model.Rel::LessEqual,
    24.0,
    "machine_hours",
  )
  m.add_named_constraint(
    [(x, 1.0), (y, 2.0)],
    @model.Rel::LessEqual,
    6.0,
    "labour_hours",
  )
  let sol = @moonopt.solve(m)
  println("production plan: " + status_text(sol.status))
  if sol.status == @moonopt.SolveStatus::Optimal {
    println("  x = " + sol.values[0].to_string())
    println("  y = " + sol.values[1].to_string())
    println("  objective = " + sol.objective.to_string())
    println("  iterations = " + sol.iterations.to_string())
  } else {
    println("  " + sol.message)
  }
}

///|
/// Small local helper so the example stays readable.
fn status_text(status : @moonopt.SolveStatus) -> String {
  match status {
    @moonopt.SolveStatus::Optimal => "optimal"
    @moonopt.SolveStatus::Infeasible => "infeasible"
    @moonopt.SolveStatus::Unbounded => "unbounded"
    @moonopt.SolveStatus::NotSolved => "not solved"
  }
}
