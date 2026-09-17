///|
/// Branch and bound, checked against something that is not branch and bound.
///
/// The oracle here is exhaustive enumeration over the integer box: a model small enough
/// to list every integer point has a best value that can be computed by brute force, and
/// the search has to agree with it. That is the same idea as the kernel's differential
/// tests against `oracle/`, one level up. Alongside it are the properties this package
/// promises about itself: every node's relaxation is verified, an unfinished run never
/// claims optimality, and a wrong relaxation is refused before it can become the answer.

///|
/// `max 5x + 4y  s.t.  6x + 4y <= 13`, `x, y` integers in `[0, 2]`.
///
/// The row can carry 13 units and `y` is worth 4 per 4 units against `x`'s 5 per 6, so the
/// relaxation fills `y` to its bound of 2 and gives `x` the 5 units left: `(5/6, 2)` for
/// 12.1667. The integer optimum is 10 at (2, 0), so the search has to branch to find it —
/// and one of the children it explores is infeasible, which the run has to survive.
fn two_variable_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=2.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=2.0, is_int=true)
  model.set_objective([(x, 5.0), (y, 4.0)])
  model.add_constraint([(x, 6.0), (y, 4.0)], @model.Rel::LessEqual, 13.0)
  model
}

///|
/// A relaxation that is feasible, whose integer points are not:
/// `min x + y  s.t.  2x + 2y = 1`, `x, y` integers in `[0, 4]`.
///
/// Every vertex of the relaxation has `x + y = 0.5`, and no integer point satisfies the
/// row, so the tree has to exhaust itself with no incumbent at all.
fn no_integer_point_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=4.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=4.0, is_int=true)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 2.0), (y, 2.0)], @model.Rel::Equal, 1.0)
  model
}

///|
/// A model whose relaxation is unbounded: `max x + y  s.t.  x - y <= 3`, both non
/// negative, `x` integer — and neither variable has an upper bound.
fn unbounded_relaxation_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, is_int=true)
  let y = model.add_var("y", lb=0.0)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, -1.0)], @model.Rel::LessEqual, 3.0)
  model
}

///|
/// The name of a status, so a failure message says which one it got instead of a record.
fn status_name(status : MipStatus) -> String {
  match status {
    MipStatus::Optimal => "optimal"
    MipStatus::Infeasible => "infeasible"
    MipStatus::NodeLimit => "node limit"
    MipStatus::UnboundedRelaxation => "unbounded relaxation"
    MipStatus::Unverified => "unverified"
    MipStatus::Invalid => "invalid"
  }
}

///|
/// The whole number nearest to `value`. The search's own rounding is private to its
/// package, and a test that reused it would be checking the answer with the routine that
/// produced it.
fn nearest_int(value : Double) -> Double {
  let truncated = Double::from_int(value.to_int())
  if value - truncated >= 0.5 {
    truncated + 1.0
  } else if truncated - value >= 0.5 {
    truncated - 1.0
  } else {
    truncated
  }
}

///|
/// The value of the objective at a point, in the model's own sense.
fn objective_at(model : @model.Model, point : Array[Double]) -> Double {
  let mut total = 0.0
  for term in model.objective() {
    let (index, coefficient) = term
    total = total + coefficient * point[index]
  }
  total
}

///|
/// Whether a point satisfies every row. Integer data and small coefficients, so a plain
/// absolute tolerance is enough here; the verifier's scaled tests are the ones the solver
/// itself is judged by.
fn point_feasible(
  model : @model.Model,
  point : Array[Double],
  tolerance : Double,
) -> Bool {
  if point.length() != model.num_vars() {
    return false
  }
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    let mut lhs = 0.0
    for term in constraint.terms {
      let (index, coefficient) = term
      lhs = lhs + coefficient * point[index]
    }
    let violation = match constraint.rel {
      @model.Rel::LessEqual => lhs - constraint.rhs
      @model.Rel::GreaterEqual => constraint.rhs - lhs
      @model.Rel::Equal => @core.fabs(lhs - constraint.rhs)
    }
    if violation > tolerance {
      return false
    }
  }
  true
}

