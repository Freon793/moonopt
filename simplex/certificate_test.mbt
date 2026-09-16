///|
/// The kernel's own answers, checked by the independent verifier.
///
/// This is what a certificate is for: the kernel says `Optimal`, and a package that
/// shares no code with it reads the model and the numbers the kernel produced and
/// decides whether the claim holds. Every test here fails with the verifier's own
/// measurements rather than with an assumption about what the kernel should have
/// produced.

///|
/// Solves a model, or `None` when the kernel refuses the model itself.
fn try_solve(model : @model.Model) -> @simplex.SimplexResult? {
  match @simplex.solve_model_with(model, @simplex.SimplexOptions::default()) {
    Ok(result) => Some(result)
    Err(_) => None
  }
}

///|
/// Turns a kernel result into the certificate the verifier reads.
fn certificate_of(result : @simplex.SimplexResult) -> @verify.Certificate {
  let claim = match result.status {
    @simplex.SimplexStatus::Optimal => @verify.Claim::Optimal
    @simplex.SimplexStatus::Infeasible => @verify.Claim::Infeasible
    @simplex.SimplexStatus::Unbounded => @verify.Claim::Unbounded
    _ => @verify.Claim::Optimal
  }
  {
    claim,
    values: result.values,
    duals: result.duals,
    ray: result.ray,
    objective: result.objective,
  }
}

///|
/// Verifies a kernel result. Returns the empty string when the verifier accepts, and
/// otherwise its own account of what is wrong, model included so a failure can be
/// reproduced from the test output.
fn certificate_problem(
  model : @model.Model,
  result : @simplex.SimplexResult,
) -> String {
  let verdict = @verify.verify(model, certificate_of(result))
  if verdict.accepted {
    ""
  } else {
    verdict.to_text() + "\nmodel:\n" + describe_model(model)
  }
}

///|
/// Renders a model, so a refusal can be reproduced.
fn describe_model(model : @model.Model) -> String {
  let mut text = if model.sense() == @model.Sense::Maximize {
    "max\n"
  } else {
    "min\n"
  }
  for term in model.objective() {
    let (index, coefficient) = term
    text = text +
      "  c" +
      index.to_string() +
      " = " +
      coefficient.to_string() +
      "\n"
  }
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    text = text + "  row " + i.to_string() + ": "
    for term in constraint.terms {
      let (index, coefficient) = term
      text = text + coefficient.to_string() + "·x" + index.to_string() + " "
    }
    let rel = match constraint.rel {
      @model.Rel::LessEqual => "<="
      @model.Rel::GreaterEqual => ">="
      @model.Rel::Equal => "="
    }
    text = text + rel + " " + constraint.rhs.to_string() + "\n"
  }
  for j = 0; j < model.num_vars(); j = j + 1 {
    let variable = model.get_var(j)
    text = text +
      "  " +
      variable.name +
      " in [" +
      variable.lb.to_string() +
      ", " +
      variable.ub.to_string() +
      "]\n"
  }
  text
}

///|
/// `min 3x + 2y  s.t.  x + y ≥ 4,  x + 3y ≥ 6,  x, y ≥ 0` — optimum 8 at (0, 4).
fn two_variable_lp() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(x, 3.0), (y, 2.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::GreaterEqual, 4.0)
  model.add_constraint([(x, 1.0), (y, 3.0)], @model.Rel::GreaterEqual, 6.0)
  model
}

///|
test "an optimal solve carries a certificate the verifier accepts" {
  let model = two_variable_lp()
  let result = match try_solve(model) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  assert_eq(result.status, @simplex.SimplexStatus::Optimal)
  assert_true(@core.approx_eq(result.objective, 8.0, rel=1.0e-9, abs=1.0e-9))
  assert_eq(result.duals.length(), 2)
  assert_eq(result.ray.length(), 0)
  let problem = certificate_problem(model, result)
  if problem != "" {
    fail(problem)
  }
}

///|
test "an infeasible model carries a farkas ray the verifier accepts" {
  // x ≤ 1 and x ≥ 2 cannot both hold.
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::LessEqual, 1.0)
  model.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 2.0)
  let result = match try_solve(model) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  assert_eq(result.status, @simplex.SimplexStatus::Infeasible)
  let problem = certificate_problem(model, result)
  if problem != "" {
    fail(problem)
  }
}

