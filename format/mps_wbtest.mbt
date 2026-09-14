///|
/// Reader and writer behaviour, including the failure paths. Every malformed
/// case asserts the reported position, because "parse failed" without a line
/// number is not actionable on a 4000 line instance.
test "mps reads a small model" {
  let text = "NAME          PRODPLAN\n" +
    "* a comment line\n" +
    "ROWS\n" +
    " N  COST\n" +
    " L  MACHINE\n" +
    " L  LABOUR\n" +
    "COLUMNS\n" +
    "    X  COST  5  MACHINE  6\n" +
    "    X  LABOUR  1\n" +
    "    Y  COST  4  MACHINE  4\n" +
    "    Y  LABOUR  2\n" +
    "RHS\n" +
    "    RHS  MACHINE  24  LABOUR  6\n" +
    "BOUNDS\n" +
    "ENDATA\n"
  let model = match parse_mps(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.num_vars(), 2)
  assert_eq(model.num_constraints(), 2)
  assert_eq(model.sense(), @model.Sense::Minimize)
  assert_eq(model.get_var(0).name, "X")
  assert_eq(model.get_var(1).name, "Y")
  assert_eq(model.get_var(0).lb, 0.0)
  assert_eq(model.get_var(0).ub, @model.infinite_bound)
  assert_eq(model.get_var(0).is_int, false)
  assert_eq(model.objective().length(), 2)
  assert_eq(model.objective()[0], (0, 5.0))
  assert_eq(model.objective()[1], (1, 4.0))
  assert_eq(model.constraint(0).name, "MACHINE")
  assert_eq(model.constraint(0).rel, @model.Rel::LessEqual)
  assert_eq(model.constraint(0).rhs, 24.0)
  assert_eq(model.constraint(0).terms.length(), 2)
  assert_eq(model.constraint(0).terms[0], (0, 6.0))
  assert_eq(model.constraint(1).name, "LABOUR")
  assert_eq(model.constraint(1).rhs, 6.0)
  assert_eq(model.validate().length(), 0)
}

///|
test "mps honours the OBJSENSE extension" {
  let text = "NAME T\nOBJSENSE\n MAX\nROWS\n N OBJ\n L R1\nCOLUMNS\n    X  OBJ  1  R1  1\nRHS\n    RHS  R1  5\nENDATA\n"
  let model = match parse_mps(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.sense(), @model.Sense::Maximize)
  assert_eq(model.objective()[0], (0, 1.0))
}

///|
test "mps integer markers mark the columns inside the block" {
  let text = "NAME T\nROWS\n N OBJ\n L R1\nCOLUMNS\n" +
    "    MARKER                 'MARKER'                 'INTORG'\n" +
    "    I  OBJ  1  R1  1\n" +
    "    MARKER                 'MARKER'                 'INTEND'\n" +
    "    C  OBJ  1  R1  1\n" +
    "RHS\n    RHS  R1  5\nENDATA\n"
  let model = match parse_mps(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.get_var(0).name, "I")
  assert_eq(model.get_var(0).is_int, true)
  assert_eq(model.get_var(1).name, "C")
  assert_eq(model.get_var(1).is_int, false)
}

///|
test "mps applies every bound type it claims to support" {
  let text = "NAME T\nROWS\n N OBJ\n L R1\nCOLUMNS\n" +
    "    A  OBJ  1  R1  1\n" +
    "    B  OBJ  1  R1  1\n" +
    "    C  OBJ  1  R1  1\n" +
    "    D  OBJ  1  R1  1\n" +
    "    E  OBJ  1  R1  1\n" +
    "    F  OBJ  1  R1  1\n" +
    "RHS\n    RHS  R1  5\n" +
    "BOUNDS\n" +
    " LO BND A  2\n" +
    " UP BND B  7\n" +
    " FX BND C  3\n" +
    " FR BND D\n" +
    " MI BND E\n" +
    " BV BND F\n" +
    "ENDATA\n"
  let model = match parse_mps(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.get_var(0).lb, 2.0)
  assert_eq(model.get_var(0).ub, @model.infinite_bound)
  assert_eq(model.get_var(1).ub, 7.0)
  assert_eq(model.get_var(2).lb, 3.0)
  assert_eq(model.get_var(2).ub, 3.0)
  assert_eq(model.get_var(3).lb, -@model.infinite_bound)
  assert_eq(model.get_var(3).ub, @model.infinite_bound)
  assert_eq(model.get_var(4).lb, -@model.infinite_bound)
  assert_eq(model.get_var(5).lb, 0.0)
  assert_eq(model.get_var(5).ub, 1.0)
  assert_eq(model.get_var(5).is_int, true)
}

///|
test "mps ranges expand a row into two inequalities" {
  let text = "NAME T\nROWS\n N OBJ\n G R1\nCOLUMNS\n    X  OBJ  1  R1  1\nRHS\n    RHS  R1  10\nRANGES\n    RNG  R1  3\nENDATA\n"
  let model = match parse_mps(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.num_constraints(), 2)
  assert_eq(model.constraint(0).rel, @model.Rel::GreaterEqual)
  assert_eq(model.constraint(0).rhs, 10.0)
  assert_eq(model.constraint(1).name, "R1.up")
  assert_eq(model.constraint(1).rel, @model.Rel::LessEqual)
  assert_eq(model.constraint(1).rhs, 13.0)
}

///|
test "mps accepts the Fortran style exponent marker" {
  let text = "NAME T\nROWS\n N OBJ\nCOLUMNS\n    X  OBJ  1.5D+02\nENDATA\n"
  let model = match parse_mps(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.objective()[0], (0, 150.0))
}

