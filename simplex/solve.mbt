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
/// Whether a warm start's own result can be handed to the caller, or whether the model has to be
/// given to the cold path after all.
///
/// A refusal is not an answer about the model: `NumericalFailure` says the dual path reached a basis
/// whose *certificate* cannot be written down — the multipliers are outside the sign convention a
/// certificate is read in, or the gap the multipliers give does not close. Both are statements about
/// that basis and its arithmetic, and the cold path starts from a different basis and can answer.
/// (An iteration limit is a statement about the cap, and the cold path gets the same one; it is left
/// to the caller, whose accounting calls a relaxation that reached no verdict exactly that.)
///
/// This is the rule the doc comment of `solve_model_with_basis` states, and until round 39 it was not
/// implemented for the refusal case: `solve_from_basis` returns such a result as `Some`, so the
/// fallback that exists for `None` was bypassed. Measured on `blend2`: forty of the 24 743 node
/// relaxations of a run whose tree is otherwise *empty* came back `NumericalFailure` on the warm path
/// while a cold solve of the very same model reached a verdict, which is what kept the run from
/// proving the instance.
fn warm_result_is_usable(status : SimplexStatus) -> Bool {
  status != SimplexStatus::NumericalFailure
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
        Some(result) =>
          if warm_result_is_usable(result.status) {
            Ok(result)
          } else {
            Ok(solve_problem(problem, options))
          }
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
    Some(result) =>
      if warm_result_is_usable(result.status) {
        result
      } else {
        solve_problem(problem, options)
      }
    None => solve_problem(problem, options)
  }
}
