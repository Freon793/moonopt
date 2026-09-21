///|
/// Cuts in the search: that they are earned, that they never change the answer, and that
/// a cut which has been deliberately broken is refused before it can reach the model the
/// tree is built on.
///
/// The last one is the test that matters. A cut is the only artefact in this project that
/// can make the search report `Optimal` for a problem nobody solved — an invalid cut
/// removes the optimum from every node below it and every other check keeps agreeing,
/// because they all check answers against the model the cut is part of. So a wrong cut is
/// handed to the search through its own hook, and the run has to come back `Unverified`
/// with nothing added.

///|
/// `max x₁ + x₂` subject to `2x₁ + 2x₂ ≤ 5`, whole in `[0, 3]`.
///
/// The relaxation reaches `2.5` at `(2.5, 0)`; the whole answer is `2`. The rounding of
/// the row is exactly `x₁ + x₂ ≤ 2`, which is the missing bound, so one round of cuts
/// leaves a relaxation whose optimum is already whole.
fn cut_friendly_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=3.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=3.0, is_int=true)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 2.0), (y, 2.0)], @model.Rel::LessEqual, 5.0)
  model
}

///|
/// A model whose relaxation is fractional but whose row has no useful rounding, so the
/// round of cuts finds nothing and the search has to branch as it always did.
fn unroundable_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=2.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=2.0, is_int=true)
  model.set_objective([(x, 5.0), (y, 4.0)])
  model.add_constraint([(x, 6.0), (y, 4.0)], @model.Rel::LessEqual, 13.0)
  model
}

///|
/// A model with no integer point at all: `2x + 2y = 1` over whole `x, y`.
fn no_integer_point() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=4.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=4.0, is_int=true)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 2.0), (y, 2.0)], @model.Rel::Equal, 1.0)
  model
}

///|
/// A mixed model, where the cut has to leave the continuous variable alone: the
/// relaxation's optimum is fractional in the whole variable, and `y` is free to move.
fn mixed_cut_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=5.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=5.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 2.0), (y, 2.0)], @model.Rel::LessEqual, 7.0)
  model
}

///|
/// The name of a status, so a failure says which one it got instead of a record.
fn cut_status_name(status : @mip.MipStatus) -> String {
  match status {
    @mip.MipStatus::Optimal => "optimal"
    @mip.MipStatus::Infeasible => "infeasible"
    @mip.MipStatus::NodeLimit => "node-limit"
    @mip.MipStatus::UnboundedRelaxation => "unbounded-relaxation"
    @mip.MipStatus::Unverified => "unverified"
    @mip.MipStatus::Invalid => "invalid"
  }
}

///|
/// The root earns a cut, the cut is verified like everything else, and the answer is the
/// whole optimum — which the search also reaches without cuts, by branching.
test "the root tightens itself with a cut and still proves the whole optimum" {
  let model = cut_friendly_mip()
  let base = @mip.MipOptions::default()
  let with_cuts = @mip.solve_mip(model, base)
  assert_eq(cut_status_name(with_cuts.status), "optimal")
  assert_true(with_cuts.cuts > 0)
  assert_eq(with_cuts.verified, with_cuts.nodes)
  assert_true(@core.fabs(with_cuts.objective - 2.0) < 1.0e-7)
  let without_cuts = @mip.solve_mip(model, base.without_cuts())
  assert_eq(without_cuts.cuts, 0)
  assert_eq(cut_status_name(without_cuts.status), "optimal")
  assert_true(@core.fabs(without_cuts.objective - 2.0) < 1.0e-7)
}

///|
/// The invariant that makes cuts usable: they may change how a run gets to an answer, not
/// what the answer is. Checked against a run with cut generation switched off, on models
/// that have integer points, that have none, and that are mixed.
test "cut generation never changes the answer" {
  let models = [
    cut_friendly_mip(),
    unroundable_mip(),
    no_integer_point(),
    mixed_cut_mip(),
  ]
  for model in models {
    let base = @mip.MipOptions::default()
    let with_cuts = @mip.solve_mip(model, base)
    let without_cuts = @mip.solve_mip(model, base.without_cuts())
    assert_eq(
      cut_status_name(with_cuts.status),
      cut_status_name(without_cuts.status),
    )
    assert_eq(with_cuts.values.length(), without_cuts.values.length())
    if with_cuts.values.length() > 0 {
      assert_true(
        @core.fabs(with_cuts.objective - without_cuts.objective) < 1.0e-6,
      )
    }
    assert_eq(with_cuts.verified, with_cuts.nodes)
  }
}

///|
/// A cut pulled a unit weaker than the derivation is refused, the run stops, and nothing
/// is added: `(2.5, 0)` satisfies the weakened cut, so the search would have gone on to
/// treat it as a bound it had earned.
test "a deliberately weakened cut is refused rather than added" {
  let model = cut_friendly_mip()
  let options = @mip.MipOptions::default().with_cut_hook(fn(cut) {
    { terms: cut.terms, rel: cut.rel, rhs: cut.rhs - 1.0, }
  })
  let result = @mip.solve_mip(model, options)
  assert_eq(cut_status_name(result.status), "unverified")
  assert_eq(result.cuts, 0)
  assert_true(result.message.length() > 0)
  assert_eq(result.values.length(), 0)
}

///|
/// A cut that cuts away a *feasible whole point* is the dangerous one, and it is refused
/// the same way. The point it would have removed is `(2, 0)` of the model above, which is
/// the integer optimum — the outcome this whole file is about.
test "a cut that removes the integer optimum is refused" {
  let model = cut_friendly_mip()
  let options = @mip.MipOptions::default().with_cut_hook(fn(cut) {
    { terms: cut.terms, rel: cut.rel, rhs: cut.rhs + 1.0, }
  })
  let result = @mip.solve_mip(model, options)
  assert_eq(cut_status_name(result.status), "unverified")
  assert_eq(result.cuts, 0)
}

///|
/// With cut generation switched off the hook is never consulted, so the same deliberately
/// wrong hook changes nothing: the wrongness is caught by the check, not by the caller
/// having remembered to turn it on.
test "no cuts means nothing to refuse" {
  let model = cut_friendly_mip()
  let options = @mip.MipOptions::default()
    .without_cuts()
    .with_cut_hook(fn(cut) {
      { terms: cut.terms, rel: cut.rel, rhs: cut.rhs + 1.0, }
    })
  let result = @mip.solve_mip(model, options)
  assert_eq(cut_status_name(result.status), "optimal")
  assert_eq(result.cuts, 0)
  assert_true(@core.fabs(result.objective - 2.0) < 1.0e-7)
}
