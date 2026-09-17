///|
/// Branch and bound over the linear kernel, with every relaxation checked.
///
/// The kernel solves the LP relaxation of a model; this package turns that into an
/// answer for a model with integer variables. The shape is the classical one: relax,
/// branch on a fractional variable, prune by bound, keep the best integral point found.
/// Four things are this package's own choices and worth stating up front.
///
/// **Nothing is reported as an answer until it is proven.** A solve that stops at a
/// limit reports that limit, with the incumbent it has and the bound still open — never
/// `Optimal`. The one status that claims an optimum is the one where the tree is
/// exhausted, or where every remaining node's bound has been closed against the
/// incumbent. A model that fails validation is `Invalid` rather than `Infeasible`,
/// because "these bounds contradict each other" is not a proof that no integer point
/// exists.
///
/// **Every node's relaxation is verified.** The LP solution a node is branched on decides
/// the whole tree, so each one goes through `@verify` — the independent checker, which
/// shares no code with the solver — before it is believed. A certificate the verifier
/// refuses stops the run with `Unverified` and the verifier's own measurements, rather
/// than branching on an answer nothing can justify.
///
/// **An unbounded relaxation is not reported as an unbounded model.** An LP that is
/// unbounded above does not imply the integer problem is: the improving ray may carry no
/// lattice points. Proving a MIP unbounded needs an *integral* ray from an integral
/// feasible point, which this round does not build, so the run says
/// `UnboundedRelaxation` and leaves the question where it is.
///
/// **A bound is worth nothing without a point to compare it to.** Best-bound branching
/// searches for a bound and can spend a whole budget without ever standing on an integer
/// point, and in that state the bound prunes nothing: the first report over the public
/// instances stopped at the node budget on fourteen of them and thirteen had no incumbent
/// at all. So before a fractional relaxation is branched on, one more thing is tried on it
/// — a walk down the nearer whole side of the most fractional variable, re-solving as it
/// goes (`dive_for_incumbent`) — which costs a few of the same relaxations and turns an
/// unknown gap into a number. It only ever *offers* an incumbent, it is bounded by
/// `dive_steps` and `dive_attempts`, and its relaxations are verified like every other one,
/// because being a heuristic is not a reason to trust the kernel more than the tree does.

///|
/// How a branch and bound run ended.
pub(all) enum MipStatus {
  /// The incumbent is optimal: the tree is exhausted, or every open node's bound is
  /// closed against it.
  Optimal
  /// No integer point satisfies the model.
  Infeasible
  /// The node limit was reached with work left. The incumbent, if any, is a feasible
  /// integer point and is **not** proven optimal.
  NodeLimit
  /// A relaxation came back unbounded. The model may or may not be unbounded; see the
  /// package doc.
  UnboundedRelaxation
  /// A node's certificate was refused by the verifier. The run stops rather than
  /// branching on it.
  Unverified
  /// The model failed validation, so nothing is claimed about it. Kept apart from
  /// `Infeasible`: "this model has a contradictory bound" and "no integer point satisfies
  /// this model" are different statements, and only the second one is a proof.
  Invalid
} derive(Debug, Eq)

///|
/// What a branch and bound run produced.
pub struct MipResult {
  status : MipStatus
  /// Best integer point found, empty when the run proved infeasibility or found none.
  values : Array[Double]
  /// Its objective in the model's own sense. Only meaningful when `values` is not empty.
  objective : Double
  /// Bound on the best possible objective among the nodes still open, in the model's
  /// sense. Equal to the objective when the run proved optimality; the gap a caller
  /// should look at otherwise.
  bound : Double
  /// How far the incumbent can still be beaten: the difference between the objective and
  /// that bound, in the model's own scale, so zero means proven optimal. Carried
  /// separately because it is the number a caller decides on, and recomputing it from two
  /// numbers whose sense the caller has to know is how that decision goes wrong.
  gap : Double
  /// Nodes whose relaxation was solved (and verified).
  nodes : Int
  /// Nodes whose relaxation was verified. Equal to `nodes` unless verification is off or
  /// a relaxation reached no verdict: with `verify_nodes` on, `nodes - verified` is
  /// exactly the number of relaxations that did not finish, because every relaxation that
  /// did reach a verdict went through the verifier. The tests assert the equality — it is
  /// the evidence for "every re-solve is checked".
  verified : Int
  /// The verifier's account of the first refusal, when the run ended `Unverified`; the
  /// reason a run ended otherwise (an invalid model, a limit, an unbounded relaxation).
  message : String
} derive(Debug)

///|
/// One node's relaxation, as the branch and bound needs it.
///
/// The kernel's own result carries more than this, and the split is deliberate: a test can
/// build one of these by hand — a wrong answer with a plausible shape — and hand it to the
/// branch and bound through `MipOptions::node_solver` to check that the verifier catches
/// it before it can become the incumbent. A `SimplexResult` cannot be built outside the
/// kernel, which is the right property for the kernel and the wrong one for this test.
pub(all) struct NodeSolution {
  status : NodeStatus
  values : Array[Double]
  objective : Double
  /// Row multipliers, or the Farkas ray of an infeasibility claim.
  duals : Array[Double]
  /// Recession direction of an unboundedness claim.
  ray : Array[Double]
}

