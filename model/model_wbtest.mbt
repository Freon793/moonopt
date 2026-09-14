///|
test "normalize_terms sorts, merges and drops zeros" {
  let terms = normalize_terms([
    (2, 1.0),
    (0, 3.0),
    (2, -1.0),
    (1, 0.0),
    (0, 1.0),
  ])
  assert_eq(terms.length(), 1)
  assert_eq(terms[0], (0, 4.0))
}

///|
test "model builder records variables and constraints" {
  let m = Model::new(Maximize)
  let x = m.add_var("x")
  let y = m.add_var("y", lb=0.0, ub=10.0, is_int=true)
  assert_eq(x, 0)
  assert_eq(y, 1)
  assert_eq(m.num_vars(), 2)
  assert_eq(m.sense(), Maximize)
  m.set_objective([(x, 3.0), (y, 2.0)])
  m.add_constraint([(x, 1.0), (y, 1.0)], LessEqual, 4.0)
  m.add_named_constraint([(x, 1.0), (y, 3.0)], LessEqual, 6.0, "hours")
  assert_eq(m.num_constraints(), 2)
  assert_eq(m.objective().length(), 2)
  assert_eq(m.constraint(1).name, "hours")
  assert_eq(m.constraint(1).rel, LessEqual)
  assert_eq(m.get_var(1).ub, 10.0)
  assert_eq(m.get_var(1).is_int, true)
  assert_eq(m.validate().length(), 0)
  assert_true(m.is_valid())
}

///|
test "validate reports structural problems" {
  let m = Model::new(Minimize)
  let _ = m.add_var("x", lb=5.0, ub=1.0)
  let _ = m.add_var("x")
  m.add_constraint([], LessEqual, 1.0)
  m.set_objective([(7, 1.0)])
  let issues = m.validate()
  assert_eq(m.is_valid(), false)
  assert_eq(issues.length(), 4)
}

///|
test "sense can be switched after construction" {
  let m = Model::new(Maximize)
  m.set_sense(Minimize)
  assert_eq(m.sense(), Minimize)
}
