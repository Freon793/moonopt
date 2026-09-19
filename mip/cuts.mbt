///|
/// Cut generation.
///
/// The search is best-bound: what it can prune with is a bound, and every round before
/// this one moved the *search* rather than the relaxation. Cuts move the relaxation: an
/// inequality every integer point satisfies but the relaxation's own optimum does not
/// takes the bound down (for a minimisation) at the node the inequality is added to, and
/// every node below it inherits the cut.
///
/// That is also why this is the one place in the project where a mistake cannot be
/// caught downstream. An invalid cut removes integer points (possibly the optimum) and
/// the rest of the machinery keeps agreeing: the relaxation that follows is solved
/// correctly, its certificate is checked against the model the cut is part of, and the
/// tree reports `Optimal` for a problem nobody solved. So a cut does not get added here
/// because it was computed; it gets added because `verify_cut` re-derived it from the
/// witness the tableau gave and agreed, and a disagreement stops the run.
///
/// The shape of a round:
///
/// - take the tableau rows of the basis the relaxation ended on (`@simplex.tableau_rows`);
/// - for each row whose basic variable is an integer variable the relaxation left
///   fractional, build the witness (the row as a combination of model rows, and the
///   bound each variable's term is written from) and ask `derive_cut` for the cut;
/// - check it, and refuse to continue if the checker refuses;
/// - keep the cuts the relaxation's own point violates, strongest first, up to
///   `cut_round_cap`, because a cut the point already satisfies can only cost a re-solve.

///|
/// How many cuts one round may add. Every cut costs a re-solve of the node it lands on,
/// so a round is worth its cost only while the cuts it produces still cut the
/// relaxation's own point away.
let cut_round_cap : Int = 10

///|
/// The row a combination of model rows gives: `rⱼ = Σᵢ yᵢ·aᵢⱼ`.
fn combination_coefficients(
  model : @model.Model,
  multipliers : Array[Double],
) -> Array[Double] {
  let r : Array[Double] = Array::make(model.num_vars(), 0.0)
  for i = 0; i < model.num_constraints() && i < multipliers.length(); i = i + 1 {
    let multiplier = multipliers[i]
    if multiplier == 0.0 {
      continue
    }
    for term in model.constraint(i).terms {
      let (index, coefficient) = term
      if index >= 0 && index < r.length() {
        r[index] = r[index] + multiplier * coefficient
      }
    }
  }
  r
}

///|
/// The right hand side that combination gives: `β = Σᵢ yᵢ·bᵢ`.
fn combination_rhs(model : @model.Model, multipliers : Array[Double]) -> Double {
  let constant = @core.CompensatedSum::new()
  for i = 0; i < model.num_constraints() && i < multipliers.length(); i = i + 1 {
    if multipliers[i] != 0.0 {
      constant.add(multipliers[i] * model.constraint(i).rhs)
    }
  }
  constant.value()
}

///|
/// `true` when a lower bound is a real bound rather than the model's infinity sentinel.
fn has_lower_bound(lb : Double) -> Bool {
  lb > -1.0e29
}

///|
/// `true` when an upper bound is a real bound rather than the model's infinity sentinel.
fn has_upper_bound(ub : Double) -> Bool {
  ub < 1.0e29
}

///|
/// Which bound each variable's term in the row is written from.
///
/// What the rounding argument needs is that the variable becomes *non-negative* after the
/// shift, and `x − lb` or `ub − x` is one either way. The choice is made on the point the
/// relaxation is standing on (the bound that variable actually sits at), because that is
/// the shift that keeps the row's constant on the side where the cut bites. It is a
/// choice and not a claim: a bad choice can only weaken a cut, never invalidate one, and
/// a variable with no finite bound is left as-is for the checker to refuse.
fn shift_choice(
  model : @model.Model,
  basic : Int,
  values : Array[Double],
  multipliers : Array[Double],
  tolerance : Double,
) -> Array[Bool] {
  let n = model.num_vars()
  let from_lower : Array[Bool] = Array::make(n, true)
  let r = combination_coefficients(model, multipliers)
  for j = 0; j < n; j = j + 1 {
    if j == basic || @core.fabs(r[j]) <= tolerance {
      continue
    }
    let variable = model.get_var(j)
    let lower_ready = has_lower_bound(variable.lb)
    let upper_ready = has_upper_bound(variable.ub)
    if lower_ready && upper_ready {
      let value = if j < values.length() { values[j] } else { variable.lb }
      from_lower[j] = @core.fabs(value - variable.lb) <=
        @core.fabs(variable.ub - value)
    } else if !lower_ready {
      from_lower[j] = false
    }
  }
  from_lower
}

