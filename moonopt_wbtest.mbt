///|
/// Whitebox tests for the model → kernel adaptation, which is deliberately not
/// part of the public surface.
test "kernel adaptation negates the objective for minimisation" {
  let m = @model.Model::new(@model.Sense::Minimize)
  let x = m.add_var("x")
  m.set_objective([(x, 2.0)])
  m.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 1.0)
  let (problem, reason) = to_kernel(m)
  assert_eq(reason, "")
  match problem {
    None => fail("expected a kernel problem")
    Some(kernel) => {
      assert_eq(kernel.objective_sign, -1.0)
      assert_eq(kernel.objective[0], -2.0)
      assert_eq(kernel.rows.length(), 1)
    }
  }
}

///|
test "kernel adaptation keeps maximisation as is and adds bound rows" {
  let m = @model.Model::new(@model.Sense::Maximize)
  let x = m.add_var("x", ub=7.0)
  m.set_objective([(x, 3.0)])
  let (problem, _) = to_kernel(m)
  match problem {
    None => fail("expected a kernel problem")
    Some(kernel) => {
      assert_eq(kernel.objective_sign, 1.0)
      assert_eq(kernel.objective[0], 3.0)
      assert_eq(kernel.rows.length(), 1)
      let (coeff, rel, rhs) = kernel.rows[0]
      assert_eq(coeff[0], 1.0)
      assert_eq(rel, @model.Rel::LessEqual)
      assert_eq(rhs, 7.0)
    }
  }
}
