///|
/// The gate a cut has to pass, and the evidence that the gate is load-bearing.
///
/// Two kinds of test live here. The first is a case worked out by hand: half of the row
/// `2x₁ + 2x₂ ≤ 5` is the row `x₁ + x₂ = 2.5`, whose rounding is the classical cut
/// `x₁ + x₂ ≤ 2`, so the derivation can be checked against arithmetic done on paper
/// rather than against itself.
///
/// The second is the one that matters for the method: small models whose whole box of
/// integer points is enumerable, where every feasible integer point is compared with the
/// cut. A cut that removes one of them is an invalid cut — the failure mode this file
/// exists to prevent — and the same enumeration shows that a deliberately corrupted cut
/// *does* remove one, so the check is not passing for want of anything to catch.

///|
/// `2x₁ + 2x₂ ≤ 5` over integer `[0, 3]²`, whose relaxation optimum is `(2.5, 0)`.
fn two_by_two_row() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x1 = model.add_var("x1", lb=0.0, ub=3.0, is_int=true)
  let x2 = model.add_var("x2", lb=0.0, ub=3.0, is_int=true)
  model.set_objective([(x1, 1.0), (x2, 1.0)])
  model.add_constraint([(x1, 2.0), (x2, 2.0)], @model.Rel::LessEqual, 5.0)
  model
}

///|
/// The row `x₁ + x₂ = 2.5`: the model row above, halved. A row of the tableau is a
/// combination of the model's rows, and this is the simplest combination there is.
fn half_row_certificate() -> @verify.CutCertificate {
  { basic: 0, multipliers: [0.5], rhs: 2.5, from_lower: [true, true], }
}

///|
/// The coefficient of one variable in a cut, or zero when it does not appear.
fn cut_coefficient(cut : @verify.CutRow, variable : Int) -> Double {
  let mut value = 0.0
  for term in cut.terms {
    let (index, coefficient) = term
    if index == variable {
      value = value + coefficient
    }
  }
  value
}

///|
/// `true` when a point satisfies every row and bound of the model.
fn point_is_feasible(
  model : @model.Model,
  point : Array[Double],
  tolerance : Double,
) -> Bool {
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    let mut lhs = 0.0
    for term in constraint.terms {
      let (index, coefficient) = term
      lhs = lhs + coefficient * point[index]
    }
    let satisfied = match constraint.rel {
      @model.Rel::LessEqual => lhs <= constraint.rhs + tolerance
      @model.Rel::GreaterEqual => lhs >= constraint.rhs - tolerance
      @model.Rel::Equal => @core.fabs(lhs - constraint.rhs) <= tolerance
    }
    if !satisfied {
      return false
    }
  }
  for j = 0; j < model.num_vars() && j < point.length(); j = j + 1 {
    let variable = model.get_var(j)
    if point[j] < variable.lb - tolerance || point[j] > variable.ub + tolerance {
      return false
    }
  }
  true
}

///|
/// `true` when a point satisfies a cut.
fn point_satisfies_cut(
  cut : @verify.CutRow,
  point : Array[Double],
  tolerance : Double,
) -> Bool {
  let mut lhs = 0.0
  for term in cut.terms {
    let (index, coefficient) = term
    if index >= 0 && index < point.length() {
      lhs = lhs + coefficient * point[index]
    }
  }
  match cut.rel {
    @model.Rel::GreaterEqual => lhs >= cut.rhs - tolerance
    @model.Rel::LessEqual => lhs <= cut.rhs + tolerance
    @model.Rel::Equal => @core.fabs(lhs - cut.rhs) <= tolerance
  }
}

///|
/// Every whole point of the box `[0, limit]ⁿ`, in an order a reader can predict.
fn box_points(n : Int, limit : Int) -> Array[Array[Double]] {
  let points : Array[Array[Double]] = []
  let mut total = 1
  for j = 0; j < n; j = j + 1 {
    total = total * (limit + 1)
  }
  for index = 0; index < total; index = index + 1 {
    let mut remainder = index
    let point : Array[Double] = Array::make(n, 0.0)
    for j = 0; j < n; j = j + 1 {
      point[j] = Double::from_int(remainder % (limit + 1))
      remainder = remainder / (limit + 1)
    }
    points.push(point)
  }
  points
}

