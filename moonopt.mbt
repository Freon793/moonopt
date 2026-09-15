///|
/// Public entry points of `moonopt`.
///
/// This package is orchestration only: it validates a `@model.Model`, adapts it
/// into the form a kernel accepts, calls the kernel, and reports the outcome.
/// Algorithm details live in the kernel packages — see `docs/design.md`.
///
/// Current capability: the `simplex` kernel solves continuous models with
/// `x >= 0`, finite upper bounds (added as explicit rows) and any mix of `≤`,
/// `≥`, `=` rows, with integer models handled through their LP relaxation.
/// Anything outside that class returns `NotSolved` together with the reason —
/// never a plausible but unverified answer.

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
/// `Optimal`. `message` is empty on success and carries the reason otherwise.
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
/// `pub(all)` so callers can write `{ max_iterations: 1000 }` directly;
/// `SolveOptions::new` is the readable alternative.
pub(all) struct SolveOptions {
  max_iterations : Int
} derive(Debug)

///|
/// Default solve options.
pub fn SolveOptions::default() -> SolveOptions {
  { max_iterations: 10000, }
}

///|
/// Solve options with an explicit iteration cap.
pub fn SolveOptions::new(max_iterations : Int) -> SolveOptions {
  { max_iterations, }
}

///|
/// Solves `model` with default options.
pub fn solve(model : @model.Model) -> Solution {
  solve_with(model, SolveOptions::default())
}

///|
/// Solves `model` and returns a `Solution` describing what happened.
///
/// The work happens in the `simplex` kernel; this function only validates the
/// model, maps the kernel's status onto the public one, and makes sure that a
/// question the kernel cannot answer comes back as `NotSolved` with a reason
/// rather than as a plausible looking answer.
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
  match
    @simplex.solve_model_with(
      model,
      @simplex.SimplexOptions::with_max_iterations(options.max_iterations),
    ) {
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
        @simplex.SimplexStatus::Optimal =>
          {
            status: Optimal,
            values: result.values,
            objective: result.objective,
            iterations: result.iterations,
            message: "",
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
}
