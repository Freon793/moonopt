///|
/// LP format reader and writer behaviour.
///
/// Blackbox on purpose: it exercises the same surface a caller sees.
test "lp reads a small model" {
  let text = "\\ a comment\n" +
    "Maximize\n" +
    " obj: 5 x + 4 y\n" +
    "Subject To\n" +
    " machine: 6 x + 4 y <= 24\n" +
    " labour: x + 2 y <= 6\n" +
    "Bounds\n" +
    " 0 <= x <= 100\n" +
    " y free\n" +
    "Generals\n" +
    " y\n" +
    "End\n"
  let model = match @format.read_lp(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.sense(), @model.Sense::Maximize)
  assert_eq(model.num_vars(), 2)
  assert_eq(model.num_constraints(), 2)
  assert_eq(model.objective()[0], (0, 5.0))
  assert_eq(model.objective()[1], (1, 4.0))
  assert_eq(model.constraint(0).name, "machine")
  assert_eq(model.constraint(0).rel, @model.Rel::LessEqual)
  assert_eq(model.constraint(0).rhs, 24.0)
  assert_eq(model.get_var(0).ub, 100.0)
  assert_eq(model.get_var(1).lb, -@model.infinite_bound)
  assert_eq(model.get_var(1).ub, @model.infinite_bound)
  assert_eq(model.get_var(1).is_int, true)
}

///|
test "lp accepts glued coefficients and operators" {
  let text = "Minimize\n" +
    " obj: 3x - y + 2.5 z\n" +
    "st\n" +
    " c1: x+y<=4\n" +
    " c2: 2x >= 1\n" +
    "End\n"
  let model = match @format.read_lp(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.num_vars(), 3)
  assert_eq(model.objective()[0], (0, 3.0))
  assert_eq(model.objective()[1], (1, -1.0))
  assert_eq(model.objective()[2], (2, 2.5))
  assert_eq(model.constraint(0).rel, @model.Rel::LessEqual)
  assert_eq(model.constraint(0).rhs, 4.0)
  assert_eq(model.constraint(0).terms.length(), 2)
  assert_eq(model.constraint(1).rel, @model.Rel::GreaterEqual)
  assert_eq(model.constraint(1).rhs, 1.0)
}

///|
test "lp bounds section covers every documented spelling" {
  let text = "Minimize\n obj: a + b + c + d + e\nBounds\n" +
    " a >= 2\n" +
    " b <= 3\n" +
    " 0 <= c <= 1\n" +
    " d = 7\n" +
    " -infinity <= e <= +infinity\n" +
    "End\n"
  let model = match @format.read_lp(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.get_var(0).lb, 2.0)
  assert_eq(model.get_var(1).ub, 3.0)
  assert_eq(model.get_var(2).lb, 0.0)
  assert_eq(model.get_var(2).ub, 1.0)
  assert_eq(model.get_var(3).lb, 7.0)
  assert_eq(model.get_var(3).ub, 7.0)
  assert_eq(model.get_var(4).lb, -@model.infinite_bound)
  assert_eq(model.get_var(4).ub, @model.infinite_bound)
}

///|
test "lp binary section gives 0/1 integer variables" {
  let text = "Minimize\n obj: x + 2 y\nSubject To\n c: x + y >= 1\nBinary\n x y\nEnd\n"
  let model = match @format.read_lp(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.get_var(0).is_int, true)
  assert_eq(model.get_var(0).lb, 0.0)
  assert_eq(model.get_var(0).ub, 1.0)
  assert_eq(model.get_var(1).is_int, true)
  assert_eq(model.get_var(1).ub, 1.0)
}

///|
test "lp reports malformed input with a position" {
  let issue = match @format.read_lp("obj: x\nEnd\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.line, 1)
  assert_eq(
    issue.message,
    "expected Minimize or Maximize before any expression",
  )
  let issue = match @format.read_lp("Minimize\nSubject To\n c: x + y\nEnd\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.line, 3)
  assert_eq(issue.message, "a constraint needs one of <=, >= or =")
  let issue = match
    @format.read_lp("Minimize\n obj: x\nSubject To\n c: x <= abc\nEnd\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.line, 4)
  assert_eq(issue.message, "the right hand side must be a number")
  let issue = match @format.read_lp("Minimize\n obj: x\nBounds\n x\nEnd\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(
    issue.message,
    "a bounds line needs a relation, `free`, or an assignment",
  )
}

///|
test "lp round trips through the writer" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=10.0)
  let y = model.add_var(
    "y",
    lb=-@model.infinite_bound,
    ub=@model.infinite_bound,
  )
  let z = model.add_var("z", lb=0.0, ub=1.0, is_int=true)
  let w = model.add_var("w", lb=2.0, ub=@model.infinite_bound, is_int=true)
  model.set_objective([(x, 2.0), (y, 3.0), (z, -1.0)])
  model.add_named_constraint(
    [(x, 1.0), (y, 1.0)],
    @model.Rel::GreaterEqual,
    4.0,
    "demand",
  )
  model.add_named_constraint(
    [(z, 1.0), (w, 1.0)],
    @model.Rel::Equal,
    1.0,
    "pick",
  )
  let text = @format.write_lp(model)
  let parsed = match @format.read_lp(text) {
    Ok(back) => back
    Err(issue) => fail("round trip failed: " + issue.to_text() + "\n" + text)
  }
  assert_eq(parsed.sense(), @model.Sense::Minimize)
  assert_eq(parsed.num_vars(), 4)
  assert_eq(parsed.num_constraints(), 2)
  assert_eq(parsed.get_var(0).ub, 10.0)
  assert_eq(parsed.get_var(1).lb, -@model.infinite_bound)
  assert_eq(parsed.get_var(2).is_int, true)
  assert_eq(parsed.get_var(2).ub, 1.0)
  assert_eq(parsed.get_var(3).is_int, true)
  assert_eq(parsed.get_var(3).lb, 2.0)
  assert_eq(parsed.objective()[0], (0, 2.0))
  assert_eq(parsed.objective()[2], (2, -1.0))
  assert_eq(parsed.constraint(0).name, "demand")
  assert_eq(parsed.constraint(0).rhs, 4.0)
  assert_eq(parsed.constraint(1).rel, @model.Rel::Equal)
}

///|
test "an LP model can be solved" {
  let text = "Maximize\n" +
    " obj: 5 x + 4 y\n" +
    "Subject To\n" +
    " machine: 6 x + 4 y <= 24\n" +
    " labour: x + 2 y <= 6\n" +
    "End\n"
  let model = match @format.read_lp(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  let solution = @moonopt.solve(model)
  assert_eq(solution.status, @moonopt.SolveStatus::Optimal)
  assert_true(@core.approx_eq(solution.objective, 21.0))
}
