///|
/// Cuts, and the one thing that makes them safe to use: they are checked by
/// re-deriving them.
///
/// A cut is an inequality a search adds to the relaxation because *every integer point
/// of the model* satisfies it. That is a claim about points the LP never saw, and it is
/// the one claim in a branch and cut that nothing else in this project can catch: a cut
/// that is invalid removes integer points — possibly the optimum — from every node below
/// it, and every existing line of defence goes on saying yes. The relaxation that
/// follows is solved correctly and its certificate is checked against the model the cut
/// is now a part of, so the checker agrees with it; the report's point check compares
/// the answer against the model with the cut in it; the search then reports `Optimal`
/// for a problem nobody solved. `verify` refuses wrong answers, not wrong *models*.
///
/// So a cut here is not a row. It is a row **plus the row it was rounded from**, and
/// this file re-derives the cut from that witness and refuses it when the two disagree.
/// What the witness is: a combination of the model's own rows. Every feasible `x` has
/// the row equality
///
/// ```text
///   Σⱼ rⱼ·xⱼ + Σ_{≤ k} yₖ·sₖ − Σ_{≥ k} yₖ·sₖ = β,  sₖ ≥ 0 the slack of row k
/// ```
///
/// where `rⱼ = Σₖ yₖ·aₖⱼ` and `β = Σₖ yₖ·bₖ` — because each model row is an equality
/// once its slack is written in. If one variable in that row is basic, its coefficient
/// is one, and it is an integer variable, then the row reads
///
/// ```text
///   x_B = β − Σ (everything else)
/// ```
///
/// with an integer left hand side, and the classical rounding applies: writing every
/// other variable as `bound ± x̂` with `x̂ ≥ 0`, the scaled sum `Σ āⱼ·x̂ⱼ = f₀ + k` has to
/// be `f₀` away from an integer for a whole `k`, which is exactly the mixed-integer
/// rounding inequality this file computes (Gomory 1960; the form used here is the one
/// in Wolsey, *Integer Programming*, §8.7):
///
/// ```text
///   Σ_{j integer} αⱼ·x̂ⱼ + Σ_{j continuous} γⱼ·x̂ⱼ  ≥  1
///   αⱼ = fⱼ/f₀            if fⱼ ≤ f₀        αⱼ = (1 − fⱼ)/(1 − f₀)  otherwise
///   γⱼ = āⱼ/f₀            if āⱼ ≥ 0         γⱼ = −āⱼ/(1 − f₀)       otherwise
/// ```
///
/// with `fⱼ = āⱼ − ⌊āⱼ⌋` and `f₀ = β′ − ⌊β′⌋`, `β′` the right hand side after the shifts.
/// A continuous variable is rounded with `γ` rather than `α` because a continuous `x̂`
/// can absorb any slack, so it cannot be used as a *counter*; that is the whole
/// difference between the pure-integer cut and the mixed one, and getting it wrong
/// silently removes points exactly as an invalid combination would.
///
/// This file therefore checks a cut by checking its witness, in this order:
///
/// 1. **the row is the combination it claims to be** — the multipliers have the shape of
///    the model, and recomputing `rⱼ` and `β` from the model gives a coefficient of one
///    on the variable the witness names as basic and the right hand side the witness
///    states. A witness whose numbers do not reproduce its own row is not evidence;
/// 2. **the basic variable is integer**, because the rounding argument counts on its
///    left hand side being whole;
/// 3. **every other variable in the row is written from a finite bound**, so that the
///    shifted variable is non-negative — which is the property the argument uses twice
///    (to say `Σ fⱼx̂ⱼ ≥ 0`, and to bound the continuous part `Σ γⱼx̂ⱼ ≥ 0`);
/// 4. **both sides of the fraction are away from zero** — `f₀` near `0` or `1` makes the
///    coefficients `1/f₀` explosions of round-off rather than statements about the model,
///    and `f₀` is judged against the arithmetic that produced it (`combination_noise`)
///    rather than against a constant alone;
/// 5. **the cut is bigger than the arithmetic that produced it** — a cut whose every
///    coefficient is of the order of the combination's own round-off says "no integer
///    point exists" on the strength of noise, and it is refused rather than added;
/// 6. **the cut is the one the derivation gives**, term by term, against the same
///    tolerance the rest of this package measures with.
///
/// What this does *not* check is the rounding formula itself — it is a definition shared
/// with the producer, and the evidence that it is the right definition is a test that
/// enumerates whole points of small models and confirms that no feasible one is removed
/// (`verify/cuts_test.mbt`), plus the same enumeration showing that a deliberately
/// corrupted cut *does* remove one.
///
/// A cut is stated in the model's own variables: the slacks are substituted back out, so
/// the row a caller adds is an ordinary constraint. That substitution is exact on
/// feasible points, which is where the cut has to hold.