///|
/// How much a cut cuts off the point the relaxation reached, or a non-positive number
/// when the point already satisfies it.
///
/// For a `≥` cut that is `rhs − a·x`: the amount by which the point is short of the row.
/// Sign matters here in the one way a sign can matter in this file — the value is compared
/// with zero to decide whether a cut is worth a re-solve, and taking it the other way round
/// means every useful cut is thrown away and every useless one is kept.
fn cut_strength(cut : @verify.CutRow, values : Array[Double]) -> Double {
  let acc = @core.CompensatedSum::new()
  for term in cut.terms {
    let (index, coefficient) = term
    if index >= 0 && index < values.length() {
      acc.add(coefficient * values[index])
    }
  }
  let lhs = acc.value()
  match cut.rel {
    @model.Rel::GreaterEqual => cut.rhs - lhs
    @model.Rel::LessEqual => lhs - cut.rhs
    @model.Rel::Equal => 0.0
  }
}

///|
/// One round of cuts: the rows to add to the model, strongest first.
///
/// `Err` carries the checker's own words. It is returned rather than skipped because a
/// refused cut means the row the tableau gave and the row the checker derived are not the
/// same row, a disagreement about the arithmetic the whole method rests on, and carrying
/// on would be carrying on past the one signal that matters.
fn cut_round(
  problem : @model.Model,
  solution : NodeSolution,
  basis : @simplex.SimplexBasis,
  options : MipOptions,
) -> Result[Array[@verify.CutRow], String] {
  let kernel_options = @simplex.SimplexOptions::relaxed().limit_iterations(
    options.max_iterations,
  )
  let rows = match @simplex.tableau_rows(problem, kernel_options, basis) {
    // No rows to round from is not a reason to stop: a basis the kernel cannot factor is
    // a fact about this node, not a disagreement about a cut.
    Err(_) => return Ok([])
    Ok(rows) => rows
  }
  let cuts : Array[@verify.CutRow] = []
  let strengths : Array[Double] = []
  for row in rows {
    if row.basic < 0 || row.basic >= problem.num_vars() {
      continue
    }
    let variable = problem.get_var(row.basic)
    if !variable.is_int || row.basic >= solution.values.length() {
      continue
    }
    let value = solution.values[row.basic]
    if @core.fabs(value - round_of(value)) <= options.tolerance {
      continue
    }
    let certificate : @verify.CutCertificate = {
      basic: row.basic,
      multipliers: row.multipliers,
      rhs: combination_rhs(problem, row.multipliers),
      from_lower: shift_choice(
        problem,
        row.basic,
        solution.values,
        row.multipliers,
        options.tolerance,
      ),
    }
    let cut = match
      @verify.derive_cut(problem, certificate, tolerance=options.tolerance) {
      // A row the rounding has nothing to say about (an integral right hand side, a
      // variable with no bound to be written from) is a row without a cut, not an error.
      Err(_) => continue
      Ok(cut) => cut
    }
    let offered = match options.cut_hook {
      None => cut
      Some(hook) => hook(cut)
    }
    let verdict = @verify.verify_cut(
      problem,
      offered,
      certificate,
      tolerance=options.tolerance,
    )
    if !verdict.accepted {
      return Err(
        "the cut rounded from the row basic in " +
        variable.name +
        " was refused: " +
        verdict.reason,
      )
    }
    let strength = cut_strength(offered, solution.values)
    if strength <= options.tolerance {
      continue
    }
    cuts.push(offered)
    strengths.push(strength)
  }
  // Strongest first, and at most `cut_round_cap` of them: a cut that barely moves the
  // point costs the same re-solve as one that moves it a long way.
  //
  // Measured in round 16, and it changes what this loop means in practice: every candidate
  // of a round has the *same* strength here. A rounding cut is violated by exactly one unit
  // of its own scale at the point it was derived from — the variables the rounding counts
  // are all sitting at the bounds their shifts were written from there — so `markshare1`'s
  // root produced six candidates measuring `1` (the largest of them `1.0000000000000018`),
  // and with the strict comparison below the loop keeps whichever came first in row order.
  // Ranking the candidates by efficacy (`violation²/‖a‖²`) instead was implemented and
  // measured: it took `gt2`'s bound up by 4.3% at the same budget and cost `p0201` a proof
  // it had within a 1000-node budget (586 nodes before, 1325 after), so it was reverted.
  // What the selection needs is a *measurement* of each candidate's own effect — a re-solve
  // per candidate, bounded by this cap — rather than another geometric proxy; the numbers
  // are in `CHANGELOG.md` (M5 round 16) and the plan in `docs/roadmap.md`.
  let selected : Array[@verify.CutRow] = []
  while selected.length() < cut_round_cap && selected.length() < cuts.length() {
    let mut best = -1
    for k = 0; k < cuts.length(); k = k + 1 {
      if strengths[k] <= 0.0 {
        continue
      }
      if best < 0 || strengths[k] > strengths[best] {
        best = k
      }
    }
    if best < 0 {
      break
    }
    selected.push(cuts[best])
    strengths[best] = 0.0
  }
  Ok(selected)
}
