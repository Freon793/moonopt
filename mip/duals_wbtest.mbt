///|
/// The dual repair: that it fires on exactly what the checker refuses, that it leaves
/// everything else alone, and that the certificate it hands on is one the checker accepts —
/// the repair is never the judge of its own work.

///|
/// `min x + y` subject to `x ≥ 1`, `y ≥ 0`, `x ≤ 2`.
///
/// Its optimum is `(1, 0)` with objective `1`, and the second row is carried by no
/// multiplier at all: the multiplier of `y ≥ 0` may be any value from zero up without moving
/// the bound, which is what makes this the smallest model in which "the sign is wrong and
/// nothing else notices" can happen.
fn degenerate_dual_model() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=2.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 1.0)
  model.add_constraint([(y, 1.0)], @model.Rel::GreaterEqual, 0.0)
  model
}

///|
/// A certificate for that model whose only flaw is the sign of the second multiplier.
fn degenerate_dual_solution(second : Double) -> NodeSolution {
  {
    status: NodeStatus::Optimal,
    values: [1.0, 0.0],
    objective: 1.0,
    duals: [1.0, second],
    ray: [],
  }
}

///|
/// The certificate with the sign violation the checker refuses is repaired into one the
/// checker accepts, and the violation is measured with the scale the checker measures it
/// with — `raw · max|aᵢⱼ| / max|cⱼ|`, not some scale of the repair's own.
///
/// Two numbers here, one just over the tolerance and one just under: the first has to be
/// clamped and the second left alone. That is the property the first version of the repair
/// got wrong, by measuring the sign against `1 + |b| + Σ|aⱼxⱼ|` (the checker's
/// *complementarity* scale) instead of the row's largest coefficient, and the repair then
/// declined to fire on the very multiplier the verifier was refusing.
test "the repair clamps the sign violation the checker refuses, and only it" {
  let model = degenerate_dual_model()
  let over = degenerate_dual_solution(-1.1e-7)
  let under = degenerate_dual_solution(-0.9e-7)
  let certificate : @verify.Certificate = {
    claim: @verify.Claim::Optimal,
    values: over.values,
    duals: over.duals,
    ray: over.ray,
    objective: over.objective,
  }
  // The checker's own verdict on the unrepaired certificate: refused, and for its signs.
  let refused = @verify.verify(model, certificate)
  assert_true(!refused.accepted)
  assert_true(refused.reason.contains("dual signs"))
  // The repair fires on that one and hands the checker something it accepts.
  let repaired = repaired_duals(model, over, 1.0e-7)
  assert_eq(repaired.duals[0], 1.0)
  assert_eq(repaired.duals[1], 0.0)
  let accepted : @verify.Certificate = {
    claim: @verify.Claim::Optimal,
    values: repaired.values,
    duals: repaired.duals,
    ray: repaired.ray,
    objective: repaired.objective,
  }
  assert_true(@verify.verify(model, accepted).accepted)
  // A violation inside the tolerance is the checker's business and not the repair's.
  let small = repaired_duals(model, under, 1.0e-7)
  assert_eq(small.duals[1], -0.9e-7)
  // And a claim that is not an optimality claim is left alone: a ray's margin is the whole
  // statement, so zeroing part of it would be editing a proof rather than cleaning one.
  let ray : NodeSolution = {
    status: NodeStatus::Infeasible,
    values: [],
    objective: 0.0,
    duals: [1.0, -1.1e-7],
    ray: [],
  }
  assert_eq(repaired_duals(model, ray, 1.0e-7).duals[1], -1.1e-7)
}

///|
/// The order of the two attempts: the run's own certificate is offered first, and the repair
/// only for what the checker refuses.
///
/// That order is the point of this test. Repairing unconditionally is what the first version
/// did, and the clamp's own size is `violation · cost_scale / row_sign_scale`: on a model
/// whose objective is large it can remove a multiplier of real size, which turns a
/// certificate the checker would have accepted into one it refuses on a *different* check
/// (`complementarity (columns)` on `blend2` node 30782, `2.96e-6`). So a certificate the
/// checker accepts has to come back with no refusal and without being touched at all.
test "the certificate is offered before it is repaired, and both are judged" {
  let model = degenerate_dual_model()
  // Accepted as it stands: no refusal, and nothing about it is changed on the way.
  let good = degenerate_dual_solution(0.0)
  assert_eq(node_refusal(model, good, 1.0e-7), "")
  // Refused for its signs, then accepted after the clamp.
  let signed = degenerate_dual_solution(-1.1e-7)
  assert_eq(node_refusal(model, signed, 1.0e-7), "")
  // Refused for a reason no clamp can touch — the point is not on the row its multiplier
  // pays for — so the run keeps the refusal of the certificate it actually got.
  let wrong : NodeSolution = {
    status: NodeStatus::Optimal,
    values: [2.0, 0.0],
    objective: 1.0,
    duals: [1.0, 0.0],
    ray: [],
  }
  let refusal = node_refusal(model, wrong, 1.0e-7)
  assert_true(refusal.length() > 0)
  assert_true(refusal.contains("complementarity (rows)"))
}
