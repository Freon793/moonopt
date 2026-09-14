///|
test "oracle is reachable from another package" {
  let res = @oracle.solve_standard(1, [1.0], [
    ([1.0], @model.Rel::LessEqual, 3.0),
  ])
  assert_eq(res.status, @oracle.Optimal)
  assert_true(@core.approx_eq(res.objective, 3.0))
}