///|
test "mps reports malformed input with a position" {
  // Data before any section header.
  let issue = match parse_mps(" X OBJ 1\nENDATA\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.line, 1)
  assert_eq(issue.column, 2)
  assert_eq(issue.token, "X")
  // Unknown row type.
  let issue = match parse_mps("NAME T\nROWS\n Z R1\nENDATA\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.line, 3)
  assert_eq(issue.token, "Z")
  assert_eq(issue.message, "unknown row type, expected N, L, G or E")
  // Duplicate row declaration.
  let issue = match parse_mps("NAME T\nROWS\n L R1\n L R1\nENDATA\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.line, 4)
  assert_eq(issue.message, "row is declared twice")
  // Coefficient for a row that ROWS never declared.
  let issue = match
    parse_mps("NAME T\nROWS\n N OBJ\nCOLUMNS\n    X  GHOST  1\nENDATA\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.line, 5)
  assert_eq(issue.token, "GHOST")
  // Not a number.
  let issue = match
    parse_mps("NAME T\nROWS\n N OBJ\nCOLUMNS\n    X  OBJ  abc\nENDATA\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.line, 5)
  assert_eq(issue.token, "abc")
  assert_eq(issue.message, "not a number")
  // Unknown bound type.
  let issue = match
    parse_mps(
      "NAME T\nROWS\n N OBJ\nCOLUMNS\n    X  OBJ  1\nBOUNDS\n ZZ BND X  1\nENDATA\n",
    ) {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.line, 7)
  assert_eq(
    issue.message,
    "unknown bound type, expected one of LO UP FX FR MI PL BV LI UI",
  )
  // Recognised but unsupported.
  let issue = match
    parse_mps(
      "NAME T\nROWS\n N OBJ\nCOLUMNS\n    X  OBJ  1\nBOUNDS\n SC BND X  1\nENDATA\n",
    ) {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.message, "semicontinuous bounds are not supported")
  // Truncated file.
  let issue = match parse_mps("NAME T\nROWS\n N OBJ\n") {
    Ok(_) => fail("expected an error")
    Err(found) => found
  }
  assert_eq(issue.message, "file ends without an ENDATA line")
}

///|
test "mps round trips through the writer" {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=1.0, ub=4.0)
  let y = model.add_var("y", lb=0.0, ub=@model.infinite_bound, is_int=true)
  let z = model.add_var(
    "z",
    lb=-@model.infinite_bound,
    ub=@model.infinite_bound,
  )
  model.set_objective([(x, 3.0), (y, -2.0)])
  model.add_named_constraint(
    [(x, 1.0), (y, 1.0)],
    @model.Rel::LessEqual,
    6.0,
    "cap",
  )
  model.add_named_constraint([(z, 1.0)], @model.Rel::Equal, 0.0, "balance")
  let text = write_mps(model)
  let parsed = match parse_mps(text) {
    Ok(back) => back
    Err(issue) => fail("round trip failed: " + issue.to_text() + "\n" + text)
  }
  assert_eq(parsed.sense(), @model.Sense::Maximize)
  assert_eq(parsed.num_vars(), 3)
  assert_eq(parsed.num_constraints(), 2)
  assert_eq(parsed.get_var(0).name, "x")
  assert_eq(parsed.get_var(0).lb, 1.0)
  assert_eq(parsed.get_var(0).ub, 4.0)
  assert_eq(parsed.get_var(1).is_int, true)
  assert_eq(parsed.get_var(2).lb, -@model.infinite_bound)
  assert_eq(parsed.get_var(2).ub, @model.infinite_bound)
  assert_eq(parsed.objective()[0], (0, 3.0))
  assert_eq(parsed.objective()[1], (1, -2.0))
  assert_eq(parsed.constraint(0).name, "cap")
  assert_eq(parsed.constraint(0).rhs, 6.0)
  assert_eq(parsed.constraint(1).name, "balance")
  assert_eq(parsed.constraint(1).rel, @model.Rel::Equal)
  // The written form is stable: writing the reparsed model gives the same text.
  assert_eq(write_mps(parsed), text)
}

///|
test "mps writer keeps names usable in a file" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let _ = model.add_var("a b")
  model.add_named_constraint([], @model.Rel::LessEqual, 1.0, "row one")
  let text = write_mps(model)
  assert_true(text.contains("a_b"))
  assert_true(text.contains("row_one"))
  assert_eq(
    match parse_mps(text) {
      Ok(_) => true
      Err(_) => false
    },
    true,
  )
}

///|
/// Real instances declare extra `N` rows. MPS calls those *free rows*: they are
/// neither constraints nor the objective and their coefficients are ignored.
/// (Found by running the reader over MIPLIB 2017; `dsbmip` is one such file.)
test "mps ignores coefficients of extra free rows" {
  let text = "NAME T\nROWS\n N OBJ\n N FREE1\n L R1\nCOLUMNS\n" +
    "    X  OBJ  1  FREE1  5\n" +
    "    X  R1  2\n" +
    "RHS\n    RHS  R1  4\nENDATA\n"
  let model = match parse_mps(text) {
    Ok(parsed) => parsed
    Err(issue) => fail("unexpected parse error: " + issue.to_text())
  }
  assert_eq(model.num_constraints(), 1)
  assert_eq(model.objective().length(), 1)
  assert_eq(model.objective()[0], (0, 1.0))
  assert_eq(model.constraint(0).name, "R1")
  assert_eq(model.constraint(0).terms.length(), 1)
  assert_eq(model.constraint(0).terms[0], (0, 2.0))
}

///|
test "token splitting keeps columns" {
  let tokens = split_tokens("  alpha\tbeta   gamma")
  assert_eq(tokens.length(), 3)
  assert_eq(tokens[0], ("alpha", 3))
  assert_eq(tokens[1], ("beta", 9))
  assert_eq(tokens[2], ("gamma", 16))
}
