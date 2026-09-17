///|
/// Public entry points of `moonopt`.
///
/// This package is orchestration only: it validates a `@model.Model`, reduces it
/// with `@presolve` unless the caller turns that off, adapts it into the form the
/// kernel accepts, calls the kernel, and reports the outcome. Algorithm details
/// live in the kernel packages — see `docs/design.md`.
///
/// Current capability: continuous models with `x >= 0`, finite upper bounds and any
/// mix of `≤`, `≥`, `=` rows, solved by the sparse revised simplex with the presolve
/// reduction on by default; and models with integer variables, handed to the branch
/// and bound package (`mip`) which proves every relaxation it branches on. Anything
/// outside that class returns `NotSolved` together with the reason — never a
/// plausible but unverified answer.
///
/// A model with integer variables is the one class the presolve reduction is not
/// offered. The kernel answers a relaxation when it is asked for one, but this entry
/// point never reports a relaxation as if it were an answer to an integer model: the
/// model goes to the branch and bound, whose statuses map onto `Optimal`,
/// `Infeasible`, and — when the node budget runs out with work left — `NodeLimit`,
/// where `values` is a feasible integer point that is *not* proven optimal and
/// `bound`/`gap` say how much room is left.
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
  /// The answer is proven: for a linear model the kernel's own residual and dual checks
  /// stand behind it, and for a model with integer variables every relaxation the
  /// branch and bound branched on was checked by `verify` and the tree was exhausted (or
  /// every open bound was closed against the incumbent).
  Optimal
  /// No feasible point exists, and that is proven — a Farkas ray for a linear model, an
  /// exhausted tree with no integer point for one with integer variables.
  Infeasible
  /// The objective has no bound on the feasible set (a linear model; for an integer
  /// model an unbounded *relaxation* is reported as `NotSolved`, because an improving
  /// ray of the relaxation need not carry any lattice points).
  Unbounded
  /// The search stopped at the node budget with work left. `values` is a feasible
  /// integer point that is **not** proven optimal, and `bound` and `gap` are the two
  /// numbers a caller decides on: the best objective still reachable among the nodes
  /// left open, and how far the incumbent can still be beaten.
  NodeLimit
  /// Nothing was proven, and `message` says why: the iteration or node budget ran out
  /// without an answer, the model is outside the class this solver accepts, an
  /// unbounded relaxation says nothing about the integer model, or a certificate was
  /// refused by the independent checker.
  NotSolved
} derive(Debug, Eq)

///|
/// What a solve call produced.
///
/// `values` is indexed by variable index. It is empty unless the status is `Optimal` or
/// `NodeLimit`; for `NodeLimit` it is a feasible integer point that is not proven
/// optimal. `message` carries the reason otherwise, and also the kernel's or the
/// search's own note when a run needed its recovery attempt or reached no verdict on a
/// relaxation.
pub struct Solution {
  status : SolveStatus
  values : Array[Double]
  /// The objective at `values`, in the model's own sense. Meaningful only when `values`
  /// is not empty: a run that never stood on a feasible point reports zero here, and it
  /// is `values` — not this number — that says whether there is a point at all.
  objective : Double
  /// Pivots the kernel ran. A branch and bound run counts relaxations instead, in
  /// `nodes`, because that is what its budget is spent on.
  iterations : Int
  /// Relaxations a branch and bound run solved, including the ones its primal heuristic
  /// spent walking a fractional node down to a whole point. Zero for a linear solve.
  nodes : Int
  /// The best objective still reachable among the work left open, in the model's sense.
  /// Equal to `objective` when nothing is left to prove — a linear solve is its own
  /// bound, so it is equal there too — and the number `gap` is measured against
  /// otherwise.
  bound : Double
  /// How far the incumbent can still be beaten: the difference between `objective` and
  /// `bound` in the model's own scale, so zero means proven optimal. Carried separately
  /// because it is the number a caller decides on, and recomputing it from two numbers
  /// whose sense the caller has to know is how that decision goes wrong.
  gap : Double
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
  ///
  /// A model with integer variables skips the reduction either way: see the package
  /// doc for why that promise must not depend on what a reduction happened to fix.
  presolve : Bool
  /// Relaxations a model with integer variables may solve, including the ones the primal
  /// heuristic spends. Reaching it ends the run as `NodeLimit` with the incumbent and the
  /// bound still open. Ignored by a linear solve, which spends `max_iterations` instead.
  max_nodes : Int
} derive(Debug)

