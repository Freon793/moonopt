///|
test "reference solver: bounded two row problem" {
  // max 3x + 2y  s.t.  x + y <= 4,  x + 3y <= 6,  x, y >= 0  ->  12 at (4, 0)
  let res = solve_standard(2, [3.0, 2.0], [
    ([1.0, 1.0], @model.Rel::LessEqual, 4.0),
    ([1.0, 3.0], @model.Rel::LessEqual, 6.0),
  ])
  assert_eq(res.status, Optimal)
  assert_eq(res.values.length(), 2)
  assert_true(@core.approx_eq(res.values[0], 4.0))
  assert_true(@core.approx_eq(res.values[1], 0.0))
  assert_true(@core.approx_eq(res.objective, 12.0))
}

///|
test "reference solver: equality row" {
  // max x + y  s.t.  x + y = 1,  x, y >= 0  ->  1
  let res = solve_standard(2, [1.0, 1.0], [([1.0, 1.0], @model.Rel::Equal, 1.0)])
  assert_eq(res.status, Optimal)
  assert_true(@core.approx_eq(res.objective, 1.0))
}

///|
test "reference solver: negative right hand side is normalised" {
  // max x  s.t.  -x <= -2  (i.e. x >= 2) and  x <= 5  ->  5
  let res = solve_standard(1, [1.0], [
    ([-1.0], @model.Rel::LessEqual, -2.0),
    ([1.0], @model.Rel::LessEqual, 5.0),
  ])
  assert_eq(res.status, Optimal)
  assert_true(@core.approx_eq(res.values[0], 5.0))
  assert_true(@core.approx_eq(res.objective, 5.0))
}

///|
test "reference solver: infeasible model is detected" {
  // x <= 1  and  x >= 2
  let res = solve_standard(1, [1.0], [
    ([1.0], @model.Rel::LessEqual, 1.0),
    ([1.0], @model.Rel::GreaterEqual, 2.0),
  ])
  assert_eq(res.status, Infeasible)
  assert_eq(res.values.length(), 0)
}

///|
test "reference solver: unbounded model is detected" {
  // max x  s.t.  x >= 1
  let res = solve_standard(1, [1.0], [([1.0], @model.Rel::GreaterEqual, 1.0)])
  assert_eq(res.status, Unbounded)
}

///|
test "reference solver: degenerate problem terminates" {
  // Classic degeneracy: three rows through the same vertex.
  // max x + y  s.t.  x + y <= 1,  x <= 1,  y <= 1  ->  1
  let res = solve_standard(2, [1.0, 1.0], [
    ([1.0, 1.0], @model.Rel::LessEqual, 1.0),
    ([1.0, 0.0], @model.Rel::LessEqual, 1.0),
    ([0.0, 1.0], @model.Rel::LessEqual, 1.0),
  ])
  assert_eq(res.status, Optimal)
  assert_true(@core.approx_eq(res.objective, 1.0))
}

///|
test "reference solver: no constraints, non-improving objective" {
  // max −5x − 3y with x, y >= 0 and no rows: the origin is optimal.
  let res = solve_standard(2, [-5.0, -3.0], [])
  assert_eq(res.status, Optimal)
  assert_true(@core.approx_eq(res.objective, 0.0))
  assert_true(@core.approx_eq(res.values[0], 0.0))
  assert_true(@core.approx_eq(res.values[1], 0.0))
}

///|
test "reference solver: no constraints, improving objective is unbounded" {
  // max 5x with x >= 0 and no rows has no finite optimum.
  let res = solve_standard(1, [5.0], [])
  assert_eq(res.status, Unbounded)
}

///|
test "reference solver: iteration limit is reported, not guessed" {
  let res = solve_standard(
    2,
    [3.0, 2.0],
    [
      ([1.0, 1.0], @model.Rel::LessEqual, 4.0),
      ([1.0, 3.0], @model.Rel::LessEqual, 6.0),
    ],
    max_iterations=0,
  )
  assert_eq(res.status, IterationLimit)
  assert_eq(res.iterations, 0)
}