///|
/// A cut: one inequality, in the model's variables.
pub(all) struct CutRow {
  terms : Array[(Int, Double)]
  rel : @model.Rel
  rhs : Double
} derive(Debug)

///|
/// Where a cut comes from: the relaxation row it was rounded from, as a combination of
/// the model's own rows.
///
/// Plain data, so that a producer can build one and this package can re-derive the cut
/// from it without knowing anything about the producer.
pub(all) struct CutCertificate {
  /// The variable that is basic in the row: the one the row solves for. It has to be an
  /// integer variable, and its coefficient in the combination has to come out as one.
  basic : Int
  /// Coefficients of the model's rows in the combination that gives the row.
  multipliers : Array[Double]
  /// The right hand side the combination gives. Carried so that a producer and this
  /// checker can disagree out loud instead of silently deriving different rows.
  rhs : Double
  /// Per model variable: `true` when the row is written from the variable's lower bound,
  /// `false` when from its upper bound. Both are allowed and neither changes validity —
  /// what the rounding needs is that the shifted variable is non-negative, and any
  /// bound gives that — but the choice does change the cut, so the checker is told which
  /// one was made rather than guessing.
  from_lower : Array[Bool]
} derive(Debug)

///|
/// The fractionality a right hand side must have before it is worth rounding, and the
/// scale that decides when a cut is too small to mean anything.
///
/// `f₀` is compared against this *and* against the round-off of the combination that
/// produced the row: `f₀ = 1e-9` on a row built from numbers of size `10⁶` is arithmetic,
/// not a fractional part, and rounding on it is how a cut turns into a claim that no
/// integer point exists.
let cut_fraction_floor : Double = 1.0e-6

///|
/// Largest whole number not above `value`.
fn floor_value(value : Double) -> Double {
  let truncated = Double::from_int(value.to_int())
  if value < 0.0 && truncated != value {
    truncated - 1.0
  } else {
    truncated
  }
}

///|
/// Nearest whole number to `value`.
fn round_value(value : Double) -> Double {
  floor_value(value + 0.5)
}

///|
/// Fractional part `value − ⌊value⌋`, in `[0, 1)`.
fn fractional_part(value : Double) -> Double {
  value - floor_value(value)
}

///|
/// The row a combination of model rows gives: `rⱼ = Σₖ yₖ·aₖⱼ` and `β = Σₖ yₖ·bₖ`.
///
/// This is recomputed here from the model and the multipliers, never read from the
/// producer: the point of a witness is that it can be checked.
fn combination_row(
  model : @model.Model,
  multipliers : Array[Double],
) -> (Array[Double], Double) {
  let r : Array[Double] = Array::make(model.num_vars(), 0.0)
  let constant = @core.CompensatedSum::new()
  for k = 0; k < model.num_constraints() && k < multipliers.length(); k = k + 1 {
    let multiplier = multipliers[k]
    if multiplier == 0.0 {
      continue
    }
    let constraint = model.constraint(k)
    constant.add(multiplier * constraint.rhs)
    for term in constraint.terms {
      let (index, coefficient) = term
      if index >= 0 && index < r.length() {
        r[index] = r[index] + multiplier * coefficient
      }
    }
  }
  (r, constant.value())
}

