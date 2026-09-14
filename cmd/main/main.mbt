///|
/// `moonopt` command line interface.
///
/// D1 keeps the surface deliberately small: it runs the built-in demos and
/// prints a report, so that the project has a runnable entry point from day one.
/// Argument parsing for `solve` / `verify` / `fmt` / `bench` lands on D9 — see
/// `docs/roadmap.md`.
///
/// Run with: `moon run cmd/main`

///|
/// Reported version string. Kept in sync with `moon.mod` by hand until the CLI
/// grows a real release command.
let version : String = "0.1.0-dev"

///|
/// Prints a solve result in a stable, greppable format.
fn report(
  title : String,
  names : Array[String],
  sol : @moonopt.Solution,
) -> Unit {
  println("== " + title)
  println("status     : " + status_name(sol.status))
  println("iterations : " + sol.iterations.to_string())
  if sol.status == @moonopt.SolveStatus::Optimal {
    println("objective  : " + sol.objective.to_string())
    for i = 0; i < names.length() && i < sol.values.length(); i = i + 1 {
      println("  " + names[i] + " = " + sol.values[i].to_string())
    }
  } else {
    println("message    : " + sol.message)
  }
  println("")
}

///|
/// Human readable status name.
fn status_name(status : @moonopt.SolveStatus) -> String {
  match status {
    @moonopt.SolveStatus::Optimal => "Optimal"
    @moonopt.SolveStatus::Infeasible => "Infeasible"
    @moonopt.SolveStatus::Unbounded => "Unbounded"
    @moonopt.SolveStatus::NotSolved => "NotSolved"
  }
}

///|
/// Demo 1: two-product production plan.
///
///   max 5x + 4y  s.t.  6x + 4y <= 24,  x + 2y <= 6,  x, y >= 0   ->  21
fn production_plan() -> Unit {
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
  report("production plan", ["x", "y"], @moonopt.solve(m))
}

///|
/// Demo 2: minimum cost transportation with balanced supply and demand.
///
///   min 2a + 3b + 1c + 4d
///   s.t. a + b = 3,  c + d = 2,  a + c = 2,  b + d = 3,  all >= 0   ->  11
fn transportation() -> Unit {
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
    "supply_1",
  )
  m.add_named_constraint(
    [(c, 1.0), (d, 1.0)],
    @model.Rel::Equal,
    2.0,
    "supply_2",
  )
  m.add_named_constraint(
    [(a, 1.0), (c, 1.0)],
    @model.Rel::Equal,
    2.0,
    "demand_1",
  )
  m.add_named_constraint(
    [(b, 1.0), (d, 1.0)],
    @model.Rel::Equal,
    3.0,
    "demand_2",
  )
  report("transportation", ["a", "b", "c", "d"], @moonopt.solve(m))
}

///|
/// Demo 3: a model outside the current kernel's class, reported honestly.
fn unsupported_model() -> Unit {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", ub=1.0, is_int=true)
  m.set_objective([(x, 1.0)])
  report("integer model (not supported yet)", ["x"], @moonopt.solve(m))
}

///|
/// CLI entry point.
fn main {
  println("moonopt " + version)
  println("")
  production_plan()
  transportation()
  unsupported_model()
}