///|
/// The best objective over every integer point of a model whose variables are all
/// integers with small finite bounds, or `None` when no integer point is feasible.
///
/// Deliberately the dumbest possible routine: it constructs the points, tests them one by
/// one, and keeps the best. What it cannot do is agree with the search for the wrong
/// reason.
fn best_by_enumeration(
  model : @model.Model,
  tolerance : Double,
) -> Double? raise {
  let n = model.num_vars()
  let lo : Array[Int] = []
  let hi : Array[Int] = []
  for j = 0; j < n; j = j + 1 {
    let variable = model.get_var(j)
    assert_true(variable.is_int)
    assert_true(variable.ub <= 4.0)
    lo.push(variable.lb.to_int())
    hi.push(variable.ub.to_int())
  }
  let point : Array[Double] = Array::make(n, 0.0)
  let index : Array[Int] = Array::make(n, 0)
  let mut best : Double? = None
  let mut done = false
  while !done {
    for j = 0; j < n; j = j + 1 {
      point[j] = Double::from_int(lo[j] + index[j])
    }
    if point_feasible(model, point, tolerance) {
      let objective = objective_at(model, point)
      let better = match best {
        None => true
        Some(value) =>
          if model.sense() == @model.Sense::Maximize {
            objective > value + tolerance
          } else {
            objective < value - tolerance
          }
      }
      if better {
        best = Some(objective)
      }
    }
    let mut k = 0
    while k < n {
      index[k] = index[k] + 1
      if index[k] <= hi[k] - lo[k] {
        break
      }
      index[k] = 0
      k = k + 1
    }
    if k == n {
      done = true
    }
  }
  best
}

///|
/// Checks the parts of a successful answer that hold without knowing the optimum: the
/// point has the right length, satisfies the rows, sits on whole numbers where the
/// variables are integers, and its objective is the objective of that point.
fn assert_answer_at_point(
  model : @model.Model,
  result : MipResult,
  tolerance : Double,
) -> Unit raise {
  assert_eq(result.values.length(), model.num_vars())
  if !point_feasible(model, result.values, tolerance) {
    fail("the reported point does not satisfy the model")
  }
  for j = 0; j < model.num_vars(); j = j + 1 {
    if model.get_var(j).is_int {
      let rounded = nearest_int(result.values[j])
      if @core.fabs(result.values[j] - rounded) > tolerance {
        fail(
          "variable " +
          j.to_string() +
          " is " +
          result.values[j].to_string() +
          ", which is not whole",
        )
      }
    }
  }
  assert_true(
    @core.approx_eq(
      result.objective,
      objective_at(model, result.values),
      rel=1.0e-9,
      abs=1.0e-9,
    ),
  )
}

///|
/// A relaxation that always claims the same thing, whatever model it is handed. Used to
/// show the verifier stands between a node solver and the answer.
fn claims_optimal_at_origin(_problem : @model.Model) -> NodeSolution {
  {
    status: NodeStatus::Optimal,
    values: [0.0, 0.0],
    objective: 0.0,
    duals: [0.0],
    ray: [],
  }
}

///|
/// A relaxation that claims the model is infeasible, with a Farkas ray of the right shape
/// and the wrong arithmetic.
fn claims_infeasible(problem : @model.Model) -> NodeSolution {
  {
    status: NodeStatus::Infeasible,
    values: [],
    objective: 0.0,
    duals: Array::make(problem.num_constraints(), 1.0),
    ray: [],
  }
}

///|
/// A relaxation that reaches no verdict at all, which is what a node solve does when its
/// budget runs out.
fn never_finishes(_problem : @model.Model) -> NodeSolution {
  {
    status: NodeStatus::Unfinished,
    values: [],
    objective: 0.0,
    duals: [],
    ray: [],
  }
}

///|
/// `max x + y  s.t.  x + y <= 3.3`, `x, y` integers in `[0, 4]`.
///
/// The relaxation's best value is 3.3 along the whole edge `x + y = 3.3`, and the best
/// integer point is 3, one step inside it. That is what makes this the model the primal
/// heuristic is worth measuring on: the walk that fixes the fractional variable reaches
/// `(3, 0)` or `(0, 3)` in a single relaxation, while the tree's first two children are
/// still not whole. (The relaxation's value is deliberately not a half: at `3.5` the two
/// sides of the fractional variable are equally near and the walk would pick by round-off.)
fn one_fractional_step_mip() -> @model.Model {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, ub=4.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=4.0, is_int=true)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 3.3)
  model
}