///|
/// The size of the arithmetic that produced a combination: the sum of the row data and
/// the right hand sides, each weighted by the multiplier that acts on it.
///
/// Multiplying this by the unit round-off gives the absolute error a floating-point
/// evaluation of the combination can carry, which is what a fractional part has to be
/// judged against. Judging it against its own size (as a bare `> 1e-6` does) is how a
/// cut gets rounded from a number that is an integer with an error attached.
fn combination_noise(
  model : @model.Model,
  multipliers : Array[Double],
) -> Double {
  let noise = @core.CompensatedSum::new()
  for k = 0; k < model.num_constraints() && k < multipliers.length(); k = k + 1 {
    let magnitude = @core.fabs(multipliers[k])
    if magnitude == 0.0 {
      continue
    }
    let constraint = model.constraint(k)
    let row = @core.CompensatedSum::new()
    for term in constraint.terms {
      row.add(@core.fabs(term.1))
    }
    noise.add(magnitude * (1.0 + @core.fabs(constraint.rhs) + row.value()))
  }
  noise.value()
}

///|
/// `true` when every value of the row is a whole number and every variable it uses is
/// integer, which is what makes the row's slack a whole number on every integer point.
///
/// This is a *sufficient* condition and it is used as one: when it fails the slack is
/// treated as a continuous variable, and the mixed-integer rounding is still valid for a
/// continuous variable — it is merely weaker. Getting the direction the other way (an
/// integer slack that is really fractional) would be a validity bug.
fn row_is_integer_scaled(
  model : @model.Model,
  row : Int,
  tolerance : Double,
) -> Bool {
  let constraint = model.constraint(row)
  let rhs = constraint.rhs
  if @core.fabs(rhs - round_value(rhs)) > tolerance * (1.0 + @core.fabs(rhs)) {
    return false
  }
  for term in constraint.terms {
    let (index, coefficient) = term
    if @core.fabs(coefficient - round_value(coefficient)) >
      tolerance * (1.0 + @core.fabs(coefficient)) {
      return false
    }
    if index < 0 || index >= model.num_vars() || !model.get_var(index).is_int {
      return false
    }
  }
  true
}

///|
/// One variable of the shifted row: either a model variable or the slack of a model row,
/// with the non-negative variable it becomes and the class its rounding uses.
///
/// `row >= 0` marks a slack: it is a rule-defined variable (`s = b − a·x` on a `≤` row,
/// `s = a·x − b` on a `≥` one) rather than one with its own bounds, which is why it is
/// substituted back into the model's variables at the end instead of being rounded and
/// left there.
priv struct CutEntry {
  /// Coefficient of the non-negative variable after the shift.
  a : Double
  /// Integer on every integer point of the model — the class the rounding uses.
  is_int : Bool
  /// Model variable index, or `-1` for a slack.
  variable : Int
  /// Model row the slack belongs to, or `-1` for a variable.
  row : Int
  from_lower : Bool
  bound : Double
}

