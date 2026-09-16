///|
/// What the verifier has to get right.
///
/// The tests are written from the outside: a model, a certificate, and what the
/// verdict has to be. The ones that matter most are the refusals — a verifier that
/// accepts everything is worse than no verifier, and the interesting failures to
/// catch are the answers that look right (a feasible point that is not optimal, duals
/// that are plausible but not feasible, a solution off by a hair).

///|
/// `min 3x + 2y  s.t.  x + y ≥ 4,  x + 3y ≥ 6,  x, y ≥ 0` — optimum 8 at (0, 4),
/// with multipliers 2 on the first row and 0 on the second.
fn two_variable_lp() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(x, 3.0), (y, 2.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::GreaterEqual, 4.0)
  model.add_constraint([(x, 1.0), (y, 3.0)], @model.Rel::GreaterEqual, 6.0)
  model
}

///|
/// Builds a certificate without going through the constructor.
fn certificate(
  claim : @verify.Claim,
  values : Array[Double],
  duals : Array[Double],
  ray : Array[Double],
  objective : Double,
) -> @verify.Certificate {
  { claim, values, duals, ray, objective, }
}

///|
/// `min −x  s.t.  x ≥ 1,  x ≥ 0`.
fn ray_lp() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  model.set_objective([(x, -1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 1.0)
  model
}

///|
/// A point that satisfies every row of `two_variable_lp` and is not optimal.
fn feasible_not_optimal() -> Array[Double] {
  [4.0, 1.0]
}

///|
test "an optimality certificate is accepted" {
  let model = two_variable_lp()
  let verdict = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, [0.0, 4.0], [2.0, 0.0], [], 8.0),
  )
  assert_true(verdict.accepted)
  // Two shape checks and eight measurements: feasibility of the point, the signs and
  // feasibility of the multipliers, both halves of complementary slackness, the gap,
  // and the certificate's own objective.
  assert_eq(verdict.checks.length(), 10)
  for item in verdict.checks {
    assert_true(item.ok)
  }
}

///|
test "a feasible but non-optimal point is rejected" {
  let model = two_variable_lp()
  let values = feasible_not_optimal()
  // Feasible, so the primal checks pass: the refusal has to come from the optimality
  // argument, not from feasibility. With the true multipliers the point violates
  // complementary slackness and the duality gap.
  let verdict = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, values, [2.0, 0.0], [], 14.0),
  )
  assert_false(verdict.accepted)
  assert_true(
    verdict.reason.contains("complementarity") ||
    verdict.reason.contains("duality gap"),
  )
}

///|
test "a point that misses feasibility by little is rejected" {
  let model = two_variable_lp()
  // 3.999 instead of 4: a plausible number, and still infeasible.
  let verdict = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, [0.0, 3.999], [2.0, 0.0], [], 7.998),
  )
  assert_false(verdict.accepted)
  assert_true(verdict.reason.contains("row feasibility"))
}

///|
test "plausible but wrong multipliers are rejected" {
  let model = two_variable_lp()
  // 1 instead of 2 on the tight row: the point is optimal, the proof is not.
  let verdict = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, [0.0, 4.0], [1.0, 0.0], [], 8.0),
  )
  assert_false(verdict.accepted)
  assert_true(
    verdict.reason.contains("complementarity") ||
    verdict.reason.contains("duality gap"),
  )
}

///|
test "a certificate whose objective does not match its own point is rejected" {
  let model = two_variable_lp()
  let verdict = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, [0.0, 4.0], [2.0, 0.0], [], 7.5),
  )
  assert_false(verdict.accepted)
  assert_true(verdict.reason.contains("claimed objective"))
}

///|
test "a certificate of the wrong shape is rejected before anything is read" {
  let model = two_variable_lp()
  let short = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, [0.0], [2.0, 0.0], [], 8.0),
  )
  assert_false(short.accepted)
  assert_true(short.reason.contains("values dimension"))
  let no_duals = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, [0.0, 4.0], [], [], 8.0),
  )
  assert_false(no_duals.accepted)
  assert_true(no_duals.reason.contains("duals dimension"))
}

