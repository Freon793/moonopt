///|
/// What column dominance must and must not do.
///
/// The reduction is exact only on 0/1 set-covering models, and its three conditions each have
/// a test that fails if the condition is dropped. The third one — the dominator must settle the
/// covered row on its own — is the one a plain cover-containment screen leaves out, and the
/// corpus measured a screen without it turning `markshare1` from `node-limit` into `infeasible`
/// in a single node. That is the test that matters most here.

///|
/// A 0/1 set-covering model: `min Σ cⱼxⱼ` subject to `Σ aᵢⱼxⱼ ≥ bᵢ` with `xⱼ ∈ {0,1}`.
fn covering_model(
  costs : Array[Double],
  rows : Array[(Array[(Int32, Double)], Double)],
) -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let objective : Array[(Int32, Double)] = []
  let mut j = 0
  for cost in costs {
    model.add_var("x" + j.to_string(), lb=0.0, ub=1.0, is_int=true) |> ignore
    objective.push((j, cost))
    j = j + 1
  }
  model.set_objective(objective)
  for row in rows {
    let (terms, rhs) = row
    model.add_constraint(terms, @model.Rel::GreaterEqual, rhs)
  }
  model
}

///|
/// A cheaper column with the same cover removes the other one.
test "a cheaper column on the same cover removes the other" {
  let model = covering_model([1.0, 2.0], [([(0, 1.0), (1, 1.0)], 1.0)])
  let (reduced, removed, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_removed, 1)
  assert_eq(stats.columns_compared, 2)
  assert_eq(reduced.num_vars(), 1)
  assert_eq(removed.length(), 1)
  assert_eq(removed[0], 1)
}

///|
/// The third condition: with a right hand side of two, no single column settles the row, so
/// identical covers must not shadow each other. A screen that only compared covers would remove
/// two of these three columns and turn an optimum of 2 into an infeasible model.
test "a right hand side no single column settles protects every column" {
  let model = covering_model([1.0, 1.0, 1.0], [
    ([(0, 1.0), (1, 1.0), (2, 1.0)], 2.0),
  ])
  let (reduced, removed, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_removed, 0)
  assert_eq(removed.length(), 0)
  assert_eq(reduced.num_vars(), 3)
}

///|
/// A dominator has to cover at least as much of the row as the column it replaces. Here the
/// cheaper column covers half the row it shares with the dearer one, and neither may go.
test "a smaller coefficient on the same cover is not a dominator" {
  let model = covering_model([1.0, 2.0], [([(0, 1.0), (1, 2.0)], 1.0)])
  let (reduced, _, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_removed, 0)
  assert_eq(reduced.num_vars(), 2)
}

///|
/// The mirror of the test above: covering *more* of the same row is enough.
test "a larger coefficient on the same cover removes the other" {
  let model = covering_model([1.0, 1.0], [([(0, 2.0), (1, 1.0)], 1.0)])
  let (reduced, removed, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_removed, 1)
  assert_eq(removed.length(), 1)
  assert_eq(removed[0], 1)
  assert_eq(reduced.num_vars(), 1)
}

///|
/// Cover containment, not cover equality: a column that also covers row 1 shadows one that only
/// covers row 0 when the cost does not stand in the way.
test "a cover that contains another removes it" {
  let model = covering_model([1.0, 1.0], [
    ([(0, 1.0), (1, 1.0)], 1.0),
    ([(0, 1.0)], 1.0),
  ])
  let (reduced, removed, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_removed, 1)
  assert_eq(removed.length(), 1)
  assert_eq(removed[0], 1)
  assert_eq(reduced.num_vars(), 1)
}

///|
/// Identical columns must keep exactly one representative. A rule that lets equal-cost columns
/// dominate each other deletes the whole group, which is how an earlier screen reported 100 %
/// dominance on two instances of the corpus.
test "identical columns keep exactly one representative" {
  let model = covering_model([1.0, 1.0, 1.0], [
    ([(0, 1.0), (1, 1.0), (2, 1.0)], 1.0),
  ])
  let (reduced, removed, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_removed, 2)
  assert_eq(reduced.num_vars(), 1)
  assert_eq(removed.length(), 2)
  assert_eq(removed[0], 1)
  assert_eq(removed[1], 2)
}

///|
/// A dearer column does not shadow a cheaper one.
test "a dearer column does not remove a cheaper one" {
  let model = covering_model([2.0, 1.0], [([(0, 1.0), (1, 1.0)], 1.0)])
  let (reduced, removed, stats) = @presolve.remove_dominated_columns(model)
  // The cheap column is `x1`, so the one that goes is `x0`.
  assert_eq(stats.columns_removed, 1)
  assert_eq(removed.length(), 1)
  assert_eq(removed[0], 0)
  assert_eq(reduced.num_vars(), 1)
}

///|
/// An equality row is outside the class, so nothing is examined at all. The count that says
/// "not looked at" is `columns_compared`, and it has to be zero here rather than "zero removed":
/// the two are different statements and only one of them is honest about this model.
test "an equality model is outside the class" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let a = model.add_var("a", lb=0.0, ub=1.0, is_int=true)
  let b = model.add_var("b", lb=0.0, ub=1.0, is_int=true)
  model.set_objective([(a, 1.0), (b, 2.0)])
  model.add_constraint([(a, 1.0), (b, 1.0)], @model.Rel::Equal, 1.0)
  let (reduced, removed, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_compared, 0)
  assert_eq(stats.columns_removed, 0)
  assert_eq(removed.length(), 0)
  assert_eq(reduced.num_vars(), 2)
}

///|
/// A variable that can take a value above one breaks the replacement argument, so the model is
/// outside the class even though every row is a covering row.
test "an integer variable above one is outside the class" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let a = model.add_var("a", lb=0.0, ub=2.0, is_int=true)
  let b = model.add_var("b", lb=0.0, ub=1.0, is_int=true)
  model.set_objective([(a, 1.0), (b, 2.0)])
  model.add_constraint([(a, 1.0), (b, 1.0)], @model.Rel::GreaterEqual, 1.0)
  let (_, _, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_compared, 0)
  assert_eq(stats.columns_removed, 0)
}

///|
/// A continuous variable is outside the class as well: the walk from `x_B = 1` to `x_B = 0`
/// raises `x_A` to one, and a continuous variable does not need to move in whole steps.
test "a continuous variable is outside the class" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let a = model.add_var("a", lb=0.0, ub=1.0)
  let b = model.add_var("b", lb=0.0, ub=1.0)
  model.set_objective([(a, 1.0), (b, 2.0)])
  model.add_constraint([(a, 1.0), (b, 1.0)], @model.Rel::GreaterEqual, 1.0)
  let (_, _, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_compared, 0)
  assert_eq(stats.columns_removed, 0)
}

///|
/// A column no row mentions has nothing to be dominated on, and a model that is already minimal
/// reports zero removed with a non-zero comparison count rather than an empty screen.
test "a model with nothing to give reports a comparison count" {
  let model = covering_model([1.0, 1.0], [([(0, 1.0)], 1.0), ([(1, 1.0)], 1.0)])
  let (reduced, removed, stats) = @presolve.remove_dominated_columns(model)
  assert_eq(stats.columns_compared, 2)
  assert_eq(stats.columns_removed, 0)
  assert_eq(removed.length(), 0)
  assert_eq(reduced.num_vars(), 2)
}