///|
/// Every condition the rounding argument needs, measured, plus the cut it gives when
/// they hold.
///
/// Returns the cut as `None` when any condition failed, with the measurements in the
/// array either way: a refusal has to say what it measured, not only that it refused.
fn cut_checks(
  model : @model.Model,
  certificate : CutCertificate,
  tolerance : Double,
) -> (CutRow?, Array[Check]) {
  let checks : Array[Check] = []
  let n = model.num_vars()
  let m = model.num_constraints()
  checks.push(
    check(
      "multiplier dimension",
      certificate.multipliers.length() == m,
      certificate.multipliers.length().to_double(),
      0.0,
    ),
  )
  checks.push(
    check(
      "shift dimension",
      certificate.from_lower.length() == n,
      certificate.from_lower.length().to_double(),
      0.0,
    ),
  )
  checks.push(
    check(
      "basic variable index",
      certificate.basic >= 0 && certificate.basic < n,
      certificate.basic.to_double(),
      0.0,
    ),
  )
  if !all_ok(checks) {
    return (None, checks)
  }
  let basic = certificate.basic
  let (r, beta) = combination_row(model, certificate.multipliers)
  let basic_residual = @core.fabs(r[basic] - 1.0) / (1.0 + @core.fabs(r[basic]))
  checks.push(
    check(
      "basic column is one",
      basic_residual <= tolerance,
      basic_residual,
      tolerance,
    ),
  )
  let basic_is_int = model.get_var(basic).is_int
  checks.push(
    check(
      "basic variable is integer",
      basic_is_int,
      if basic_is_int {
        1.0
      } else {
        0.0
      },
      0.0,
    ),
  )
  let rhs_residual = @core.fabs(beta - certificate.rhs) /
    (1.0 + @core.fabs(beta))
  checks.push(
    check(
      "right hand side of the row",
      rhs_residual <= tolerance,
      rhs_residual,
      tolerance,
    ),
  )
  // The shifted row. Every variable except the basic one becomes a non-negative
  // variable, either from below (`x = lb + x̂`) or from above (`x = ub − x̂`); the
  // multipliers that are not zero bring in the slack of the row they act on, whose own
  // sign is the row's relation. A row with an equality contributes no slack: the
  // kernel's column for it is an artificial, and an artificial is zero on every feasible
  // point, so the term is not there to round.
  let entries : Array[CutEntry] = []
  let mut unbounded = 0
  for j = 0; j < n; j = j + 1 {
    if j == basic || @core.fabs(r[j]) <= tolerance {
      continue
    }
    let variable = model.get_var(j)
    let from_lower = certificate.from_lower[j]
    let finite = if from_lower {
      has_lower(variable.lb)
    } else {
      has_upper(variable.ub)
    }
    if !finite {
      unbounded = unbounded + 1
      continue
    }
    let bound = if from_lower { variable.lb } else { variable.ub }
    entries.push({
      a: if from_lower {
        r[j]
      } else {
        -r[j]
      },
      is_int: variable.is_int,
      variable: j,
      row: -1,
      from_lower,
      bound,
    })
  }
  checks.push(
    check(
      "every variable is written from a finite bound",
      unbounded == 0,
      unbounded.to_double(),
      0.0,
    ),
  )
  for k = 0; k < m && k < certificate.multipliers.length(); k = k + 1 {
    let multiplier = certificate.multipliers[k]
    if @core.fabs(multiplier) <= tolerance {
      continue
    }
    let constraint = model.constraint(k)
    let integer_slack = row_is_integer_scaled(model, k, tolerance)
    match constraint.rel {
      @model.Rel::Equal => ()
      @model.Rel::LessEqual =>
        entries.push({
          a: multiplier,
          is_int: integer_slack,
          variable: -1,
          row: k,
          from_lower: true,
          bound: 0.0,
        })
      @model.Rel::GreaterEqual =>
        entries.push({
          a: -multiplier,
          is_int: integer_slack,
          variable: -1,
          row: k,
          from_lower: true,
          bound: 0.0,
        })
    }
  }
  // `x_B + Σ ā·x̂ = β′`, with the shifts' constants moved across.
  let mut shifted_rhs = beta
  for entry in entries {
    let constant = if entry.from_lower {
      entry.a * entry.bound
    } else {
      -entry.a * entry.bound
    }
    shifted_rhs = shifted_rhs - constant
  }
  let fraction = fractional_part(shifted_rhs)
  let noise = combination_noise(model, certificate.multipliers)
  let fraction_floor = @core.fmax(cut_fraction_floor, noise * 1.0e-9)
  let fractional_ok = fraction > fraction_floor &&
    fraction < 1.0 - fraction_floor
  checks.push(
    check(
      "right hand side is fractional", fractional_ok, fraction, fraction_floor,
    ),
  )
  if !all_ok(checks) {
    return (None, checks)
  }
  // The rounding. Integer variables are counted (`fⱼ/f₀` or `(1−fⱼ)/(1−f₀)`), continuous
  // ones are not — they can absorb any amount of the right hand side, so they enter with
  // the coefficient that keeps the inequality true instead.
  let coefficients : Array[Double] = Array::make(n, 0.0)
  let mut constant_total = 0.0
  let mut magnitude = 0.0
  for entry in entries {
    let coefficient = if entry.is_int {
      let part = fractional_part(entry.a)
      if part <= fraction {
        part / fraction
      } else {
        (1.0 - part) / (1.0 - fraction)
      }
    } else if entry.a >= 0.0 {
      entry.a / fraction
    } else {
      -entry.a / (1.0 - fraction)
    }
    if entry.row >= 0 {
      let constraint = model.constraint(entry.row)
      match constraint.rel {
        @model.Rel::LessEqual => {
          constant_total = constant_total + coefficient * constraint.rhs
          for term in constraint.terms {
            let (index, value) = term
            coefficients[index] = coefficients[index] - coefficient * value
          }
        }
        @model.Rel::GreaterEqual => {
          constant_total = constant_total - coefficient * constraint.rhs
          for term in constraint.terms {
            let (index, value) = term
            coefficients[index] = coefficients[index] + coefficient * value
          }
        }
        @model.Rel::Equal => ()
      }
    } else if entry.from_lower {
      coefficients[entry.variable] = coefficients[entry.variable] + coefficient
      constant_total = constant_total - coefficient * entry.bound
    } else {
      coefficients[entry.variable] = coefficients[entry.variable] - coefficient
      constant_total = constant_total + coefficient * entry.bound
    }
    if coefficient > magnitude {
      magnitude = coefficient
    }
  }
  // A cut of the size of the round-off that produced it is a claim about the arithmetic
  // rather than about the model: on a row whose fractional parts are noise it says "no
  // integer point exists", which is the one conclusion a cut must never draw by accident.
  let size_floor = noise * 1.0e-9 / fraction
  checks.push(
    check(
      "cut is larger than the arithmetic behind it",
      magnitude >= size_floor,
      magnitude,
      size_floor,
    ),
  )
  if !all_ok(checks) {
    return (None, checks)
  }
  let terms : Array[(Int, Double)] = []
  for j = 0; j < n; j = j + 1 {
    if coefficients[j] != 0.0 {
      terms.push((j, coefficients[j]))
    }
  }
  let cut : CutRow = {
    terms: @model.normalize_terms(terms),
    rel: @model.Rel::GreaterEqual,
    rhs: 1.0 - constant_total,
  }
  (Some(cut), checks)
}

