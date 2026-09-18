///|
/// Repairing a relaxation's dual solution before it is offered as a certificate.
///
/// A linear relaxation's optimal dual is not unique when the optimum is degenerate, and the
/// point in that face a simplex lands on can carry a multiplier whose sign is wrong by
/// round-off. The certificate that follows is then refused by `verify` for its signs while
/// every other measurement agrees: on `blend2` node 159 the verifier reported dual signs
/// `2.29e-7` against a tolerance of `1e-7`, dual feasibility `0`, complementarity `0` on
/// both sides, a duality gap of `3.5e-13` and the claimed objective exact — an optimality
/// argument that is right and a multiplier that is not.
///
/// The multiplier is not wrong in a way that matters *there*: it multiplies a row the point
/// sits on, so setting it to zero moves the bound by `y · slack`, and the slack is zero.
/// That is what this file does — clamp the offending multipliers that a tight row makes
/// free, and leave everything else alone — and it does not decide anything by itself: the
/// repaired certificate goes through the same independent checker as before, and a repair
/// that moved the bound would be refused there for its duality gap. A producer repairs; the
/// checker judges.
///
/// The violation is measured with the **same** formula and the same scale `verify` uses for
/// its sign check (`raw · row_scale / cost_scale`, with the row's own data as the scale).
/// Measuring it differently — a raw magnitude, or a scale of this file's own choosing — puts
/// the repair and the check out of step, and the two failure modes of that are opposite and
/// both bad: repairing what the checker would have accepted (pointless), or leaving what it
/// refuses (the run stops at a limit for no reason).

///|
/// The scale the row multipliers are judged against: the largest objective coefficient, or
/// `1` when the objective is empty. The same number `verify` computes.
fn cost_scale(model : @model.Model) -> Double {
  let mut scale = 1.0
  for term in model.objective() {
    let magnitude = @core.fabs(term.1)
    if magnitude > scale {
      scale = magnitude
    }
  }
  scale
}

///|
/// The scale a row's multiplier is judged against by the **sign** check: the largest
/// coefficient of the row, with a floor of one.
///
/// Not the same number as `verify`'s `row_scale`, which is `1 + |b| + Σ|aⱼxⱼ|` and is what
/// its *complementarity* check measures with. This file used the latter first, and the
/// repair then declined to fire on the very multiplier the checker was refusing: the two
/// scales differ by whatever the point contributes, and reading one for the other is how a
/// producer and a checker end up measuring different things while both look right.
fn row_sign_scale(model : @model.Model, row : Int) -> Double {
  let constraint = model.constraint(row)
  let mut scale = 1.0
  for term in constraint.terms {
    let magnitude = @core.fabs(term.1)
    if magnitude > scale {
      scale = magnitude
    }
  }
  scale
}

///|
/// The same solution with the sign-violating multipliers clamped to zero.
///
/// Only `Optimal` claims are repaired: an infeasibility claim's multipliers are a ray whose
/// margin is the whole statement, and zeroing part of it would be editing the proof rather
/// than cleaning it. A multiplier already inside the tolerance is left as it is, because the
/// checker accepts it.
///
/// Nothing here asks whether the row the multiplier acts on is tight. It is tempting to — a
/// tight row is where the clamp is provably free — but a multiplier the checker refuses can
/// sit on a row with slack just as easily, and then two things are true at once: its sign is
/// wrong (so the Lagrangian argument does not go through) and it is so small that leaving it
/// is not an option either. Which of the two the clamp costs is a question this file cannot
/// answer, and does not have to: the repaired certificate goes through the checker, whose
/// duality gap measures exactly that — what the clamped bound is worth — and refuses it if
/// the answer is "less than the objective". A repair that can only be accepted when it is
/// right is worth more than one that decides for itself.
fn repaired_duals(
  model : @model.Model,
  solution : NodeSolution,
  tolerance : Double,
) -> NodeSolution {
  if solution.status != NodeStatus::Optimal || solution.duals.length() == 0 {
    return solution
  }
  let cost = cost_scale(model)
  let duals = solution.duals.copy()
  let mut repaired = 0
  for i = 0; i < model.num_constraints() && i < duals.length(); i = i + 1 {
    let constraint = model.constraint(i)
    // An equality row's multiplier is free, so there is no sign to repair.
    if constraint.rel == @model.Rel::Equal {
      continue
    }
    let raw = @core.fmax(0.0, -duals[i])
    if raw <= 0.0 {
      continue
    }
    if raw * row_sign_scale(model, i) / cost <= tolerance {
      continue
    }
    duals[i] = 0.0
    repaired = repaired + 1
  }
  if repaired == 0 {
    return solution
  }
  {
    status: solution.status,
    values: solution.values,
    objective: solution.objective,
    duals,
    ray: solution.ray,
  }
}
