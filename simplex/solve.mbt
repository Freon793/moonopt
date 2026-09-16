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

///|
/// Solves a model starting from a basis a previous run left behind.
///
/// This is the reoptimization path a branch and bound tree needs. A bound change
/// leaves every reduced cost alone (they depend on the basis and the objective, not on
/// the bounds) and takes the basic values out of their bounds, so the previous optimal
/// basis is still *dual* feasible and no longer primal feasible — which is exactly the
/// state the dual simplex repairs. Rebuilding Phase I from scratch instead costs the
/// part of a solve that a bound change did not invalidate.
///
/// A warm start is only ever a speedup. The basis has to match this problem's shape and
/// has to be dual feasible, and whatever the dual simplex finishes with goes through the
/// same self-check as a cold run; anything short of that falls back to the cold path, so
/// the answer cannot depend on which path was taken.
pub fn solve_model_with_basis(
  model : @model.Model,
  options : SimplexOptions,
  basis : SimplexBasis,
) -> Result[SimplexResult, String] {
  match from_model_with(model, options.relax_integrality) {
    Err(reason) => Err(reason)
    Ok(problem) =>
      match solve_from_basis(problem, options, basis) {
        Some(result) => Ok(result)
        None => Ok(solve_problem(problem, options))
      }
  }
}

///|
/// Same as `solve_standard_with`, starting from a basis a previous run left behind.
pub fn solve_standard_with_basis(
  num_vars : Int,
  cost : Array[Double],
  rows : Array[(Array[Double], @model.Rel, Double)],
  options : SimplexOptions,
  basis : SimplexBasis,
) -> SimplexResult {
  let problem = KernelProblem::from_standard(num_vars, cost, rows)
  match solve_from_basis(problem, options, basis) {
    Some(result) => result
    None => solve_problem(problem, options)
  }
}
