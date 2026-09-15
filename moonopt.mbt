///|
/// Public entry points of `moonopt`.
///
/// This package is orchestration only: it validates a `@model.Model`, reduces it
/// with `@presolve` unless the caller turns that off, adapts it into the form the
/// kernel accepts, calls the kernel, and reports the outcome. Algorithm details
/// live in the kernel packages — see `docs/design.md`.
///
/// Current capability: continuous models with `x >= 0`, finite upper bounds (added
/// as explicit rows) and any mix of `≤`, `≥`, `=` rows, with integer models handled
/// through their LP relaxation. Anything outside that class returns `NotSolved`
/// together with the reason — never a plausible but unverified answer.
///
/// With presolve on — the default — the model is reduced first and the kernel's
/// solution is mapped back to the original variables. The way back is *verified*,
/// not assumed: a reconstructed solution is reported as `Optimal` only after the
/// original model agrees that it satisfies its rows and bounds and that the
/// objective, recomputed from the original cost vector, is the number being
/// reported. A reduction that fails that check becomes `NotSolved` with the
/// measured violations, because a wrong answer carrying a confident status is the
/// one outcome this package exists to prevent.

///|
/// Row and bound violation a reconstructed solution may carry before it is
/// refused. The same scale the kernel uses for its own feasibility decision.
let reconstruction_tolerance : Double = 1.0e-7

///|
/// Outcome of a solve call.
pub(all) enum SolveStatus {
  Optimal
  Infeasible
  Unbounded
  NotSolved
} derive(Debug, Eq)

///|
/// What a solve call produced.
///
/// `values` is indexed by variable index and is empty unless the status is
/// `Optimal`. `message` carries the reason otherwise, and also the kernel's own
/// note when a run needed its recovery attempt to get there.
pub struct Solution {
  status : SolveStatus
  values : Array[Double]
  objective : Double
  iterations : Int
  message : String
} derive(Debug)

///|
/// Tunables for a solve call.
///
/// `pub(all)` so callers can write `{ max_iterations: 1000, presolve: false }`
/// directly; `SolveOptions::new` is the readable alternative.
pub(all) struct SolveOptions {
  max_iterations : Int
  /// Reduce the model before the kernel sees it and reconstruct the solution
  /// afterwards. On by default: every reduction is proved before it fires and every
  /// reconstruction is checked against the original model. Turn it off to observe
  /// the kernel's own behaviour on the model exactly as written.
  presolve : Bool
} derive(Debug)

///|
/// Default solve options: a generous iteration budget, presolve on.
pub fn SolveOptions::default() -> SolveOptions {
  { max_iterations: 10000, presolve: true, }
}

///|
/// Solve options with an explicit iteration cap, keeping presolve on.
pub fn SolveOptions::new(max_iterations : Int) -> SolveOptions {
  { max_iterations, presolve: true, }
}

///|
/// Maps a kernel result onto the public one.
///
/// A question the kernel cannot answer comes back as `NotSolved` with the kernel's
/// own words; an optimal run keeps its message too, because that is where a run
/// says it had to restart with Bland's rule to get there.
fn from_simplex(result : @simplex.SimplexResult) -> Solution {
  match result.status {
    @simplex.SimplexStatus::Optimal =>
      {
        status: Optimal,
        values: result.values,
        objective: result.objective,
        iterations: result.iterations,
        message: result.message,
      }
    @simplex.SimplexStatus::Infeasible =>
      {
        status: Infeasible,
        values: [],
        objective: 0.0,
        iterations: result.iterations,
        message: result.message,
      }
    @simplex.SimplexStatus::Unbounded =>
      {
        status: Unbounded,
        values: [],
        objective: 0.0,
        iterations: result.iterations,
        message: result.message,
      }
    @simplex.SimplexStatus::IterationLimit =>
      {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: result.iterations,
        message: result.message,
      }
    @simplex.SimplexStatus::NumericalFailure =>
      {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: result.iterations,
        message: result.message,
      }
    @simplex.SimplexStatus::TooLarge =>
      {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: 0,
        message: result.message,
      }
  }
}

///|
/// Solves `model` with default options.
pub fn solve(model : @model.Model) -> Solution {
  solve_with(model, SolveOptions::default())
}

///|
/// `true` when the model has at least one integer variable.
fn has_integer_variables(model : @model.Model) -> Bool {
  for j = 0; j < model.num_vars(); j = j + 1 {
    if model.get_var(j).is_int {
      return true
    }
  }
  false
}