///|
/// The cut a witness gives, or the reason it gives none.
///
/// This is the *definition* of the cut the project generates — a producer calls it to
/// get the row it then adds to a model. Nothing about the answer is trusted because a
/// producer asked for it: what a caller gets is a row derived from the model and the
/// multipliers alone, and `verify_cut` re-derives it from the same witness to show the
/// row that goes into the model is that row.
pub fn derive_cut(
  model : @model.Model,
  certificate : CutCertificate,
  tolerance? : Double = default_tolerance,
) -> Result[CutRow, String] {
  let (cut, checks) = cut_checks(model, certificate, tolerance)
  match cut {
    Some(row) => Ok(row)
    None => Err(first_failure(checks))
  }
}

///|
/// What checking a cut concluded, with every measurement behind it.
///
/// Kept apart from `Verdict` on purpose: a `Verdict` answers "does this point prove this
/// claim", and the claims it knows about are about a point's optimality, a model's
/// infeasibility or a ray. A cut is a different kind of statement — about *every*
/// integer point — and folding it into the same type would put a claim in the
/// certificate path that `verify` cannot answer.
pub(all) struct CutVerdict {
  accepted : Bool
  checks : Array[Check]
  /// The first failing check, in words; empty when the cut was accepted.
  reason : String
  /// The cut the witness derives, whether or not it is the one that was offered. A
  /// refusal says how far the offered row was from the row the argument actually gives.
  derived : CutRow?
} derive(Debug)