///|
/// The hand-computed case: the cutoff of the half row is `x₁ + x₂ ≤ 2`, written in the
/// direction the rounding produces (`−2x₁ − 2x₂ ≥ −4`).
///
/// The rounding is what the derivation is *for*, so it is checked here against arithmetic
/// that fits on a line: `x₁ + x₂ = 2.5` with `x₁, x₂` whole forces `x₁ + x₂ ≤ 2`.
test "the half row of 2x1 + 2x2 <= 5 rounds to x1 + x2 <= 2" {
  let model = two_by_two_row()
  let certificate = half_row_certificate()
  let derived = @verify.derive_cut(model, certificate)
  let described = match derived {
    Err(reason) => reason
    Ok(cut) => {
      assert_eq(cut.rel, @model.Rel::GreaterEqual)
      assert_eq(cut.terms.length(), 2)
      assert_true(@core.fabs(cut_coefficient(cut, 0) + 2.0) < 1.0e-9)
      assert_true(@core.fabs(cut_coefficient(cut, 1) + 2.0) < 1.0e-9)
      assert_true(@core.fabs(cut.rhs + 4.0) < 1.0e-9)
      let verdict = @verify.verify_cut(model, cut, certificate)
      assert_true(verdict.accepted)
      // The same inequality as `x₁ + x₂ ≤ 2`, checked the way a reader would read it.
      for point in box_points(2, 3) {
        if point_is_feasible(model, point, 1.0e-9) {
          assert_true(point[0] + point[1] <= 2.0 + 1.0e-9)
        }
      }
      ""
    }
  }
  assert_eq(described, "")
}

///|
/// The false cut: the same witness with the right hand side a unit stronger, which rules
/// out `(2, 0)` — a feasible whole point of the model. The checker has to refuse it, and
/// the point it would have removed is listed here so the reason for the test is visible.
test "a cut a unit stronger than the derivation is refused" {
  let model = two_by_two_row()
  let certificate = half_row_certificate()
  let offered : @verify.CutRow = {
    terms: [(0, -2.0), (1, -2.0)],
    rel: @model.Rel::GreaterEqual,
    rhs: -2.0,
  }
  let verdict = @verify.verify_cut(model, offered, certificate)
  assert_true(!verdict.accepted)
  assert_true(verdict.checks.length() > 0)
  // What the refusal is worth: `(2, 0)` is feasible for the model and fails that row.
  assert_true(point_is_feasible(model, [2.0, 0.0], 1.0e-9))
  assert_true(!point_satisfies_cut(offered, [2.0, 0.0], 1.0e-9))
}

///|
/// A witness whose row does not reproduce the variable it calls basic, a right hand side
/// that is whole, an unbounded variable in the row and a basic variable that is not
/// integer: each one is a condition the rounding argument needs, and each one has to be
/// refused rather than rounded through.
test "a witness missing a condition of the argument is refused" {
  let model = two_by_two_row()
  // Double the combination: the basic variable's coefficient comes out as two.
  let doubled : @verify.CutCertificate = {
    basic: 0,
    multipliers: [1.0],
    rhs: 5.0,
    from_lower: [true, true],
  }
  assert_true(@verify.derive_cut(model, doubled) is Err(_))
  // An integral right hand side has nothing to round: `x₁ ≤ 3` with multipliers one.
  let integral_model = @model.Model::new(@model.Sense::Minimize)
  let x = integral_model.add_var("x", lb=0.0, ub=3.0, is_int=true)
  integral_model.set_objective([(x, 1.0)])
  integral_model.add_constraint([(x, 1.0)], @model.Rel::LessEqual, 3.0)
  let integral : @verify.CutCertificate = {
    basic: 0,
    multipliers: [1.0],
    rhs: 3.0,
    from_lower: [true],
  }
  assert_true(@verify.derive_cut(integral_model, integral) is Err(_))
  // A variable with no bound to be written from: the row has `x₂` in it and `x₂` is free.
  let free_model = @model.Model::new(@model.Sense::Minimize)
  let a = free_model.add_var("a", lb=0.0, ub=3.0, is_int=true)
  let b = free_model.add_var(
    "b",
    lb=-@model.infinite_bound,
    ub=@model.infinite_bound,
  )
  free_model.set_objective([(a, 1.0), (b, 1.0)])
  free_model.add_constraint([(a, 1.0), (b, 1.0)], @model.Rel::LessEqual, 2.5)
  let free : @verify.CutCertificate = {
    basic: 0,
    multipliers: [1.0],
    rhs: 2.5,
    from_lower: [true, true],
  }
  assert_true(@verify.derive_cut(free_model, free) is Err(_))
  // A continuous basic variable: its left hand side is not whole, so nothing rounds.
  let continuous_model = @model.Model::new(@model.Sense::Minimize)
  let c = continuous_model.add_var("c", lb=0.0, ub=3.0)
  let d = continuous_model.add_var("d", lb=0.0, ub=3.0, is_int=true)
  continuous_model.set_objective([(c, 1.0), (d, 1.0)])
  continuous_model.add_constraint(
    [(c, 1.0), (d, 1.0)],
    @model.Rel::LessEqual,
    2.5,
  )
  let continuous : @verify.CutCertificate = {
    basic: 0,
    multipliers: [1.0],
    rhs: 2.5,
    from_lower: [true, true],
  }
  assert_true(@verify.derive_cut(continuous_model, continuous) is Err(_))
  // A multiplier vector that does not have the shape of the model.
  let short : @verify.CutCertificate = {
    basic: 0,
    multipliers: [],
    rhs: 2.5,
    from_lower: [true, true],
  }
  assert_true(@verify.derive_cut(model, short) is Err(_))
}