///|
/// `x ≤ 1` and `x ≥ 2` cannot both hold. Farkas: multipliers 1 and 1 give
/// `(x − 1) + (2 − x) = 1 > 0` over every `x ≥ 0`, which no feasible point could do.
fn infeasible_lp() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::LessEqual, 1.0)
  model.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 2.0)
  model
}

///|
test "a farkas certificate proves infeasibility" {
  let model = infeasible_lp()
  let verdict = @verify.verify(
    model,
    certificate(@verify.Claim::Infeasible, [], [1.0, 1.0], [], 0.0),
  )
  assert_true(verdict.accepted)
}

///|
test "farkas rays that do not prove anything are rejected" {
  let model = infeasible_lp()
  // No contradiction: `x − 1` is negative for small x.
  let weak = @verify.verify(
    model,
    certificate(@verify.Claim::Infeasible, [], [1.0, 0.0], [], 0.0),
  )
  assert_false(weak.accepted)
  assert_true(weak.reason.contains("farkas margin"))
  // A negative multiplier is not a Farkas ray at all.
  let wrong_sign = @verify.verify(
    model,
    certificate(@verify.Claim::Infeasible, [], [-1.0, 1.0], [], 0.0),
  )
  assert_false(wrong_sign.accepted)
  assert_true(wrong_sign.reason.contains("ray signs"))
  // A ray the box cannot absorb points at infinity, which proves nothing.
  let unabsorbed = @verify.verify(
    model,
    certificate(@verify.Claim::Infeasible, [], [0.0, 1.0], [], 0.0),
  )
  assert_false(unabsorbed.accepted)
  assert_true(unabsorbed.reason.contains("absorbed"))
  // The trivial combination proves nothing either.
  let trivial = @verify.verify(
    model,
    certificate(@verify.Claim::Infeasible, [], [0.0, 0.0], [], 0.0),
  )
  assert_false(trivial.accepted)
}

///|
test "an unboundedness certificate is accepted" {
  let model = ray_lp()
  let verdict = @verify.verify(
    model,
    certificate(@verify.Claim::Unbounded, [1.0], [], [1.0], 0.0),
  )
  assert_true(verdict.accepted)
}

///|
test "rays that are not rays are rejected" {
  let model = ray_lp()
  let zero = @verify.verify(
    model,
    certificate(@verify.Claim::Unbounded, [1.0], [], [0.0], 0.0),
  )
  assert_false(zero.accepted)
  assert_true(zero.reason.contains("ray magnitude"))
  let backwards = @verify.verify(
    model,
    certificate(@verify.Claim::Unbounded, [1.0], [], [-1.0], 0.0),
  )
  assert_false(backwards.accepted)
  // A ray that runs against the row is stopped by the row first.
  assert_true(backwards.reason.contains("rows do not block"))
  // A bounded model cannot be unbounded, whatever the ray says.
  let bounded = @model.Model::new(@model.Sense::Minimize)
  let x = bounded.add_var("x", lb=0.0, ub=5.0)
  bounded.set_objective([(x, -1.0)])
  let bounded_verdict = @verify.verify(
    bounded,
    certificate(@verify.Claim::Unbounded, [0.0], [], [1.0], 0.0),
  )
  assert_false(bounded_verdict.accepted)
  assert_true(bounded_verdict.reason.contains("bounds do not block"))
}

