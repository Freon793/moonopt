///|
/// The Lagrangian box minimum: what the tolerance is allowed to decide, and what it is not.
///
/// The band `|rⱼ| ≤ tolerance · scale` is about the *direction* a reduced cost points in —
/// a round-off sized one points nowhere, and calling it a direction to infinity would
/// refuse a certificate whose every other measurement agrees. It is not about the value of
/// the term, which is `|bound| · |rⱼ|` and follows the bound the reduced cost points at.
/// The first version of this function read the band as an answer to both, dropped the term,
/// and so reported a Lagrangian bound too *high* by exactly the terms it dropped — on
/// `blend2`, where the bounds are of order `1e3` and the reduced costs of the failing nodes
/// of order `1e-6`, that is a term of order `1e-3` against a gap tolerance of `1e-7`.

///|
/// `min x₂` subject to `x₁ + x₂ ≥ 1`, `x₁ ∈ [0, 1000]`, `x₂ ∈ [0, 1]`.
///
/// One row with coefficient one on `x₁` and a multiplier of ten makes `x₁`'s reduced cost
/// scale `1 + |c₁| + |a·y| = 1 + 0 + 10 = 11`, so the band at a tolerance of `1e-7` is
/// `1.1e-6`: `1e-6` is inside it and `1e-3` is outside, and the bounds are the `1e2`–`1e3`
/// the real instances have. Every case below is that arithmetic and nothing else.
fn box_minimum_model() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x1 = model.add_var("x1", lb=0.0, ub=1000.0)
  let x2 = model.add_var("x2", lb=0.0, ub=1.0)
  model.set_objective([(x2, 1.0)])
  model.add_constraint([(x1, 1.0), (x2, 1.0)], @model.Rel::GreaterEqual, 1.0)
  model
}

///|
/// A reduced cost inside the band points at the upper bound of a variable of bound `1000`,
/// and the term is `1000 · (−1e-6) = −1e-3` — three orders of magnitude the old code threw
/// away because the reduced cost was small against a scale of `11`.
test "a reduced cost inside the tolerance band is still worth its bound" {
  let model = box_minimum_model()
  let cost = dense_cost(model)
  let duals : Array[Double] = [10.0]
  let value = box_minimum(model, cost, duals, [-1.0e-6, 0.0], 1.0e-7)
  assert_true(@core.approx_eq(value, -1.0e-3, rel=1.0e-12, abs=1.0e-18))
}

///|
/// Outside the band the direction is trusted, and a positive reduced cost takes the lower
/// bound — `0` here. The old code gave the same answer, which is the point: the two are only
/// told apart by what happens *inside* the band.
test "a positive reduced cost outside the band takes the lower bound" {
  let model = box_minimum_model()
  let cost = dense_cost(model)
  let duals : Array[Double] = [10.0]
  assert_eq(box_minimum(model, cost, duals, [1.0e-3, 0.0], 1.0e-7), 0.0)
}

///|
/// And a negative one takes the upper bound, `1000 · (−1e-3) = −1`.
test "a negative reduced cost outside the band takes the upper bound" {
  let model = box_minimum_model()
  let cost = dense_cost(model)
  let duals : Array[Double] = [10.0]
  assert_true(
    @core.approx_eq(
      box_minimum(model, cost, duals, [-1.0e-3, 0.0], 1.0e-7),
      -1.0,
      rel=1.0e-12,
      abs=1.0e-18,
    ),
  )
}

///|
/// A variable with no upper bound, and a reduced cost of the size the real instances have.
///
/// The direction is a negative one, which would want the upper bound; there is none, so the
/// term is dropped and the value stays finite. That is the whole difference inside the band:
/// the term disappears because there is no bound to multiply by, not because the reduced cost
/// was small. Outside the band the same reduced cost *is* read as a direction, and then the
/// missing bound is the sentinel that says this certificate bounds nothing — which is the
/// answer the dual feasibility check already refuses the certificate for.
test "a reduced cost inside the band cannot report that the bound is missing" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  model.set_objective([(x, 10.0)])
  let cost = dense_cost(model)
  // scale = 1 + |c| = 11, so the band is 1.1e-6 again.
  let inside = box_minimum(model, cost, [], [-1.0e-6], 1.0e-7)
  assert_false(is_no_bound(inside))
  assert_eq(inside, 0.0)
  let outside = box_minimum(model, cost, [], [-1.0e-3], 1.0e-7)
  assert_true(is_no_bound(outside))
  assert_true(outside <= -1.0e299)
}
