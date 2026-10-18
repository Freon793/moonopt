///|
/// Runnable example: an integer model whose objective has no bound, and the proof of it.
///
///   max x + y
///   s.t. x - y <= 3
///        x >= 0 integer, y >= 0
///
/// The relaxation is unbounded: nothing stops `y` from growing. That does *not* by itself
/// mean the integer model is unbounded — an improving ray of the relaxation need not carry
/// lattice points — so the branch and bound reports `Unbounded` only when it holds an
/// integral point **and** an integral ray. Both are on the result:
///
///   point  x0 = (0, 0)   and   ray  d = (0, 1),   so  x0 + k*d = (0, k)
///
/// is whole and feasible for every integer `k`, which is the proof.
///
/// Run with: `moon run examples/unbounded`
fn main {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", lb=0.0, is_int=true)
  let y = m.add_var("y", lb=0.0, is_int=false)
  m.set_objective([(x, 1.0), (y, 1.0)])
  m.add_constraint([(x, 1.0), (y, -1.0)], @model.Rel::LessEqual, 3.0)
  let result = @mip.solve_mip(m, @mip.MipOptions::default())
  println("branch and bound: " + mip_status_text(result.status))
  if result.status == @mip.MipStatus::Unbounded {
    println("  point x0 = " + point_text(result.values))
    println("  ray   d  = " + point_text(result.ray))
    println(
      "  every x0 + k*d is whole and feasible, so the integer model is unbounded",
    )
  } else {
    println("  " + result.message)
  }
  // The public entry point reports the same verdict. It does not carry the point and the
  // ray: those are the proof, and they live on the low-level result, the way the kernel's
  // unboundedness certificate does.
  let sol = @moonopt.solve(m)
  println("public status: " + status_text(sol.status))
}

///|
/// A vector as `(a, b, ...)`, so the point and the ray read the same way.
fn point_text(values : Array[Double]) -> String {
  let mut text = "("
  for i = 0; i < values.length(); i = i + 1 {
    if i > 0 {
      text = text + ", "
    }
    text = text + values[i].to_string()
  }
  text + ")"
}

///|
/// The status of a branch and bound run, in words.
fn mip_status_text(status : @mip.MipStatus) -> String {
  match status {
    @mip.MipStatus::Optimal => "optimal"
    @mip.MipStatus::Infeasible => "infeasible"
    @mip.MipStatus::NodeLimit => "stopped at the node budget"
    @mip.MipStatus::UnboundedRelaxation =>
      "unbounded relaxation, model not proven"
    @mip.MipStatus::Unbounded => "unbounded integer model"
    @mip.MipStatus::Unverified => "certificate refused"
    @mip.MipStatus::Invalid => "invalid model"
  }
}

///|
/// The status of a public solve, in words.
fn status_text(status : @moonopt.SolveStatus) -> String {
  match status {
    @moonopt.SolveStatus::Optimal => "optimal"
    @moonopt.SolveStatus::Infeasible => "infeasible"
    @moonopt.SolveStatus::Unbounded => "unbounded"
    @moonopt.SolveStatus::NodeLimit => "stopped at the node budget"
    @moonopt.SolveStatus::NotSolved => "not solved"
  }
}
