///|
/// Public entry points of the kernel.

///|
/// Solves `min cᵀx` subject to `rows` (`a·x {≤, ≥, =} b`) and `x ≥ 0`.
///
/// This is the same problem shape the reference solver in `oracle` accepts, so
/// the two can be compared directly.
pub fn solve_standard(
  num_vars : Int,
  cost : Array[Double],
  rows : Array[(Array[Double], @model.Rel, Double)],
) -> SimplexResult {
  solve_standard_with(num_vars, cost, rows, SimplexOptions::default())
}

///|
/// Same as `solve_standard` with explicit options.
pub fn solve_standard_with(
  num_vars : Int,
  cost : Array[Double],
  rows : Array[(Array[Double], @model.Rel, Double)],
  options : SimplexOptions,
) -> SimplexResult {
  solve_problem(KernelProblem::from_standard(num_vars, cost, rows), options)
}

///|
/// Solves a model with default options.
///
/// `Err` carries the reason the model cannot be handed to the linear kernel
/// (integer variables, for now); a model that is merely hard comes back as a
/// result whose status says so.
pub fn solve_model(model : @model.Model) -> Result[SimplexResult, String] {
  solve_model_with(model, SimplexOptions::default())
}

///|
/// Same as `solve_model` with explicit options.
pub fn solve_model_with(
  model : @model.Model,
  options : SimplexOptions,
) -> Result[SimplexResult, String] {
  match from_model_with(model, options.relax_integrality) {
    Err(reason) => Err(reason)
    Ok(problem) => Ok(solve_problem(problem, options))
  }
}
