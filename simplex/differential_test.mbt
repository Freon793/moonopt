///|
/// Differential testing against the reference solver.
///
/// This is the main correctness argument for the kernel: on randomly generated
/// LPs that both implementations can express, they have to agree on the status,
/// on the objective value, and the kernel's own solution has to be feasible when
/// checked directly from the row data.
///
/// The generator is a deterministic LCG, so a failing case can be reproduced
/// from its seed alone.

///|
/// Small linear congruential generator: reproducible, and good enough to spread
/// coefficient patterns over the test corpus.
priv struct Lcg {
  mut state : Int
}

///|
/// Creates a generator from a seed.
fn Lcg::new(seed : Int) -> Lcg {
  { state: seed % 100003, }
}

///|
/// Next raw value in `[0, 100003)`.
///
/// The constants are small on purpose: `state` stays below the modulus and the
/// product stays far below any integer overflow, so the sequence is identical on
/// every backend instead of depending on wrap-around behaviour.
fn Lcg::next(self : Lcg) -> Int {
  self.state = (self.state * 31 + 17) % 100003
  self.state
}

///|
/// Next value in `[0, bound)`.
fn Lcg::below(self : Lcg, bound : Int) -> Int {
  if bound <= 1 {
    0
  } else {
    self.next() % bound
  }
}

///|
/// Next value in `[low, high]` as a double.
fn Lcg::between(self : Lcg, low : Int, high : Int) -> Double {
  Double::from_int(low + self.below(high - low + 1))
}

///|
/// Kernel status as text, for failure messages.
fn kernel_status_name(status : @simplex.SimplexStatus) -> String {
  match status {
    @simplex.SimplexStatus::Optimal => "Optimal"
    @simplex.SimplexStatus::Infeasible => "Infeasible"
    @simplex.SimplexStatus::Unbounded => "Unbounded"
    @simplex.SimplexStatus::IterationLimit => "IterationLimit"
    @simplex.SimplexStatus::NumericalFailure => "NumericalFailure"
    @simplex.SimplexStatus::TooLarge => "TooLarge"
  }
}

///|
/// Reference solver status as text, for failure messages.
fn oracle_status_name(status : @oracle.OracleStatus) -> String {
  match status {
    @oracle.OracleStatus::Optimal => "Optimal"
    @oracle.OracleStatus::Infeasible => "Infeasible"
    @oracle.OracleStatus::Unbounded => "Unbounded"
    @oracle.OracleStatus::IterationLimit => "IterationLimit"
  }
}

///|
/// Renders a value vector for failure messages.
fn values_to_string(values : Array[Double]) -> String {
  let parts : Array[String] = []
  for j = 0; j < values.length(); j = j + 1 {
    parts.push(values[j].to_string())
  }
  "[" + parts.join(", ") + "]"
}

///|
/// Renders the rows of an instance for failure messages.
fn rows_to_string(rows : Array[(Array[Double], @model.Rel, Double)]) -> String {
  let parts : Array[String] = []
  for i = 0; i < rows.length(); i = i + 1 {
    let (coefficients, rel, rhs) = rows[i]
    let symbol = match rel {
      @model.Rel::LessEqual => "<="
      @model.Rel::GreaterEqual => ">="
      @model.Rel::Equal => "="
    }
    parts.push(
      values_to_string(coefficients) + " " + symbol + " " + rhs.to_string(),
    )
  }
  "{" + parts.join("; ") + "}"
}

///|
/// One random LP in the class both solvers accept: `x ≥ 0`, rows of any
/// relation, right hand sides that are sometimes negative.
fn random_case(
  seed : Int,
) -> (Int, Array[Double], Array[(Array[Double], @model.Rel, Double)]) {
  let rng = Lcg::new(seed)
  let variables = 2 + rng.below(4)
  let rows_count = 2 + rng.below(4)
  let cost : Array[Double] = []
  for j = 0; j < variables; j = j + 1 {
    cost.push(rng.between(-4, 4))
  }
  let rows : Array[(Array[Double], @model.Rel, Double)] = []
  for i = 0; i < rows_count; i = i + 1 {
    let coefficients : Array[Double] = []
    for j = 0; j < variables; j = j + 1 {
      if rng.below(10) < 6 {
        coefficients.push(rng.between(-3, 3))
      } else {
        coefficients.push(0.0)
      }
    }
    let rel = match rng.below(3) {
      0 => @model.Rel::LessEqual
      1 => @model.Rel::GreaterEqual
      _ => @model.Rel::Equal
    }
    rows.push((coefficients, rel, rng.between(-5, 9)))
  }
  (variables, cost, rows)
}

