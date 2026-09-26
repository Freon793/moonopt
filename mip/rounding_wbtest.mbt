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
