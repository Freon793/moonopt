///|
/// Runnable example: minimum cost transportation with balanced supply and
/// demand (a classical LP with equality rows only).
///
///   min 2a + 3b + 1c + 4d
///   s.t. a + b = 3   (plant 1 capacity)
///        c + d = 2   (plant 2 capacity)
///        a + c = 2   (customer 1 demand)
///        b + d = 3   (customer 2 demand)
///        a, b, c, d >= 0
///
/// The optimum is 11 at (0, 3, 2, 0): every row is an equality, so the kernel
/// has to start from an artificial basis and drive it out — the Phase I path.
///
/// Run with: `moon run examples/transportation`
fn main {
  let m = @model.Model::new(@model.Sense::Minimize)
  let a = m.add_var("a")
  let b = m.add_var("b")
  let c = m.add_var("c")
  let d = m.add_var("d")
  m.set_objective([(a, 2.0), (b, 3.0), (c, 1.0), (d, 4.0)])
  m.add_named_constraint(
    [(a, 1.0), (b, 1.0)],
    @model.Rel::Equal,
    3.0,
    "plant_1",
  )
  m.add_named_constraint(
    [(c, 1.0), (d, 1.0)],
    @model.Rel::Equal,
    2.0,
    "plant_2",
  )
  m.add_named_constraint(
    [(a, 1.0), (c, 1.0)],
    @model.Rel::Equal,
    2.0,
    "customer_1",
  )
  m.add_named_constraint(
    [(b, 1.0), (d, 1.0)],
    @model.Rel::Equal,
    3.0,
    "customer_2",
  )
  let sol = @moonopt.solve(m)
  println("transportation: " + status_text(sol.status))
  if sol.status == @moonopt.SolveStatus::Optimal {
    let names : Array[String] = ["a", "b", "c", "d"]
    for i = 0; i < names.length(); i = i + 1 {
      println("  " + names[i] + " = " + sol.values[i].to_string())
    }
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
