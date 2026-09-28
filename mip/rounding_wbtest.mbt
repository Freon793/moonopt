///|
/// Rouning a relaxation into a whole point: what it accepts and what it refuses.
///
/// The three tests below are the three cases the heuristic lives between. A point that rounds into
/// feasibility is taken; a point whose model has no whole point at all is refused rather than
/// "repaired"; and a point that a rounding leaves just outside a row is refused by the same
/// measurement the independent checker makes, because an incumbent is a feasibility claim and this
/// project has three times paid for a producer that judged a claim by a rule of its own.

///|
/// `max x + y  s.t.  x + y <= 3.3` over the integers in `[0, 4]`: the relaxation sits at
/// `(3.3, 0)` and rounding it down gives `(3, 0)`, which the row admits.
fn roundable_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=4.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=4.0, is_int=true)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 3.3)
  model
}

///|
/// `min x + y  s.t.  x + y = 0.5` over the integers in `[0, 1]`: no whole point satisfies the row,
/// so no rounding of any point can be feasible and the heuristic has nothing to offer.
fn unroundable_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=1.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=1.0, is_int=true)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::Equal, 0.5)
  model
}

///|
/// A rounding that is feasible is offered, and it is whole and satisfies the model.
test "a relaxation rounds into a whole point the model admits" {
  let model = roundable_mip()
  let point = rounded_point(model, [3.3, 0.0], 1.0e-7, -1.0)
  assert_eq(point.length(), 2)
  assert_eq(point[0], 3.0)
  assert_eq(point[1], 0.0)
  assert_eq(point_violation(model, point, 1.0e-7), 0.0)
  // And it is a point of the model, not of the rounding: the row it came from is respected.
  assert_true(point_row_dot(model, 0, point) <= 3.3 + 1.0e-9)
}

///|
/// When no rounding is feasible the heuristic offers nothing. Empty is the answer, not a point that
/// nearly satisfies the model: the caller is a search that would take such a point as an incumbent
/// and report it as the answer if the tree closed against it.
test "a rounding that cannot satisfy the model offers nothing" {
  let model = unroundable_mip()
  for start in [[0.5, 0.0], [0.0, 0.5], [0.25, 0.25]] {
    assert_eq(rounded_point(model, start, 1.0e-7, 1.0).length(), 0)
  }
}

///|
/// A point that a rounding leaves outside a row is refused, and the refusal is the checker's own
/// measurement rather than a tolerance of the rounding's own: `x >= 1` is violated by `(0, 0)` at
/// the full size of the row's scale, which no tolerance can excuse.
test "a rounding that leaves a row violated is not offered" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=4.0, is_int=true)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 1.0)
  // `0.4` rounds down to `0`, which breaks the covering row; rounding up to `1` is the one that
  // works, so the heuristic has to try more than the nearer whole number.
  let point = rounded_point(model, [0.4], 1.0e-7, 1.0)
  assert_eq(point.length(), 1)
  assert_eq(point[0], 1.0)
  assert_eq(point_violation(model, point, 1.0e-7), 0.0)
}

///|
/// The projection step of a pump: the objective is replaced by a pull toward the whole point, and
/// the pull has to point the right way in both senses. A minimisation pays for raising a variable
/// with a negative coefficient and for lowering it with a positive one; a maximisation is the mirror
/// image. Only the integer variables are pulled — the continuous ones are what a pump lets move.
test "the pump's objective pulls the integers toward the whole point" {
  let minimise = @model.Model::new(@model.Sense::Minimize)
  let x = minimise.add_var("x", lb=0.0, ub=10.0, is_int=true)
  let y = minimise.add_var("y", lb=0.0, ub=10.0, is_int=false)
  minimise.set_objective([(x, 3.0), (y, 1.0)])
  minimise.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::GreaterEqual, 5.0)
  // `x` was 1.5 and rounds up to 2: the relaxation is paid to raise it, so the coefficient is
  // negative in a minimisation. `y` is not an integer and gets no term at all.
  let pulled = rounded_objective_model(minimise, [1.5, 3.5], [2.0, 3.5], 1.0)
  let terms = pulled.objective()
  assert_eq(terms.length(), 1)
  assert_eq(terms[0].0, x)
  assert_eq(terms[0].1, -1.0)
  // Rounded down instead: the coefficient flips.
  let down = rounded_objective_model(minimise, [2.5, 2.0], [2.0, 2.0], 1.0)
  let down_terms = down.objective()
  assert_eq(down_terms.length(), 1)
  assert_eq(down_terms[0].1, 1.0)
  // The same pull in a maximisation has the opposite sign, and the rows are untouched.
  let maximise = @model.Model::new(@model.Sense::Maximize)
  let z = maximise.add_var("z", lb=0.0, ub=10.0, is_int=true)
  maximise.set_objective([(z, 1.0)])
  maximise.add_constraint([(z, 1.0)], @model.Rel::LessEqual, 6.0)
  let up = rounded_objective_model(maximise, [3.5], [4.0], -1.0)
  let up_terms = up.objective()
  assert_eq(up_terms.length(), 1)
  assert_eq(up_terms[0].1, 1.0)
  assert_eq(up.num_constraints(), 1)
  assert_true(@core.approx_eq(up.constraint(0).rhs, 6.0, rel=0.0, abs=1.0e-12))
}