///|
/// Default solve options: a generous iteration budget and node budget, presolve on.
pub fn SolveOptions::default() -> SolveOptions {
  { max_iterations: 10000, presolve: true, max_nodes: 20000, }
}

///|
/// Solve options with an explicit iteration cap, keeping presolve on.
pub fn SolveOptions::new(max_iterations : Int) -> SolveOptions {
  { max_iterations, presolve: true, max_nodes: 20000, }
}

///|
/// Solve options with an explicit node budget, for a model with integer variables.
pub fn SolveOptions::with_max_nodes(max_nodes : Int) -> SolveOptions {
  { max_iterations: 10000, presolve: true, max_nodes, }
}

///|
/// Maps a kernel result onto the public one.
///
/// A question the kernel cannot answer comes back as `NotSolved` with the kernel's
/// own words; an optimal run keeps its message too, because that is where a run
/// says it had to restart with Bland's rule to get there.
///
/// A linear solve is its own bound: an optimal one has nothing left open, so `bound` is
/// the objective and `gap` is zero, which is what makes the two fields mean the same
/// thing on every path that fills them in.
fn from_simplex(result : @simplex.SimplexResult) -> Solution {
  match result.status {
    @simplex.SimplexStatus::Optimal =>
      {
        status: Optimal,
        values: result.values,
        objective: result.objective,
        iterations: result.iterations,
        nodes: 0,
        bound: result.objective,
        gap: 0.0,
        message: result.message,
      }
    @simplex.SimplexStatus::Infeasible =>
      {
        status: Infeasible,
        values: [],
        objective: 0.0,
        iterations: result.iterations,
        nodes: 0,
        bound: 0.0,
        gap: 0.0,
        message: result.message,
      }
    @simplex.SimplexStatus::Unbounded =>
      {
        status: Unbounded,
        values: [],
        objective: 0.0,
        iterations: result.iterations,
        nodes: 0,
        bound: 0.0,
        gap: 0.0,
        message: result.message,
      }
    @simplex.SimplexStatus::IterationLimit =>
      {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: result.iterations,
        nodes: 0,
        bound: 0.0,
        gap: 0.0,
        message: result.message,
      }
    @simplex.SimplexStatus::NumericalFailure =>
      {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: result.iterations,
        nodes: 0,
        bound: 0.0,
        gap: 0.0,
        message: result.message,
      }
    @simplex.SimplexStatus::TooLarge =>
      {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: 0,
        nodes: 0,
        bound: 0.0,
        gap: 0.0,
        message: result.message,
      }
  }
}