///|
/// Checks a candidate solution directly against the row data, independently of
/// either solver.
fn is_feasible(
  values : Array[Double],
  rows : Array[(Array[Double], @model.Rel, Double)],
  tolerance : Double,
) -> Bool {
  for j = 0; j < values.length(); j = j + 1 {
    if values[j] < -tolerance {
      return false
    }
  }
  for i = 0; i < rows.length(); i = i + 1 {
    let (coefficients, rel, rhs) = rows[i]
    let acc = @core.CompensatedSum::new()
    for j = 0; j < values.length() && j < coefficients.length(); j = j + 1 {
      acc.add(coefficients[j] * values[j])
    }
    let lhs = acc.value()
    let satisfied = match rel {
      @model.Rel::LessEqual => lhs <= rhs + tolerance
      @model.Rel::GreaterEqual => lhs >= rhs - tolerance
      @model.Rel::Equal => @core.fabs(lhs - rhs) <= tolerance
    }
    if !satisfied {
      return false
    }
  }
  true
}

///|
test "kernel agrees with the reference solver on random LPs" {
  let mut optimal = 0
  let mut infeasible = 0
  let mut unbounded = 0
  for seed = 1; seed <= 200; seed = seed + 1 {
    let (variables, cost, rows) = random_case(seed)
    let kernel = solve_standard(variables, cost, rows)
    // The reference solver maximises, so it receives the negated cost.
    let negated : Array[Double] = []
    for j = 0; j < variables; j = j + 1 {
      negated.push(-cost[j])
    }
    let reference = @oracle.solve_standard(variables, negated, rows)
    match kernel.status {
      Optimal => {
        optimal = optimal + 1
        if reference.status != @oracle.Optimal {
          fail(
            "seed " +
            seed.to_string() +
            ": kernel optimal, reference " +
            oracle_status_name(reference.status),
          )
        }
        let expected = -reference.objective
        if @core.fabs(kernel.objective - expected) >
          1.0e-6 * (1.0 + @core.fabs(expected)) {
          fail(
            "seed " +
            seed.to_string() +
            ": objective " +
            kernel.objective.to_string() +
            " vs reference " +
            expected.to_string(),
          )
        }
        if !is_feasible(kernel.values, rows, 1.0e-6) {
          fail("seed " + seed.to_string() + ": kernel solution is not feasible")
        }
      }
      Infeasible => {
        infeasible = infeasible + 1
        if reference.status != @oracle.Infeasible {
          fail(
            "seed " +
            seed.to_string() +
            ": kernel says infeasible, reference " +
            oracle_status_name(reference.status),
          )
        }
      }
      Unbounded => {
        unbounded = unbounded + 1
        if reference.status != @oracle.Unbounded {
          fail(
            "seed " +
            seed.to_string() +
            ": kernel says unbounded, reference " +
            oracle_status_name(reference.status),
          )
        }
      }
      other =>
        fail(
          "seed " +
          seed.to_string() +
          ": kernel returned " +
          kernel_status_name(other) +
          " (" +
          kernel.message +
          ")",
        )
    }
  }
  assert_true(optimal > 0)
  assert_eq(optimal + infeasible + unbounded, 200)
}