///|
/// A small random model, and a witness for one of its rows scaled so that one integer
/// variable's coefficient is exactly one.
struct CutLcg {
  mut state : Int
}

///|
fn CutLcg::new(seed : Int) -> CutLcg {
  { state: seed, }
}

///|
fn CutLcg::next(self : CutLcg) -> Int {
  self.state = (self.state * 31 + 17) % 100003
  self.state
}

///|
fn CutLcg::between(self : CutLcg, low : Int, high : Int) -> Int {
  low + self.next() % (high - low + 1)
}

///|
/// A model with two or three integer variables in `[0, 4]` and one to three rows with
/// small whole coefficients, all right hand sides positive so that the rows bite.
fn random_cut_model(lcg : CutLcg) -> @model.Model {
  let n = lcg.between(2, 3)
  let model = @model.Model::new(@model.Sense::Minimize)
  let indices : Array[Int] = []
  for j = 0; j < n; j = j + 1 {
    indices.push(
      model.add_var("x" + j.to_string(), lb=0.0, ub=4.0, is_int=true),
    )
  }
  let rows = lcg.between(1, 3)
  for k = 0; k < rows; k = k + 1 {
    let terms : Array[(Int, Double)] = []
    for j = 0; j < n; j = j + 1 {
      let coefficient = lcg.between(-3, 3)
      if coefficient != 0 {
        terms.push((indices[j], Double::from_int(coefficient)))
      }
    }
    if terms.length() > 0 {
      let rel = match lcg.between(0, 2) {
        0 => @model.Rel::LessEqual
        1 => @model.Rel::GreaterEqual
        _ => @model.Rel::Equal
      }
      model.add_constraint(terms, rel, Double::from_int(lcg.between(0, 6)))
    }
  }
  let objective : Array[(Int, Double)] = []
  for j = 0; j < n; j = j + 1 {
    objective.push((indices[j], 1.0))
  }
  model.set_objective(objective)
  model
}

///|
/// A witness for one row of `model`: the row scaled so that the first variable it uses
/// has coefficient one, which is what a tableau row looks like.
fn random_certificate(
  model : @model.Model,
  lcg : CutLcg,
) -> @verify.CutCertificate? {
  let rows = model.num_constraints()
  if rows == 0 {
    return None
  }
  let row = lcg.between(0, rows - 1)
  let constraint = model.constraint(row)
  if constraint.terms.length() == 0 {
    return None
  }
  let (basic, coefficient) = constraint.terms[0]
  if @core.fabs(coefficient) < 1.0e-9 || !model.get_var(basic).is_int {
    return None
  }
  let multipliers : Array[Double] = Array::make(rows, 0.0)
  multipliers[row] = 1.0 / coefficient
  let from_lower : Array[Bool] = Array::make(model.num_vars(), true)
  Some({ basic, multipliers, rhs: constraint.rhs / coefficient, from_lower, })
}

///|
/// The evidence for the rounding formula: on random small models, every whole point that
/// satisfies the model also satisfies the cut, and the cut is the one the derivation
/// gives.
///
/// The box `[0, 4]ⁿ` contains every point the model's bounds allow, so the enumeration is
/// exhaustive for these instances rather than a sample of them.
test "a rounded cut never removes a feasible whole point" {
  let lcg = CutLcg::new(20260917)
  let mut derived = 0
  let mut dangerous = 0
  for round = 0; round < 300; round = round + 1 {
    let model = random_cut_model(lcg)
    match random_certificate(model, lcg) {
      None => ()
      Some(certificate) =>
        match @verify.derive_cut(model, certificate) {
          Err(_) => ()
          Ok(cut) => {
            derived = derived + 1
            assert_true(@verify.verify_cut(model, cut, certificate).accepted)
            for point in box_points(model.num_vars(), 4) {
              if point_is_feasible(model, point, 1.0e-9) {
                assert_true(point_satisfies_cut(cut, point, 1.0e-7))
              }
            }
            // The same cut made a unit stronger: refused, and — the point of the whole
            // exercise — the refusal is not cosmetic, because the stronger row really does
            // cut away a whole point the model allows.
            let stronger : @verify.CutRow = {
              terms: cut.terms,
              rel: cut.rel,
              rhs: cut.rhs + 1.0,
            }
            assert_true(
              !@verify.verify_cut(model, stronger, certificate).accepted,
            )
            for point in box_points(model.num_vars(), 4) {
              if point_is_feasible(model, point, 1.0e-9) &&
                !point_satisfies_cut(stronger, point, 1.0e-9) {
                dangerous = dangerous + 1
                break
              }
            }
          }
        }
    }
  }
  // A run that derived nothing would pass every assertion above and prove nothing.
  assert_true(derived > 20)
  assert_true(dangerous > 0)
}