///|
/// The primal heuristic is what turns a bound into pruning: same model, same budget, and
/// the only difference is whether the walk down to a whole point is allowed.
test "the primal heuristic finds an incumbent the tree has not reached yet" {
  let model = one_fractional_step_mip()
  // Three relaxations: the root, then the walk's step. Without the walk the same three
  // relaxations are the root and two children, neither of which is whole.
  let without = solve_mip(
    model,
    MipOptions::with_max_nodes(3).without_primal_dive(),
  )
  assert_eq(without.status, MipStatus::NodeLimit)
  assert_eq(without.values.length(), 0)
  assert_eq(without.verified, without.nodes)
  let dived = solve_mip(model, MipOptions::with_max_nodes(3))
  assert_eq(dived.status, MipStatus::NodeLimit)
  // The point it found is a real answer to the model, checked without the search's own
  // routines: it satisfies the rows, sits on whole numbers and its objective is its own.
  assert_answer_at_point(model, dived, 1.0e-6)
  assert_true(@core.approx_eq(dived.objective, 3.0, rel=1.0e-9, abs=1.0e-9))
  // The bound is still the relaxation's, so the run still has something to prove — and
  // the gap between the two is now a number the caller can act on instead of `1e300`.
  assert_true(@core.approx_eq(dived.bound, 3.3, rel=1.0e-9, abs=1.0e-9))
  assert_true(@core.approx_eq(dived.gap, 0.3, rel=1.0e-9, abs=1.0e-9))
  // The walk's relaxations are relaxations: solved, counted and verified like any other.
  assert_eq(dived.verified, dived.nodes)
  assert_true(dived.nodes > 1)
}

///|
/// The heuristic offers an incumbent; it never claims optimality. With a budget too small
/// to finish, the run still ends at the limit rather than at an answer.
test "the primal heuristic does not turn a limit into an answer" {
  let model = one_fractional_step_mip()
  let result = solve_mip(model, MipOptions::with_max_nodes(2))
  assert_eq(result.status, MipStatus::NodeLimit)
  assert_true(result.message.length() > 0)
  if result.values.length() > 0 {
    assert_answer_at_point(model, result, 1.0e-6)
  }
}

///|
/// The relaxation is fractional, so the answer only appears after branching.
test "branching finds the integer optimum of a fractional relaxation" {
  let model = two_variable_mip()
  let result = solve_mip(model, MipOptions::default())
  assert_eq(result.status, MipStatus::Optimal)
  assert_true(@core.approx_eq(result.objective, 10.0, rel=1.0e-9, abs=1.0e-9))
  assert_answer_at_point(model, result, 1.0e-6)
  assert_true(result.nodes > 1)
  assert_eq(result.verified, result.nodes)
  assert_true(@core.approx_eq(result.gap, 0.0, rel=0.0, abs=1.0e-12))
}

///|
/// A feasible relaxation with no integer point: proved infeasible, with no incumbent.
test "a model with no integer point is proved infeasible" {
  let model = no_integer_point_mip()
  let result = solve_mip(model, MipOptions::default())
  assert_eq(result.status, MipStatus::Infeasible)
  assert_eq(result.values.length(), 0)
  assert_eq(result.verified, result.nodes)
  assert_true(result.nodes > 1)
}

///|
/// An unbounded relaxation is reported as exactly that: the run does not claim the model
/// is unbounded, because an improving ray carries no integrality of its own.
test "an unbounded relaxation is not reported as an unbounded model" {
  let model = unbounded_relaxation_mip()
  let result = solve_mip(model, MipOptions::default())
  assert_eq(result.status, MipStatus::UnboundedRelaxation)
  assert_eq(result.values.length(), 0)
  assert_eq(result.nodes, 1)
  assert_eq(result.verified, 1)
  assert_true(result.message.length() > 0)
}