///|
/// Every rounding of the relaxation `(2.5, 0)` is infeasible — the continuous variable is left where
/// the relaxation put it, and neither `x = 2` nor `x = 3` satisfies the row with `y = 0`. What makes
/// it feasible is fixing `x` and letting `y` move, which is what a repair solves for.
fn rounding_needs_a_repair_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=4.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=@model.infinite_bound, is_int=false)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::Equal, 2.5)
  model
}

///|
/// Four binaries that have to sum to one: eight assignments, of which the three deterministic
/// roundings reach three — and of the point `(0.5, 0.5, 0.5, 0.5)` all three reach the wrong ones.
fn four_binary_sum_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let a = model.add_var("a", lb=0.0, ub=1.0, is_int=true)
  let b = model.add_var("b", lb=0.0, ub=1.0, is_int=true)
  let c = model.add_var("c", lb=0.0, ub=1.0, is_int=true)
  let d = model.add_var("d", lb=0.0, ub=1.0, is_int=true)
  model.set_objective([(a, 1.0), (b, 1.0), (c, 1.0), (d, 1.0)])
  model.add_constraint(
    [(a, 1.0), (b, 1.0), (c, 1.0), (d, 1.0)],
    @model.Rel::Equal,
    1.0,
  )
  model
}

///|
/// The three deterministic roundings are three points of the rounding space; the sampler draws from
/// the space itself. Of `(0.5, 0.5, 0.5, 0.5)` the nearer whole point and the downward rounding are
/// `(0, 0, 0, 0)` and the upward one is `(1, 1, 1, 1)` — none of them sums to one, so the model refuses
/// all three — while the unit vectors, which the sampler reaches, are exactly the feasible points.
/// That is the mechanism, separated from the search: the space is where the answers are, and three
/// points of it are not a search of it.
test "a sampled rounding reaches points the three deterministic ones do not" {
  let model = four_binary_sum_mip()
  let values : Array[Double] = [0.5, 0.5, 0.5, 0.5]
  assert_eq(rounded_point(model, values, 1.0e-7, 1.0).length(), 0)
  let mut state = 1
  let mut feasible = 0
  for i = 0; i < 32; i = i + 1 {
    let (point, next) = sampled_candidate(model, values, state)
    state = next
    assert_eq(point.length(), 4)
    if point_violation(model, point, 1.0e-7) == 0.0 {
      feasible = feasible + 1
      assert_eq(point[0] + point[1] + point[2] + point[3], 1.0)
    }
  }
  // Not every draw is feasible — that is what makes it a sample — and some of them are.
  assert_true(feasible > 0)
  assert_true(feasible < 32)
}

///|
/// Fixing the integers at a rounding is what turns a point the row refuses into one it accepts: the
/// continuous variables are the ones left undecided, and the model re-solved with the integers
/// pinned finds them. The point that comes out is whole where the model says whole, and the repair
/// is a *solve* of a model the checker can judge, not a second rounding.
test "fixing the integers and re-solving repairs a point the row refuses" {
  let model = rounding_needs_a_repair_mip()
  let values : Array[Double] = [2.5, 0.0]
  // Rounding alone: wherever the integers land, `y` is left at zero and the equality breaks.
  assert_eq(rounded_point(model, values, 1.0e-7, 1.0).length(), 0)
  // Which rounding to fix is not settled by which is nearest: the nearest is `x = 3`, and no
  // continuous completion of it satisfies the row, while the floor one - `x = 2` and `y = 0.5` -
  // does. That is why the search rotates through the three directions rather than retrying one.
  let nearest = rounded_candidate(model, values, 0)
  assert_eq(nearest[0], 3.0)
  let nearest_fixed = fixed_integer_model(model, nearest)
  let nearest_outcome = match
    @simplex.solve_model_with(nearest_fixed, @simplex.SimplexOptions::relaxed()) {
    Ok(value) => value
    Err(reason) => fail("the fixed model was refused: " + reason)
  }
  assert_eq(nearest_outcome.status, @simplex.SimplexStatus::Infeasible)
  let down = rounded_candidate(model, values, -1)
  assert_eq(down[0], 2.0)
  let fixed = fixed_integer_model(model, down)
  assert_eq(fixed.get_var(0).lb, 2.0)
  assert_eq(fixed.get_var(0).ub, 2.0)
  assert_eq(fixed.get_var(1).lb, 0.0)
  let repaired = match
    @simplex.solve_model_with(fixed, @simplex.SimplexOptions::relaxed()) {
    Ok(value) => value
    Err(reason) => fail("the fixed model was refused: " + reason)
  }
  assert_eq(repaired.status, @simplex.SimplexStatus::Optimal)
  assert_eq(point_violation(model, repaired.values, 1.0e-7), 0.0)
  assert_true(@core.approx_eq(repaired.values[1], 0.5, rel=1.0e-9, abs=1.0e-9))
}
