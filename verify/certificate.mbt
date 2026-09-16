///|
/// What a certificate claims about a model.
pub(all) enum Claim {
  /// The values are optimal: no feasible point beats them.
  Optimal
  /// The rows cannot all be satisfied, and `duals` is a Farkas ray proving it.
  Infeasible
  /// The values are feasible and `ray` improves the objective forever from them.
  Unbounded
} derive(Debug, Eq)

///|
/// A claim plus the numbers that are supposed to prove it.
///
/// Plain data, on purpose: the verifier checks a certificate from the model and
/// these arrays alone, so whichever code produced it is irrelevant to the verdict.
/// All multipliers follow the convention in the package doc. `pub(all)` so a caller
/// can build one field by field, and so a test can read a verdict apart.
pub(all) struct Certificate {
  claim : Claim
  /// Primal point, one entry per model variable: the optimum, or the feasible point
  /// an unboundedness certificate starts from. Empty for an infeasibility claim.
  values : Array[Double]
  /// Row multipliers, one per model constraint: the dual solution for an optimal
  /// claim, the Farkas ray for an infeasibility claim.
  duals : Array[Double]
  /// Recession direction, one per model variable. Only an unboundedness certificate
  /// fills it in.
  ray : Array[Double]
  /// Objective value in the model's own sense: `max` stays `max`. Only an optimal
  /// claim carries one.
  objective : Double
} derive(Debug)

///|
/// A certificate that claims nothing yet, for callers that fill the arrays in.
pub fn Certificate::empty(claim : Claim) -> Certificate {
  { claim, values: [], duals: [], ray: [], objective: 0.0, }
}

///|
/// One named measurement, with the number it measured and the tolerance it was
/// judged against — a refusal should say how far off the claim was, not only that
/// it was refused.
pub(all) struct Check {
  name : String
  ok : Bool
  measured : Double
  tolerance : Double
} derive(Debug)

///|
/// What the verifier concluded, and every measurement behind it.
pub(all) struct Verdict {
  accepted : Bool
  claim : Claim
  checks : Array[Check]
  /// The first failing check, in words; empty when the claim is accepted.
  reason : String
} derive(Debug)

///|
/// Renders a verdict as one line, for CLI output and test messages.
pub fn Verdict::to_text(self : Verdict) -> String {
  let claim = match self.claim {
    Claim::Optimal => "optimality"
    Claim::Infeasible => "infeasibility"
    Claim::Unbounded => "unboundedness"
  }
  let verdict = if self.accepted { "accepted" } else { "REJECTED" }
  let mut text = "certificate of " + claim + ": " + verdict
  if !self.accepted {
    text = text + " (" + self.reason + ")"
  }
  for check in self.checks {
    text = text +
      "\n  " +
      (if check.ok { "ok  " } else { "FAIL" }) +
      " " +
      check.name +
      " = " +
      check.measured.to_string() +
      (if check.tolerance > 0.0 {
        " (tolerance " + check.tolerance.to_string() + ")"
      } else {
        ""
      })
  }
  text
}