///|
/// How one node's relaxation ended, in the terms the branch and bound works in.
pub(all) enum NodeStatus {
  Optimal
  Infeasible
  Unbounded
  /// The relaxation did not finish (iteration limit, numerical failure).
  Unfinished
} derive(Debug, Eq)

///|
/// Knobs for a branch and bound run.
pub(all) struct MipOptions {
  /// Largest number of nodes to process. Reaching it ends the run with `NodeLimit`.
  max_nodes : Int
  /// Iteration cap handed to each relaxation.
  max_iterations : Int
  /// Two objectives closer than this are the same objective, which is how "integral
  /// enough" and "the bound is closed" are decided.
  tolerance : Double
  /// Verify every node's relaxation with `@verify` before branching on it. On by
  /// default; the tests turn it off to show it changes nothing but the count.
  verify_nodes : Bool
  /// How many relaxations one launch of the primal heuristic may spend walking a node's
  /// relaxation down to a whole point, or `0` to switch the heuristic off.
  ///
  /// The heuristic exists because best-bound branching without one spends a budget
  /// without ever producing an incumbent, and an incumbent is what turns a bound into
  /// pruning: of the fourteen instances the first report stopped at the node budget on,
  /// thirteen had no integer point at all. It follows the nearer whole side of the most
  /// fractional variable and re-solves, which is a solve per step, so the step count is
  /// the knob that says how much that is worth.
  ///
  /// Sixty is measured, not chosen: the walk usually needs more than one step per
  /// undecided integer, because re-solving can make a *different* variable fractional, so
  /// the count of fractional variables does not have to fall every step. `pk1` reached one
  /// fractional variable after thirty steps and landed within sixty; `markshare1` (no
  /// incumbent at thirty) and `markshare2` landed the same way. The cost is bounded by
  /// `dive_attempts` launches of at most this many relaxations — two launches of sixty out
  /// of a three hundred relaxation budget in the report's setting — and what the tree
  /// loses to that is visible in the report's remaining-open column rather than hidden.
  dive_steps : Int
  /// How many times the heuristic may be launched. A dive that ends infeasible or runs
  /// out of steps found nothing, and another launch from a deeper node starts closer to a
  /// whole point — but each launch costs up to `dive_steps` relaxations, so the number of
  /// launches is bounded separately from their length.
  dive_attempts : Int
  /// Replaces the default node solver. Only tests use it.
  node_solver : ((@model.Model) -> NodeSolution)?
}

///|
/// Defaults: a node budget rather than a time budget (a clock is a caller's tool, and this
/// package stays free of one), a relaxation cap in the kernel's usual range, and
/// verification on.
///
/// The primal heuristic gets thirty relaxations per launch and two launches, so it can
/// never be more than sixty of the node budget — the budget bounds the run, and a
/// heuristic that ate it would be a way of not searching.
pub fn MipOptions::default() -> MipOptions {
  {
    max_nodes: 20000,
    max_iterations: 20000,
    tolerance: 1.0e-7,
    verify_nodes: true,
    dive_steps: 60,
    dive_attempts: 2,
    node_solver: None,
  }
}

///|
/// Options with an explicit node budget.
pub fn MipOptions::with_max_nodes(max_nodes : Int) -> MipOptions {
  let base = MipOptions::default()
  {
    max_nodes,
    max_iterations: base.max_iterations,
    tolerance: base.tolerance,
    verify_nodes: base.verify_nodes,
    dive_steps: base.dive_steps,
    dive_attempts: base.dive_attempts,
    node_solver: base.node_solver,
  }
}

///|
/// The same options with verification switched off, for the test that shows the count
/// moves and nothing else does.
pub fn MipOptions::without_verification(self : MipOptions) -> MipOptions {
  {
    max_nodes: self.max_nodes,
    max_iterations: self.max_iterations,
    tolerance: self.tolerance,
    verify_nodes: false,
    dive_steps: self.dive_steps,
    dive_attempts: self.dive_attempts,
    node_solver: self.node_solver,
  }
}

///|
/// The same options with the primal heuristic switched off, so a test can show what the
/// incumbent it finds is worth.
pub fn MipOptions::without_primal_dive(self : MipOptions) -> MipOptions {
  {
    max_nodes: self.max_nodes,
    max_iterations: self.max_iterations,
    tolerance: self.tolerance,
    verify_nodes: self.verify_nodes,
    dive_steps: 0,
    dive_attempts: 0,
    node_solver: self.node_solver,
  }
}

///|
/// The same options with a replacement node solver, for tests that hand the search a
/// wrong relaxation.
pub fn MipOptions::with_node_solver(
  self : MipOptions,
  solver : (@model.Model) -> NodeSolution,
) -> MipOptions {
  {
    max_nodes: self.max_nodes,
    max_iterations: self.max_iterations,
    tolerance: self.tolerance,
    verify_nodes: self.verify_nodes,
    dive_steps: self.dive_steps,
    dive_attempts: self.dive_attempts,
    node_solver: Some(solver),
  }
}