///|
/// A node budget stops the run with what it has and no claim: the root relaxation's
/// objective is the bound, and nothing is the incumbent yet.
test "a node budget stops the run without claiming optimality" {
  let model = two_variable_mip()
  let result = solve_mip(model, MipOptions::with_max_nodes(1))
  assert_eq(result.status, MipStatus::NodeLimit)
  assert_eq(result.nodes, 1)
  assert_eq(result.values.length(), 0)
  assert_true(@core.approx_eq(result.bound, 73.0 / 6.0, rel=1.0e-9, abs=1.0e-9))
  assert_true(result.gap > 1.0e299)
  assert_true(result.message.length() > 0)
}

///|
/// A relaxation that reaches no verdict is not a refused certificate. There is no claim to
/// check, and what it leaves behind is work the tree has not finished: the run has to end
/// at a limit and say so, not stop as `Unverified`.
test "a relaxation that reaches no verdict ends the run at a limit" {
  let model = two_variable_mip()
  let options = MipOptions::default().with_node_solver(never_finishes)
  let result = solve_mip(model, options)
  assert_eq(result.status, MipStatus::NodeLimit)
  assert_eq(result.nodes, 1)
  assert_eq(result.verified, 0)
  assert_eq(result.values.length(), 0)
  assert_true(result.message.contains("did not finish"))
}

///|
/// The model's default upper bound is a large finite sentinel rather than an infinity, so
/// a variable that carries it still gets branched on: `max x  s.t.  x <= 5.5` over the
/// integers is 5, and the child `x >= 6` is infeasible.
test "the sentinel upper bound does not stop branching" {
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", lb=0.0, is_int=true)
  model.set_objective([(x, 1.0)])
  model.add_constraint([(x, 1.0)], @model.Rel::LessEqual, 5.5)
  let result = solve_mip(model, MipOptions::default())
  assert_eq(result.status, MipStatus::Optimal)
  assert_true(@core.approx_eq(result.objective, 5.0, rel=1.0e-9, abs=1.0e-9))
  assert_answer_at_point(model, result, 1.0e-6)
}

///|
/// The count of verified relaxations is the count of solved ones; switching verification
/// off changes that count and nothing else about the answer.
test "verification counts every node and changes nothing else" {
  let model = two_variable_mip()
  let checked = solve_mip(model, MipOptions::default())
  let unchecked = solve_mip(model, MipOptions::default().without_verification())
  assert_eq(checked.verified, checked.nodes)
  assert_eq(unchecked.verified, 0)
  assert_eq(unchecked.nodes, checked.nodes)
  assert_eq(unchecked.status, checked.status)
  assert_true(
    @core.approx_eq(
      unchecked.objective,
      checked.objective,
      rel=0.0,
      abs=1.0e-12,
    ),
  )
}

///|
/// A relaxation that claims optimality, is feasible, and is not optimal: the verifier has
/// to refuse it before it can become the incumbent.
///
/// `(0, 0)` satisfies the knapsack row, so the primal side is fine and the refusal has to
/// come from the numbers that make the claim mean something — here all-zero multipliers,
/// which leave `x` with an improving direction.
test "a plausible but wrong relaxation is refused" {
  let model = two_variable_mip()
  let options = MipOptions::default().with_node_solver(claims_optimal_at_origin)
  let result = solve_mip(model, options)
  assert_eq(result.status, MipStatus::Unverified)
  assert_eq(result.nodes, 1)
  assert_eq(result.verified, 0)
  assert_true(result.message.length() > 0)
}

///|
/// A relaxation that claims infeasibility on a model that has a feasible point. The
/// multipliers have the right shape, so the refusal is about the arithmetic of the
/// Farkas ray rather than about a missing array.
test "a wrong infeasibility claim is refused" {
  let model = two_variable_mip()
  let options = MipOptions::default().with_node_solver(claims_infeasible)
  let result = solve_mip(model, options)
  assert_eq(result.status, MipStatus::Unverified)
  assert_true(result.message.length() > 0)
}

///|
/// A model that fails validation is `Invalid`: the bounds contradict each other, which is
/// not the same statement as "no integer point exists".
test "a malformed model is not called infeasible" {
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=2.0, ub=1.0, is_int=true)
  model.set_objective([(x, 1.0)])
  let result = solve_mip(model, MipOptions::default())
  assert_eq(result.status, MipStatus::Invalid)
  assert_eq(result.nodes, 0)
  assert_true(result.message.length() > 0)
}