///|
/// Solves `model` and returns a `Solution` describing what happened.
///
/// The work happens in the `simplex` kernel; this function validates the model,
/// reduces it, maps the kernel's status onto the public one, and makes sure that a
/// question the kernel cannot answer comes back as `NotSolved` with a reason rather
/// than as a plausible looking answer.
///
/// The reduction is never trusted on its own account. When presolve proves the
/// model infeasible or unbounded, that verdict is returned without a kernel run;
/// when it returns a reduced model, the kernel's solution is reconstructed and then
/// measured against the **original** rows, bounds and objective, and a
/// reconstruction that does not verify turns into `NotSolved` rather than an
/// answer.
///
/// Integer models are the one class the reduction is not offered: the kernel
/// refuses them until the MIP stage, and that promise must not depend on whether a
/// reduction happened to fix every integer variable — that is also exactly where a
/// fractional fixed value would slip through. Such a model goes straight to the
/// kernel, which answers with its refusal.
pub fn solve_with(model : @model.Model, options : SolveOptions) -> Solution {
  let issues = model.validate()
  if issues.length() > 0 {
    return {
      status: NotSolved,
      values: [],
      objective: 0.0,
      iterations: 0,
      message: "model is not well formed: " + issues[0],
    }
  }
  let kernel_options = @simplex.SimplexOptions::with_max_iterations(
    options.max_iterations,
  )
  if !options.presolve || has_integer_variables(model) {
    return match @simplex.solve_model_with(model, kernel_options) {
      Err(reason) =>
        {
          status: NotSolved,
          values: [],
          objective: 0.0,
          iterations: 0,
          message: reason,
        }
      Ok(result) => from_simplex(result)
    }
  }
  let presolved = @presolve.presolve(model)
  match presolved.verdict() {
    @presolve.PresolveVerdict::Infeasible =>
      {
        status: Infeasible,
        values: [],
        objective: 0.0,
        iterations: 0,
        message: presolved.reason(),
      }
    @presolve.PresolveVerdict::Unbounded =>
      {
        status: Unbounded,
        values: [],
        objective: 0.0,
        iterations: 0,
        message: presolved.reason(),
      }
    @presolve.PresolveVerdict::Reduced => {
      let reduced = presolved.reduced()
      if reduced.num_vars() == 0 {
        // Every variable was decided by the reduction, so its own answer is the
        // whole answer — and it still goes through the same reconstruction check
        // as any other solution before it leaves this function.
        let values = presolved.reconstruct([])
        let objective = presolved.objective(0.0)
        let rows = @presolve.max_row_violation(model, values)
        let bounds = @presolve.max_bound_violation(model, values)
        let recomputed = @presolve.objective_value(model, values)
        if rows > reconstruction_tolerance ||
          bounds > reconstruction_tolerance ||
          !@core.approx_eq(objective, recomputed, rel=1.0e-9, abs=1.0e-6) {
          return {
            status: NotSolved,
            values: [],
            objective: 0.0,
            iterations: 0,
            message: "the reduction decided every variable but its solution did not verify against the original model (worst row violation " +
            rows.to_string() +
            ", worst bound violation " +
            bounds.to_string() +
            ", objective " +
            objective.to_string() +
            " vs " +
            recomputed.to_string() +
            " recomputed from the original model)",
          }
        }
        { status: Optimal, values, objective, iterations: 0, message: "", }
      } else {
        match @simplex.solve_model_with(reduced, kernel_options) {
          Err(reason) =>
            {
              status: NotSolved,
              values: [],
              objective: 0.0,
              iterations: 0,
              message: reason,
            }
          Ok(result) =>
            match result.status {
              @simplex.SimplexStatus::Optimal => {
                let values = presolved.reconstruct(result.values)
                let objective = presolved.objective(result.objective)
                let rows = @presolve.max_row_violation(model, values)
                let bounds = @presolve.max_bound_violation(model, values)
                let recomputed = @presolve.objective_value(model, values)
                if rows > reconstruction_tolerance ||
                  bounds > reconstruction_tolerance ||
                  !@core.approx_eq(
                    objective,
                    recomputed,
                    rel=1.0e-9,
                    abs=1.0e-6,
                  ) {
                  return {
                    status: NotSolved,
                    values: [],
                    objective: 0.0,
                    iterations: result.iterations,
                    message: "the reduced model solved but its reconstruction did not verify against the original model (worst row violation " +
                    rows.to_string() +
                    ", worst bound violation " +
                    bounds.to_string() +
                    ", objective " +
                    objective.to_string() +
                    " vs " +
                    recomputed.to_string() +
                    " recomputed from the original model)",
                  }
                }
                {
                  status: Optimal,
                  values,
                  objective,
                  iterations: result.iterations,
                  message: result.message,
                }
              }
              _ => from_simplex(result)
            }
        }
      }
    }
  }
}
