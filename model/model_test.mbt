///|
test "sense and relation symbols parse as documented" {
  assert_eq(@model.Sense::from_symbol("MAX"), Some(@model.Sense::Maximize))
  assert_eq(@model.Sense::from_symbol("maximize"), None)
  assert_eq(@model.Sense::from_symbol("MIN"), Some(@model.Sense::Minimize))
  assert_eq(@model.Rel::from_symbol("L"), Some(@model.Rel::LessEqual))
  assert_eq(@model.Rel::from_symbol("GE"), Some(@model.Rel::GreaterEqual))
  assert_eq(@model.Rel::from_symbol("="), Some(@model.Rel::Equal))
  assert_eq(@model.Rel::from_symbol("?"), None)
}

///|
test "model layer is usable from another package" {
  let m = @model.Model::new(@model.Sense::Minimize)
  let x = m.add_var("x")
  m.set_objective([(x, -1.0)])
  m.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 2.0)
  assert_true(m.is_valid())
  assert_eq(m.constraint(0).rel, @model.Rel::GreaterEqual)
  assert_eq(m.get_var(0).lb, 0.0)
  assert_eq(m.get_var(0).ub, @model.infinite_bound)
}