///|
/// Deterministic generator for the branch and bound corpus.
struct MipLcg {
  mut state : Int
}

///|
fn MipLcg::new(seed : Int) -> MipLcg {
  { state: seed % 100003, }
}

///|
fn MipLcg::next(self : MipLcg) -> Int {
  self.state = (self.state * 31 + 17) % 100003
  self.state
}

///|
fn MipLcg::below(self : MipLcg, bound : Int) -> Int {
  if bound <= 1 {
    0
  } else {
    self.next() % bound
  }
}

///|
/// A small random integer program: two or three integer variables in a tiny box, one to
/// three rows with small coefficients including negative ones, and either sense.
///
/// Small on purpose — the point of the corpus is that enumeration can settle it, not that
/// the search is stressed.
fn random_mip_model(lcg : MipLcg) -> @model.Model {
  let sense = if lcg.below(2) == 0 {
    @model.Sense::Minimize
  } else {
    @model.Sense::Maximize
  }
  let model = @model.Model::new(sense)
  let n = 2 + lcg.below(2)
  let vars : Array[Int] = []
  for j = 0; j < n; j = j + 1 {
    vars.push(
      model.add_var(
        "x" + j.to_string(),
        lb=0.0,
        ub=Double::from_int(1 + lcg.below(4)),
        is_int=true,
      ),
    )
  }
  let terms : Array[(Int, Double)] = []
  for j = 0; j < n; j = j + 1 {
    let coefficient = Double::from_int(lcg.below(9) - 4)
    if coefficient != 0.0 {
      terms.push((vars[j], coefficient))
    }
  }
  model.set_objective(terms)
  let rows = 1 + lcg.below(3)
  let mut built = 0
  while built < rows {
    let row : Array[(Int, Double)] = []
    for j = 0; j < n; j = j + 1 {
      let coefficient = Double::from_int(lcg.below(7) - 3)
      if coefficient != 0.0 {
        row.push((vars[j], coefficient))
      }
    }
    if row.length() == 0 {
      row.push((vars[0], 1.0))
    }
    let rel = match lcg.below(3) {
      0 => @model.Rel::LessEqual
      1 => @model.Rel::GreaterEqual
      _ => @model.Rel::Equal
    }
    let rhs = Double::from_int(lcg.below(11) - 3)
    model.add_constraint(row, rel, rhs)
    built = built + 1
  }
  model
}

///|
/// The differential test: on every model of the corpus the search's answer is the one
/// exhaustive enumeration gives, and every relaxation it branched on was verified.
test "the search agrees with enumeration on a random corpus" {
  let lcg = MipLcg::new(20260918)
  let mut optimal = 0
  let mut infeasible = 0
  let tolerance = 1.0e-7
  for sample = 0; sample < 60; sample = sample + 1 {
    let model = random_mip_model(lcg)
    let expected = best_by_enumeration(model, tolerance)
    let result = solve_mip(model, MipOptions::default())
    assert_eq(result.verified, result.nodes)
    match expected {
      None => {
        infeasible = infeasible + 1
        assert_eq(result.status, MipStatus::Infeasible)
      }
      Some(value) => {
        optimal = optimal + 1
        if result.status != MipStatus::Optimal {
          fail(
            "sample " +
            sample.to_string() +
            ": expected " +
            value.to_string() +
            ", got " +
            status_name(result.status) +
            " (" +
            result.message +
            ")",
          )
        }
        assert_answer_at_point(model, result, 1.0e-6)
        if !@core.approx_eq(result.objective, value, rel=1.0e-7, abs=1.0e-7) {
          fail(
            "sample " +
            sample.to_string() +
            ": enumeration says " +
            value.to_string() +
            ", the search says " +
            result.objective.to_string(),
          )
        }
      }
    }
  }
  // A corpus that only produced one of the two outcomes would pass while testing half of
  // the search, so both have to appear.
  assert_true(optimal > 0)
  assert_true(infeasible > 0)
}
