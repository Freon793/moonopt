///|
/// `moonopt` command line interface.
///
/// The first milestone keeps the surface deliberately small: it runs the built-in
/// demos and prints a report, so that the project has a runnable entry point from
/// day one. Argument parsing for `solve` / `verify` / `fmt` / `bench` arrives
/// with the report layer — see `docs/roadmap.md`.
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
  // The three numbers below mean something whenever there is an answer or a bound to
  // report: for a linear solve the objective is its own bound and the gap is zero, for a
  // branch and bound run on a budget they are what says how much is still open.
  if sol.status == @moonopt.SolveStatus::Optimal ||
    sol.status == @moonopt.SolveStatus::NodeLimit {
    println("nodes      : " + sol.nodes.to_string())
    println("bound      : " + sol.bound.to_string())
    println("gap        : " + sol.gap.to_string())
    // `objective` means something only alongside a point: a budget that ran out before the
    // search stood on one reports zero there, and printing that zero as an objective is
    // how a failed run comes to look like an answer.
    if sol.values.length() > 0 {
      println("objective  : " + sol.objective.to_string())
      for i = 0; i < names.length() && i < sol.values.length(); i = i + 1 {
        println("  " + names[i] + " = " + sol.values[i].to_string())
      }
    } else {
      println("objective  : (no integer point yet)")
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
    @moonopt.SolveStatus::NodeLimit => "NodeLimit"
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
/// Demo 3: an integer model, answered by the branch and bound.
///
/// `max 5x + 4y` with `6x + 4y <= 13` over whole `x, y` in `[0, 2]`: the relaxation fills
/// `y` to 2 and gives `x` what is left — 12.1667 — while the whole answer is 10 at
/// `(2, 0)`. The point of the demo is that the number printed is the second one, and that
/// nothing had to be said about relaxations to get it.
fn integer_plan() -> Unit {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", ub=2.0, is_int=true)
  let y = m.add_var("y", ub=2.0, is_int=true)
  m.set_objective([(x, 5.0), (y, 4.0)])
  m.add_constraint([(x, 6.0), (y, 4.0)], @model.Rel::LessEqual, 13.0)
  report("integer plan", ["x", "y"], @moonopt.solve(m))
}

///|
/// Demo 4: the same model on a node budget too small to finish.
///
/// The run says `NodeLimit` and hands back the two numbers that decide what to do next:
/// the best objective still reachable among the nodes left open, and how far the point it
/// has (if any) is from it. What it does not do is call the point an answer.
fn integer_plan_on_a_budget() -> Unit {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", ub=2.0, is_int=true)
  let y = m.add_var("y", ub=2.0, is_int=true)
  m.set_objective([(x, 5.0), (y, 4.0)])
  m.add_constraint([(x, 6.0), (y, 4.0)], @model.Rel::LessEqual, 13.0)
  report(
    "integer plan on a one-relaxation budget",
    ["x", "y"],
    @moonopt.solve_with(m, @moonopt.SolveOptions::with_max_nodes(1)),
  )
}

///|
/// CLI entry point.
fn main {
  println("moonopt " + version)
  println("")
  production_plan()
  transportation()
  integer_plan()
  integer_plan_on_a_budget()
}