///|
/// The bounded-variable kernel against the reference solver, with the *same* problem
/// written two ways: the kernel gets `xⱼ ≤ uⱼ` as a column bound, the reference gets
/// it as an extra row. Neither formulation is a variant of the other's code, so an
/// agreement here is evidence about the ratio test reading both bounds and about a
/// non-basic variable being allowed to rest at its upper bound.
///
/// Every variable is bounded in this corpus, and that is not cosmetic: the reference
/// treats the "no upper bound" sentinel as a finite number, so it reports an optimal
/// value of `-3e30` on an unbounded instance instead of saying it is unbounded (seed
/// 19 of this very generator is such a case). Bounded instances keep the comparison
/// meaningful; the unbounded verdict has its own tests.
test "kernel agrees with the reference solver on random bounded LPs" {
  let mut optimal = 0
  let mut other = 0
  for seed = 1; seed <= 200; seed = seed + 1 {
    let (variables, cost, rows) = random_case(seed)
    // A deterministic upper bound per variable: tight, loose, and exactly zero (a
    // variable pinned at its lower bound, which no column can move).
    let bounds_lcg = Lcg::new(seed * 31 + 11)
    let uppers : Array[Double] = []
    for j = 0; j < variables; j = j + 1 {
      uppers.push(
        match bounds_lcg.below(4) {
          0 => 1.0
          1 => 6.0
          2 => 0.0
          _ => 3.5
        },
      )
    }
    let model = @model.Model::new(@model.Sense::Minimize)
    let vars : Array[Int] = []
    for j = 0; j < variables; j = j + 1 {
      vars.push(model.add_var("x" + j.to_string(), lb=0.0, ub=uppers[j]))
    }
    let objective : Array[(Int, Double)] = []
    for j = 0; j < variables; j = j + 1 {
      objective.push((vars[j], cost[j]))
    }
    model.set_objective(objective)
    for i = 0; i < rows.length(); i = i + 1 {
      let (coefficients, rel, rhs) = rows[i]
      let terms : Array[(Int, Double)] = []
      for j = 0; j < variables; j = j + 1 {
        if coefficients[j] != 0.0 {
          terms.push((vars[j], coefficients[j]))
        }
      }
      model.add_constraint(terms, rel, rhs)
    }
    let kernel = match solve_model(model) {
      Ok(result) => result
      Err(reason) => fail("kernel refused a continuous model: " + reason)
    }
    // The reference gets the bounds as rows on top of the same constraints.
    let reference_rows : Array[(Array[Double], @model.Rel, Double)] = []
    for i = 0; i < rows.length(); i = i + 1 {
      reference_rows.push(rows[i])
    }
    for j = 0; j < variables; j = j + 1 {
      if @core.is_finite(uppers[j]) {
        let bound_row : Array[Double] = []
        for k = 0; k < variables; k = k + 1 {
          bound_row.push(if k == j { 1.0 } else { 0.0 })
        }
        reference_rows.push((bound_row, @model.Rel::LessEqual, uppers[j]))
      }
    }
    let negated : Array[Double] = []
    for j = 0; j < variables; j = j + 1 {
      negated.push(-cost[j])
    }
    let reference = @oracle.solve_standard(variables, negated, reference_rows)
    match kernel.status {
      Optimal => {
        optimal = optimal + 1
        if reference.status != @oracle.Optimal {
          fail(
            "seed " +
            seed.to_string() +
            ": kernel optimal, reference " +
            oracle_status_name(reference.status),
          )
        }
        let expected = -reference.objective
        if @core.fabs(kernel.objective - expected) >
          1.0e-6 * (1.0 + @core.fabs(expected)) {
          fail(
            "seed " +
            seed.to_string() +
            ": objective " +
            kernel.objective.to_string() +
            " vs reference " +
            expected.to_string(),
          )
        }
        if !is_feasible(kernel.values, reference_rows, 1.0e-6) {
          fail(
            "seed " +
            seed.to_string() +
            ": kernel solution is infeasible: values=" +
            values_to_string(kernel.values) +
            " bounds=" +
            values_to_string(uppers),
          )
        }
      }
      Infeasible | Unbounded => {
        other = other + 1
        if reference.status != @oracle.Infeasible &&
          reference.status != @oracle.Unbounded {
          fail(
            "seed " +
            seed.to_string() +
            ": kernel " +
            kernel_status_name(kernel.status) +
            ", reference " +
            oracle_status_name(reference.status),
          )
        }
      }
      status =>
        fail(
          "seed " +
          seed.to_string() +
          ": kernel returned " +
          kernel_status_name(status) +
          " (" +
          kernel.message +
          ")",
        )
    }
  }
  // The corpus has to actually exercise the bounded path.
  assert_true(optimal > 0)
  assert_eq(optimal + other, 200)
}

///|
test "kernel respects the row data on shifted and rounded instances" {
  // A small family with non-trivial right hand sides, to cover the sign
  // normalisation path with values that are not integers.
  for seed = 1000; seed <= 1040; seed = seed + 1 {
    let (variables, cost, rows) = random_case(seed)
    let scaled : Array[(Array[Double], @model.Rel, Double)] = []
    for i = 0; i < rows.length(); i = i + 1 {
      let (coefficients, rel, rhs) = rows[i]
      let tweaked : Array[Double] = []
      for j = 0; j < coefficients.length(); j = j + 1 {
        tweaked.push(coefficients[j] * 0.5)
      }
      scaled.push((tweaked, rel, rhs * 0.5 + 0.25))
    }
    let kernel = solve_standard(variables, cost, scaled)
    match kernel.status {
      Optimal => {
        if !is_feasible(kernel.values, scaled, 1.0e-6) {
          fail(
            "seed " +
            seed.to_string() +
            ": kernel solution is infeasible: values=" +
            values_to_string(kernel.values) +
            " rows=" +
            rows_to_string(scaled),
          )
        }
        let negated : Array[Double] = []
        for j = 0; j < variables; j = j + 1 {
          negated.push(-cost[j])
        }
        let reference = @oracle.solve_standard(variables, negated, scaled)
        assert_eq(reference.status, @oracle.Optimal)
        let expected = -reference.objective
        assert_true(
          @core.fabs(kernel.objective - expected) <=
          1.0e-6 * (1.0 + @core.fabs(expected)),
        )
      }
      Infeasible | Unbounded => ()
      other =>
        fail(
          "seed " +
          seed.to_string() +
          ": unexpected " +
          kernel_status_name(other),
        )
    }
  }
}