///|
test "a deliberately broken solver's answer is rejected" {
  let model = two_variable_lp()
  // What a solver that is wrong in a plausible way looks like from outside: it finds
  // a feasible point, it reports it with confidence, and its multipliers are the ones
  // a "tight row gets weight one" rule would produce.
  let broken = certificate(
    @verify.Claim::Optimal,
    feasible_not_optimal(),
    [1.0, 1.0],
    [],
    14.0,
  )
  let verdict = @verify.verify(model, broken)
  assert_false(verdict.accepted)
  // And the same solver with the multipliers it would rather have: still refused.
  let almost = certificate(
    @verify.Claim::Optimal,
    feasible_not_optimal(),
    [2.0, 0.0],
    [],
    14.0,
  )
  assert_false(@verify.verify(model, almost).accepted)
  // The honest answer from the same code path is accepted, so the refusal is about
  // the answers and not about the model.
  let honest = certificate(
    @verify.Claim::Optimal,
    [0.0, 4.0],
    [2.0, 0.0],
    [],
    8.0,
  )
  assert_true(@verify.verify(model, honest).accepted)
}

///|
test "a maximisation model is checked in its own sense" {
  // max 3x + 2y  s.t.  x + y ≤ 4,  x + 3y ≤ 6,  x, y ≥ 0  ->  12 at (4, 0).
  // The verifier works in the minimisation sense internally and reports the
  // objective the way the model states it.
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(x, 3.0), (y, 2.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 4.0)
  model.add_constraint([(x, 1.0), (y, 3.0)], @model.Rel::LessEqual, 6.0)
  let accepted = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, [4.0, 0.0], [3.0, 0.0], [], 12.0),
  )
  assert_true(accepted.accepted)
  // A lower vertex claiming to be the maximum: feasible, and refused.
  let greedy = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, [3.0, 1.0], [3.0, 0.0], [], 11.0),
  )
  assert_false(greedy.accepted)
  // And the model-sense objective is the one being checked: signing it as if the
  // model minimised is refused.
  let wrong_sense = @verify.verify(
    model,
    certificate(@verify.Claim::Optimal, [4.0, 0.0], [3.0, 0.0], [], -12.0),
  )
  assert_false(wrong_sense.accepted)
  assert_true(wrong_sense.reason.contains("claimed objective"))
}

///|
test "certificates survive a json round trip" {
  let original = certificate(
    @verify.Claim::Optimal,
    [0.0, 4.0],
    [2.0, 0.0],
    [0.0, 0.0],
    8.0,
  )
  let text = original.to_json()
  assert_true(text.contains("\"claim\":\"optimal\""))
  let parsed = match @verify.Certificate::from_json(text) {
    Some(value) => value
    None => fail("the certificate did not survive the round trip: " + text)
  }
  assert_eq(parsed.claim, original.claim)
  assert_eq(parsed.values.length(), 2)
  assert_eq(parsed.duals.length(), 2)
  assert_true(@core.approx_eq(parsed.objective, 8.0))
  assert_true(@core.approx_eq(parsed.values[1], 4.0))
  assert_true(@core.approx_eq(parsed.duals[0], 2.0))
  // And the parsed one still verifies against the model it came from.
  assert_true(@verify.verify(two_variable_lp(), parsed).accepted)
}

///|
test "malformed json is refused instead of half-read" {
  assert_true(@verify.Certificate::from_json("not json") is None)
  assert_true(@verify.Certificate::from_json("") is None)
  assert_true(@verify.Certificate::from_json("[1,2,3]") is None)
  // Missing arrays.
  assert_true(
    @verify.Certificate::from_json("{\"claim\":\"optimal\",\"values\":[0,4]}")
    is None,
  )
  // Unknown claim.
  assert_true(
    @verify.Certificate::from_json(
      "{\"claim\":\"maybe\",\"values\":[],\"duals\":[],\"ray\":[]}",
    )
    is None,
  )
  // A number that is not a number.
  assert_true(
    @verify.Certificate::from_json(
      "{\"claim\":\"optimal\",\"values\":[0,null],\"duals\":[],\"ray\":[]}",
    )
    is None,
  )
  // Trailing junk.
  assert_true(
    @verify.Certificate::from_json(
      "{\"claim\":\"optimal\",\"values\":[],\"duals\":[],\"ray\":[]} extra",
    )
    is None,
  )
}
