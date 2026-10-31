///|
/// What the reduction looks like from the caller's side of `solve_mip`.
///
/// Three things have to hold and none of them is about the search: the point comes back in the
/// caller's own variable space (one slot per variable of the model that was handed in), a
/// dominated column reads zero in that space, and the optimum is the one the unreduced run
/// reports. The third test is the one that would have caught the screen this reduction was
/// measured against: with a right-hand side no single column settles, removing columns turns an
/// optimum of two into an infeasible model.

///|
/// `min x0 + 5·x1` subject to `x0 + x1 ≥ 1`: column 0 covers the row at cost 1, column 1 at
/// cost 5, so column 1 is dominated and every optimum already sets it to zero.
fn dominated_covering() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let a = model.add_var("a", lb=0.0, ub=1.0, is_int=true)
  let b = model.add_var("b", lb=0.0, ub=1.0, is_int=true)
  model.set_objective([(a, 1.0), (b, 5.0)])
  model.add_constraint([(a, 1.0), (b, 1.0)], @model.Rel::GreaterEqual, 1.0)
  model
}

///|
/// The dominated column comes back as zero, in the caller's own indexing, and the optimum does
/// not move.
test "a dominated column comes back as zero and the optimum does not move" {
  let model = dominated_covering()
  let plain = @mip.solve_mip(model, @mip.MipOptions::default())
  let unreduced = @mip.solve_mip(
    model,
    @mip.MipOptions::default().without_column_dominance(),
  )
  assert_eq(plain.status, @mip.MipStatus::Optimal)
  assert_eq(unreduced.status, @mip.MipStatus::Optimal)
  // The point is in the caller's space: one slot per variable of the model it was handed.
  assert_eq(plain.values.length(), 2)
  assert_true(@core.approx_eq(plain.values[0], 1.0))
  assert_true(@core.approx_eq(plain.values[1], 0.0))
  assert_true(@core.approx_eq(plain.objective, 1.0))
  assert_true(@core.approx_eq(plain.objective, unreduced.objective))
  assert_eq(plain.domination.columns_removed, 1)
  assert_eq(unreduced.domination.columns_removed, 0)
  assert_eq(unreduced.domination.columns_compared, 0)
}

///|
/// The third condition, end to end: `x0 + x1 + x2 ≥ 2` with unit costs has no column that
/// settles the row by itself, so nothing may be removed. A screen that compared covers only
/// deletes two of the three columns and this model — whose optimum is 2 — comes back
/// infeasible.
test "a right hand side no single column settles leaves the model alone" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let objective : Array[(Int32, Double)] = []
  let terms : Array[(Int32, Double)] = []
  for j = 0; j < 3; j = j + 1 {
    let column = model.add_var("x" + j.to_string(), lb=0.0, ub=1.0, is_int=true)
    objective.push((column, 1.0))
    terms.push((column, 1.0))
  }
  model.set_objective(objective)
  model.add_constraint(terms, @model.Rel::GreaterEqual, 2.0)
  let result = @mip.solve_mip(model, @mip.MipOptions::default())
  assert_eq(result.domination.columns_removed, 0)
  assert_eq(result.status, @mip.MipStatus::Optimal)
  assert_true(@core.approx_eq(result.objective, 2.0))
  assert_eq(result.values.length(), 3)
}

///|
/// The mapping, on a model where it can go wrong: four columns in two independent pairs, with
/// the second column of each pair dominated. The optimum is `1, 0, 1, 0`, so an index that were
/// shifted by the restore would put a one in a dominated slot and be caught here.
test "the mapping puts the kept values in the right slots" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x0 = model.add_var("x0", lb=0.0, ub=1.0, is_int=true)
  let x1 = model.add_var("x1", lb=0.0, ub=1.0, is_int=true)
  let x2 = model.add_var("x2", lb=0.0, ub=1.0, is_int=true)
  let x3 = model.add_var("x3", lb=0.0, ub=1.0, is_int=true)
  model.set_objective([(x0, 1.0), (x1, 4.0), (x2, 1.0), (x3, 4.0)])
  model.add_constraint([(x0, 1.0), (x1, 1.0)], @model.Rel::GreaterEqual, 1.0)
  model.add_constraint([(x2, 1.0), (x3, 1.0)], @model.Rel::GreaterEqual, 1.0)
  let result = @mip.solve_mip(model, @mip.MipOptions::default())
  assert_eq(result.domination.columns_removed, 2)
  assert_eq(result.values.length(), 4)
  assert_true(@core.approx_eq(result.values[0], 1.0))
  assert_true(@core.approx_eq(result.values[1], 0.0))
  assert_true(@core.approx_eq(result.values[2], 1.0))
  assert_true(@core.approx_eq(result.values[3], 0.0))
  assert_true(@core.approx_eq(result.objective, 2.0))
}

///|
/// A model outside the class is not examined, and the counter says which of the two "nothing
/// happened" cases this was.
test "a model outside the class reports no columns compared" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let a = model.add_var("a", lb=0.0, ub=3.0, is_int=true)
  let b = model.add_var("b", lb=0.0, ub=1.0, is_int=true)
  model.set_objective([(a, 1.0), (b, 1.0)])
  model.add_constraint([(a, 1.0), (b, 1.0)], @model.Rel::Equal, 2.0)
  let result = @mip.solve_mip(model, @mip.MipOptions::default())
  assert_eq(result.domination.columns_compared, 0)
  assert_eq(result.domination.columns_removed, 0)
  assert_eq(result.status, @mip.MipStatus::Optimal)
}

///|
/// The switch is on by default and the builder turns it off, so a measurement of "the search
/// itself" can run the model it wrote.
test "column dominance is on by default and has a switch" {
  assert_true(@mip.MipOptions::default().column_dominance)
  assert_false(
    @mip.MipOptions::default().without_column_dominance().column_dominance,
  )
}