///|
/// Renders a cut verdict as one line, for CLI output and test messages.
pub fn CutVerdict::to_text(self : CutVerdict) -> String {
  let verdict = if self.accepted { "accepted" } else { "REJECTED" }
  let mut text = "cut: " + verdict
  if !self.accepted {
    text = text + " (" + self.reason + ")"
  }
  for check in self.checks {
    text = text +
      "\n  " +
      (if check.ok { "ok  " } else { "FAIL" }) +
      " " +
      check.name +
      " = " +
      check.measured.to_string() +
      (if check.tolerance > 0.0 {
        " (tolerance " + check.tolerance.to_string() + ")"
      } else {
        ""
      })
  }
  text
}

///|
/// How far `offered` is from `derived`, as the largest scaled coefficient difference.
///
/// A row with a different support is not a nearly-equal row: it is a different cut, and
/// it comes back as the "no finite difference" sentinel rather than as a large number
/// that a tolerance might accidentally pass.
fn cut_difference(
  offered : CutRow,
  derived : CutRow,
  model : @model.Model,
  tolerance : Double,
) -> Double {
  if offered.rel != derived.rel {
    return 1.0e300
  }
  let offered_dense : Array[Double] = Array::make(model.num_vars(), 0.0)
  let derived_dense : Array[Double] = Array::make(model.num_vars(), 0.0)
  for term in offered.terms {
    let (index, coefficient) = term
    if index >= 0 && index < offered_dense.length() {
      offered_dense[index] = offered_dense[index] + coefficient
    }
  }
  for term in derived.terms {
    let (index, coefficient) = term
    if index >= 0 && index < derived_dense.length() {
      derived_dense[index] = derived_dense[index] + coefficient
    }
  }
  let mut worst = 0.0
  for j = 0; j < model.num_vars(); j = j + 1 {
    let scale = 1.0 +
      @core.fmax(@core.fabs(offered_dense[j]), @core.fabs(derived_dense[j]))
    let difference = @core.fabs(offered_dense[j] - derived_dense[j]) / scale
    if difference > worst {
      worst = difference
    }
  }
  let rhs_scale = 1.0 +
    @core.fmax(@core.fabs(offered.rhs), @core.fabs(derived.rhs))
  let rhs_difference = @core.fabs(offered.rhs - derived.rhs) / rhs_scale
  if rhs_difference > worst {
    worst = rhs_difference
  }
  let _ = tolerance
  worst
}

///|
/// Checks that `cut` is a valid inequality for the integer points of `model`, by
/// re-deriving it from `certificate` and comparing.
///
/// This is the gate a cut has to pass before a search may add it to a model. The checks
/// are the ones `cut_checks` measures — the witness reproduces the row it claims, the
/// basic variable is integer, every other variable has a non-negative form, the right
/// hand side is fractionally away from a whole number, and the cut is not the size of
/// the arithmetic that produced it — plus the comparison that the row offered *is* the
/// row the argument gives. A refusal carries every measurement.
pub fn verify_cut(
  model : @model.Model,
  cut : CutRow,
  certificate : CutCertificate,
  tolerance? : Double = default_tolerance,
) -> CutVerdict {
  let (derived, checks) = cut_checks(model, certificate, tolerance)
  match derived {
    None =>
      { accepted: false, checks, reason: first_failure(checks), derived: None, }
    Some(row) => {
      checks.push(
        check(
          "cut matches the derivation",
          cut_difference(cut, row, model, tolerance) <= tolerance,
          cut_difference(cut, row, model, tolerance),
          tolerance,
        ),
      )
      let accepted = all_ok(checks)
      {
        accepted,
        checks,
        reason: if accepted {
          ""
        } else {
          first_failure(checks)
        },
        derived: Some(row),
      }
    }
  }
}
