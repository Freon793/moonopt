///|
/// Public entry points of `moonopt`.
///
/// This package is orchestration only: it validates a `@model.Model`, adapts it
/// into the form a kernel accepts, calls the kernel, and reports the outcome.
/// Algorithm details live in the kernel packages — see `docs/design.md`.
///
/// Current capability (D1): the only kernel wired up is `oracle`, the dense
/// reference implementation. It handles continuous variables with `x >= 0`,
/// finite upper bounds (added as explicit rows) and any mix of `≤`, `≥`, `=`
/// rows. Anything outside that class returns `NotSolved` together with the
/// reason — never a plausible but unverified answer.

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
  let (problem, reason) = to_kernel(model)
  match problem {
    None =>
      return {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: 0,
        message: reason,
      }
    Some(kernel) => {
      let res = @oracle.solve_standard(
        kernel.num_vars,
        kernel.objective,
        kernel.rows,
        max_iterations=options.max_iterations,
      )
      let sign = kernel.objective_sign
      match res.status {
        @oracle.Optimal =>
          {
            status: Optimal,
            values: res.values,
            objective: sign * res.objective,
            iterations: res.iterations,
            message: "",
          }
        @oracle.Infeasible =>
          {
            status: Infeasible,
            values: [],
            objective: 0.0,
            iterations: res.iterations,
            message: "no feasible point exists",
          }
        @oracle.Unbounded =>
          {
            status: Unbounded,
            values: [],
            objective: 0.0,
            iterations: res.iterations,
            message: "the objective is unbounded on the feasible set",
          }
        @oracle.IterationLimit =>
          {
            status: NotSolved,
            values: [],
            objective: 0.0,
            iterations: res.iterations,
            message: "iteration limit reached before optimality was proven",
          }
      }
    }
  }
}

///|
/// A model as the kernel sees it.
///
/// `objective_sign` is `1.0` for a maximisation and `-1.0` for a minimisation,
/// because the kernel only maximises; multiplying the kernel objective value by
/// the sign gives the value in the model's own units.
priv struct KernelProblem {
  num_vars : Int
  objective : Array[Double]
  rows : Array[(Array[Double], @model.Rel, Double)]
  objective_sign : Double
}

///|
/// Adapts a model into the kernel's standard form.
///
/// Returns `(Some(problem), "")` on success, or `(None, reason)` when the model
/// uses a construct the current kernel cannot represent. Finite upper bounds are
/// turned into explicit `xⱼ ≤ ub` rows rather than being dropped.
fn to_kernel(model : @model.Model) -> (KernelProblem?, String) {
  let nvars = model.num_vars()
  let sign = if model.sense() == @model.Sense::Minimize { -1.0 } else { 1.0 }
  let objective : Array[Double] = []
  for j = 0; j < nvars; j = j + 1 {
    objective.push(0.0)
  }
  let obj_terms = model.objective()
  for k = 0; k < obj_terms.length(); k = k + 1 {
    let (index, coeff) = obj_terms[k]
    objective[index] = sign * coeff
  }
  let rows : Array[(Array[Double], @model.Rel, Double)] = []
  for j = 0; j < nvars; j = j + 1 {
    let variable = model.get_var(j)
    if variable.is_int {
      return (
        None,
        "integer variables are not supported by the current kernel (planned for the branch-and-bound stage)",
      )
    }
    if !@core.approx_zero(variable.lb, abs=1.0e-9) {
      return (
        None,
        "the current kernel requires lower bounds of zero; variable " +
        variable.name +
        " has lb = " +
        variable.lb.to_string(),
      )
    }
    if variable.ub < @model.infinite_bound {
      let coeff : Array[Double] = []
      for i = 0; i < nvars; i = i + 1 {
        coeff.push(if i == j { 1.0 } else { 0.0 })
      }
      rows.push((coeff, @model.Rel::LessEqual, variable.ub))
    }
  }
  for c = 0; c < model.num_constraints(); c = c + 1 {
    let con = model.constraint(c)
    let coeff : Array[Double] = []
    for j = 0; j < nvars; j = j + 1 {
      coeff.push(0.0)
    }
    for k = 0; k < con.terms.length(); k = k + 1 {
      let (index, value) = con.terms[k]
      coeff[index] = value
    }
    rows.push((coeff, con.rel, con.rhs))
  }
  (Some({ num_vars: nvars, objective, rows, objective_sign: sign, }), "")
}