///|
/// Maps a branch and bound result onto the public one.
///
/// Only the search's own `Optimal` becomes `Optimal` here, and `NodeLimit` becomes
/// `NodeLimit` rather than `NotSolved`: a budget that ran out with an incumbent and an
/// open bound is a state a caller can act on, and flattening it into "nothing was
/// proven" would throw away the two numbers that say how much is left.
///
/// The three statuses that are *not* an answer to the question all come back as
/// `NotSolved`, each with the search's own words: an unbounded relaxation (an improving
/// ray of the relaxation carries no integrality of its own), a certificate the
/// independent checker refused (the kernel is wrong somewhere, which is not a statement
/// about this model), and a model that failed validation. None of them may be reported
/// as `Unbounded`, `Optimal` or `Infeasible`, because none of them proves any of those.
fn from_mip(result : @mip.MipResult) -> Solution {
  match result.status {
    @mip.MipStatus::Optimal =>
      {
        status: Optimal,
        values: result.values,
        objective: result.objective,
        iterations: 0,
        nodes: result.nodes,
        bound: result.bound,
        gap: result.gap,
        message: result.message,
      }
    @mip.MipStatus::Infeasible =>
      {
        status: Infeasible,
        values: [],
        objective: 0.0,
        iterations: 0,
        nodes: result.nodes,
        bound: result.bound,
        gap: result.gap,
        message: result.message,
      }
    @mip.MipStatus::NodeLimit =>
      {
        status: NodeLimit,
        values: result.values,
        objective: result.objective,
        iterations: 0,
        nodes: result.nodes,
        bound: result.bound,
        gap: result.gap,
        message: result.message,
      }
    @mip.MipStatus::UnboundedRelaxation =>
      {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: 0,
        nodes: result.nodes,
        bound: result.bound,
        gap: result.gap,
        message: result.message,
      }
    @mip.MipStatus::Unverified =>
      {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: 0,
        nodes: result.nodes,
        bound: result.bound,
        gap: result.gap,
        message: result.message,
      }
    @mip.MipStatus::Invalid =>
      {
        status: NotSolved,
        values: [],
        objective: 0.0,
        iterations: 0,
        nodes: 0,
        bound: 0.0,
        gap: 0.0,
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
/// Integer models are the one class the reduction is not offered: the reduction must not
/// be the reason an integer model gets an answer, because that answer would depend on
/// whether the reduction happened to fix every integer variable — and that is exactly
/// where a fractional fixed value would slip through. Such a model goes straight to the
/// branch and bound, on the model as written.
pub fn solve_with(model : @model.Model, options : SolveOptions) -> Solution {
  let issues = model.validate()
  if issues.length() > 0 {
    return {
      status: NotSolved,
      values: [],
      objective: 0.0,
      iterations: 0,
      nodes: 0,
      bound: 0.0,
      gap: 0.0,
      message: "model is not well formed: " + issues[0],
    }
  }
  if has_integer_variables(model) {
    // Built from the branch and bound's own defaults so this layer cannot drift from
    // them: only the two budgets the caller owns are overridden.
    let base = @mip.MipOptions::default()
    let mip_options : @mip.MipOptions = {
      max_nodes: options.max_nodes,
      max_iterations: options.max_iterations,
      tolerance: base.tolerance,
      verify_nodes: base.verify_nodes,
      dive_steps: base.dive_steps,
      dive_attempts: base.dive_attempts,
      node_solver: base.node_solver,
    }
    return from_mip(@mip.solve_mip(model, mip_options))
  }
  let kernel_options = @simplex.SimplexOptions::with_max_iterations(
    options.max_iterations,
  )
  if !options.presolve {
    return match @simplex.solve_model_with(model, kernel_options) {
      Err(reason) =>
        {
          status: NotSolved,
          values: [],
          objective: 0.0,
          iterations: 0,
          nodes: 0,
          bound: 0.0,
          gap: 0.0,
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
        nodes: 0,
        bound: 0.0,
        gap: 0.0,
        message: presolved.reason(),
      }
    @presolve.PresolveVerdict::Unbounded =>
      {
        status: Unbounded,
        values: [],
        objective: 0.0,
        iterations: 0,
        nodes: 0,
        bound: 0.0,
        gap: 0.0,
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
            nodes: 0,
            bound: 0.0,
            gap: 0.0,
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
        {
          status: Optimal,
          values,
          objective,
          iterations: 0,
          nodes: 0,
          bound: objective,
          gap: 0.0,
          message: "",
        }
      } else {
        match @simplex.solve_model_with(reduced, kernel_options) {
          Err(reason) =>
            {
              status: NotSolved,
              values: [],
              objective: 0.0,
              iterations: 0,
              nodes: 0,
              bound: 0.0,
              gap: 0.0,
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
                    nodes: 0,
                    bound: 0.0,
                    gap: 0.0,
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
                  nodes: 0,
                  bound: objective,
                  gap: 0.0,
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