///|
test "an unbounded model carries a recession direction the verifier accepts" {
  // min −x  s.t.  x ≥ 1,  x ≥ 0.
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0)
  model.set_objective([(x, -1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::GreaterEqual, 1.0)
  let result = match try_solve(model) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  assert_eq(result.status, @simplex.SimplexStatus::Unbounded)
  assert_eq(result.ray.length(), 1)
  let problem = certificate_problem(model, result)
  if problem != "" {
    fail(problem)
  }
}

///|
test "certificates hold up for equality rows, bounds and negated rows" {
  // max x + 2y  s.t.  x + y = 5,  0 ≤ x ≤ 4,  0 ≤ y ≤ 4  ->  9 at (1, 4).
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=4.0)
  let y = model.add_var("y", lb=0.0, ub=4.0)
  model.set_objective([(x, 1.0), (y, 2.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::Equal, 5.0)
  let equality = match try_solve(model) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  assert_eq(equality.status, @simplex.SimplexStatus::Optimal)
  let first = certificate_problem(model, equality)
  if first != "" {
    fail(first)
  }
  // A negative right hand side forces the kernel to negate the row; the certificate's
  // multipliers have to undo that sign or the verifier refuses them.
  let shifted = @model.Model::new(@model.Sense::Minimize)
  let u = shifted.add_var("u", lb=0.0)
  shifted.set_objective([(u, 1.0)])
  shifted.add_constraint([(u, -1.0)], @model.Rel::LessEqual, -2.0)
  shifted.add_constraint([(u, 1.0)], @model.Rel::LessEqual, 9.0)
  let negated = match try_solve(shifted) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  assert_eq(negated.status, @simplex.SimplexStatus::Optimal)
  let second = certificate_problem(shifted, negated)
  if second != "" {
    fail(second)
  }
}

///|
test "a tampered certificate from a real solve is refused" {
  let model = two_variable_lp()
  let result = match try_solve(model) {
    Some(result) => result
    None => fail("kernel refused the model")
  }
  let honest = certificate_of(result)
  assert_true(@verify.verify(model, honest).accepted)
  // One multiplier's sign flipped.
  let flipped : @verify.Certificate = {
    claim: honest.claim,
    values: honest.values,
    duals: [-honest.duals[0], honest.duals[1]],
    ray: honest.ray,
    objective: honest.objective,
  }
  assert_false(@verify.verify(model, flipped).accepted)
  // A different vertex, claimed as optimal.
  let cheaper : @verify.Certificate = {
    claim: honest.claim,
    values: [3.0, 1.0],
    duals: honest.duals,
    ray: honest.ray,
    objective: 11.0,
  }
  assert_false(@verify.verify(model, cheaper).accepted)
  // A value nudged off feasibility by a hair.
  let nudged : @verify.Certificate = {
    claim: honest.claim,
    values: [honest.values[0], honest.values[1] - 1.0e-4],
    duals: honest.duals,
    ray: honest.ray,
    objective: honest.objective,
  }
  assert_false(@verify.verify(model, nudged).accepted)
}

///|
/// The same claim on a corpus: every answer the kernel gives has to come with a proof
/// the verifier accepts, and the corpus has to reach all three claims or the test says
/// so instead of quietly passing on a corpus that only produced optima.
test "every certificate on a random corpus is accepted" {
  let lcg = CertLcg::new(20260917)
  let mut optimal = 0
  let mut infeasible = 0
  let mut unbounded = 0
  let mut skipped = 0
  for sample = 0; sample < 200; sample = sample + 1 {
    let model = random_certificate_model(lcg)
    let result = match try_solve(model) {
      Some(result) => result
      None => {
        skipped = skipped + 1
        continue
      }
    }
    match result.status {
      @simplex.SimplexStatus::Optimal => {
        optimal = optimal + 1
        assert_eq(result.duals.length(), model.num_constraints())
      }
      @simplex.SimplexStatus::Infeasible => infeasible = infeasible + 1
      @simplex.SimplexStatus::Unbounded => unbounded = unbounded + 1
      _ => {
        skipped = skipped + 1
        continue
      }
    }
    let problem = certificate_problem(model, result)
    if problem != "" {
      fail("sample " + sample.to_string() + ": " + problem)
    }
  }
  assert_true(optimal > 0)
  assert_true(infeasible > 0)
  assert_true(unbounded > 0)
  assert_eq(optimal + infeasible + unbounded + skipped, 200)
}

///|
/// Deterministic generator for the certificate corpus.
struct CertLcg {
  mut state : Int
}

///|
fn CertLcg::new(seed : Int) -> CertLcg {
  { state: seed % 100003, }
}

///|
fn CertLcg::next(self : CertLcg) -> Int {
  self.state = (self.state * 31 + 17) % 100003
  self.state
}

///|
fn CertLcg::below(self : CertLcg, bound : Int) -> Int {
  if bound <= 1 {
    0
  } else {
    self.next() % bound
  }
}

///|
fn CertLcg::between(self : CertLcg, low : Int, high : Int) -> Double {
  Double::from_int(low + self.below(high - low + 1))
}

///|
/// A small random model that can be optimal, infeasible or unbounded, with bounded
/// variables, negative right hand sides and all three relations.
fn random_certificate_model(lcg : CertLcg) -> @model.Model {
  let sense = if lcg.below(2) == 0 {
    @model.Sense::Minimize
  } else {
    @model.Sense::Maximize
  }
  let model = @model.Model::new(sense)
  let n = 1 + lcg.below(3)
  let vars : Array[Int] = []
  for j = 0; j < n; j = j + 1 {
    let bounded = lcg.below(4) != 0
    let ub = if bounded { lcg.between(1, 6) } else { @model.infinite_bound }
    vars.push(model.add_var("x" + j.to_string(), lb=0.0, ub~))
  }
  let objective : Array[(Int, Double)] = []
  for j = 0; j < n; j = j + 1 {
    objective.push((vars[j], lcg.between(-4, 4)))
  }
  model.set_objective(objective)
  let rows = 1 + lcg.below(3)
  for i = 0; i < rows; i = i + 1 {
    let terms : Array[(Int, Double)] = []
    for j = 0; j < n; j = j + 1 {
      let coefficient = lcg.between(-3, 3)
      if coefficient != 0.0 {
        terms.push((vars[j], coefficient))
      }
    }
    let rel = match lcg.below(4) {
      0 => @model.Rel::LessEqual
      1 => @model.Rel::GreaterEqual
      _ => @model.Rel::Equal
    }
    model.add_named_constraint(
      terms,
      rel,
      lcg.between(-6, 9),
      "r" + i.to_string(),
    )
  }
  model
}
