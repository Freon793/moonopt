///|
/// Presolve: shrink a model before the kernel sees it, and keep enough
/// information to put the original variables back together afterwards.
///
/// Every reduction here is *proved* from the current bounds and rows; nothing is
/// dropped on a hunch. A row leaves the model only when its activity range
/// already satisfies it, a variable is fixed only at a value an improving
/// direction or a proved equality forces, and a bound moves only when a row's
/// own activity range implies it. When the reductions prove that the model has no
/// feasible point, or that the objective is unbounded, that verdict is returned
/// instead of a reduced model — the same discipline the kernel follows.
///
/// Why this matters for this kernel in particular: finite upper bounds become
/// explicit rows, so the kernel's row count is the model's rows plus the number
/// of bounded variables. A reduction that proves a bound is implied, or that
/// fixes a variable outright, removes rows from the kernel's problem rather than
/// only from the model.
///
/// The reduction is exact, so a solution of the reduced model maps back to a
/// solution of the original one. The tests check both halves of that claim: on
/// random models the presolved-then-reconstructed solve agrees with the direct
/// one in status and objective, and the reconstructed values are feasible for the
/// original rows.

///|
/// One entry of the reconstruction: how an original variable is recovered from
/// the reduced model.
pub(all) enum VarForm {
  /// The variable was eliminated at a proved value.
  Fixed(Double)
  /// The variable is a linear form of the reduced model's variables:
  /// `x = constant + Σ coefficient · y_k`.
  Linear(Double, Array[(Int32, Double)])
} derive(Debug)

///|
/// What the reduction proved about the model.
pub(all) enum PresolveVerdict {
  /// The model was reduced (possibly to zero rows and zero variables).
  Reduced
  /// No point satisfies the model.
  Infeasible
  /// The objective is unbounded on the feasible set.
  Unbounded
} derive(Debug, Eq)

///|
/// Counters for one run. They are what makes the reduction observable: a caller
/// can see which of the reductions fired instead of taking "presolve helped" on
/// faith.
pub(all) struct PresolveStats {
  rows_removed_empty : Int32
  rows_removed_redundant : Int32
  rows_removed_singleton : Int32
  bounds_tightened : Int32
  variables_fixed : Int32
  /// How many of `variables_fixed` were fixed by dual fixing — a variable whose
  /// improving direction cannot violate a row, rather than one an equality pinned.
  variables_fixed_dual : Int32
  /// Rows whose coefficients were tightened by integrality. Always zero here: the
  /// strengthening (`strengthen_integer_rows`) is a reduction of the *integer* path,
  /// which this reduction never sees, and it reports its own count.
  rows_strengthened : Int32
  columns_removed_empty : Int32
  rounds : Int32
} derive(Debug)

///|
/// A model ready for the kernel, plus the map back to the original variables.
pub struct ReducedModel {
  model : @model.Model
  forms : Array[VarForm]
  objective_offset : Double
  stats : PresolveStats
  verdict : PresolveVerdict
  reason : String
}

///|
/// The model the kernel should solve.
pub fn ReducedModel::reduced(self : ReducedModel) -> @model.Model {
  self.model
}

///|
/// The reductions that fired.
pub fn ReducedModel::stats(self : ReducedModel) -> PresolveStats {
  self.stats
}

///|
/// Whether the reduction finished, or proved something about the model.
pub fn ReducedModel::verdict(self : ReducedModel) -> PresolveVerdict {
  self.verdict
}

///|
/// Why the model was declared infeasible or unbounded; empty otherwise.
pub fn ReducedModel::reason(self : ReducedModel) -> String {
  self.reason
}

///|
/// Objective contribution of the eliminated variables, in the model's own sense.
pub fn ReducedModel::objective_offset(self : ReducedModel) -> Double {
  self.objective_offset
}

///|
/// Number of variables in the original model, which is also the length of a
/// reconstructed solution.
pub fn ReducedModel::num_original_vars(self : ReducedModel) -> Int32 {
  self.forms.length()
}

///|
/// The reduction's own objective for a reduced objective value: the kernel
/// optimises the surviving variables, the eliminated ones contribute a constant.
pub fn ReducedModel::objective(
  self : ReducedModel,
  reduced_objective : Double,
) -> Double {
  reduced_objective + self.objective_offset
}

///|
/// Working copy of a variable.
priv struct WorkVar {
  name : String
  mut lb : Double
  mut ub : Double
  is_int : Bool
  mut cost : Double
  mut alive : Bool
}

///|
/// Working copy of a row.
priv struct WorkRow {
  name : String
  rel : @model.Rel
  mut rhs : Double
  mut terms : Array[(Int32, Double)]
  mut alive : Bool
}

///|
/// What a row's activity range proves about that row.
priv enum RowVerdict {
  /// Every point inside the current bounds satisfies it.
  Always
  /// No point inside the current bounds satisfies it.
  Never
  /// The bounds alone decide nothing.
  Undecided
}

///|
/// The tolerance every "proved" decision is measured against. Reductions use a
/// margin of this size, so a row is only removed when it is satisfied with room
/// to spare, and infeasibility is only reported when the violation is larger
/// than the tolerance the kernel itself treats as round-off.
fn scale_tolerance(rhs : Double) -> Double {
  1.0e-9 * (1.0 + @core.fabs(rhs))
}

///|
/// `true` for the model layer's infinite-bound sentinel and for anything that
/// overflowed past it. Sentinel arithmetic has to be recognised, not trusted:
/// `-1e30` is a perfectly finite double.
fn is_sentinel(value : Double) -> Bool {
  @core.is_nan(value) || @core.fabs(value) >= @model.infinite_bound
}

///|
/// Internal accumulator for one run.
priv struct Reduction {
  sense : @model.Sense
  vars : Array[WorkVar]
  rows : Array[WorkRow]
  mut offset : Double
  fixed_values : Array[Double]
  mut infeasible : String
  mut unbounded : String
  mut rows_removed_empty : Int32
  mut rows_removed_redundant : Int32
  mut rows_removed_singleton : Int32
  mut bounds_tightened : Int32
  mut variables_fixed : Int32
  mut variables_fixed_dual : Int32
  mut columns_removed_empty : Int32
  mut rounds : Int32
}

///|
/// Solves the reduction's bookkeeping from a model.
fn Reduction::new(model : @model.Model) -> Reduction {
  let n = model.num_vars()
  let vars : Array[WorkVar] = []
  for j = 0; j < n; j = j + 1 {
    let variable = model.get_var(j)
    vars.push({
      name: variable.name,
      lb: variable.lb,
      ub: variable.ub,
      is_int: variable.is_int,
      cost: 0.0,
      alive: true,
    })
  }
  for term in @model.normalize_terms(model.objective()) {
    let (j, coefficient) = term
    if j >= 0 && j < n {
      vars[j].cost = vars[j].cost + coefficient
    }
  }
  let rows : Array[WorkRow] = []
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    rows.push({
      name: constraint.name,
      rel: constraint.rel,
      rhs: constraint.rhs,
      terms: @model.normalize_terms(constraint.terms),
      alive: true,
    })
  }
  {
    sense: model.sense(),
    vars,
    rows,
    offset: 0.0,
    fixed_values: Array::make(n, 0.0),
    infeasible: "",
    unbounded: "",
    rows_removed_empty: 0,
    rows_removed_redundant: 0,
    rows_removed_singleton: 0,
    bounds_tightened: 0,
    variables_fixed: 0,
    variables_fixed_dual: 0,
    columns_removed_empty: 0,
    rounds: 0,
  }
}

///|
/// `true` once the run has nothing more to do.
fn Reduction::stopped(self : Reduction) -> Bool {
  self.infeasible != "" || self.unbounded != ""
}

///|
/// Activity range of a linear form over the current bounds.
///
/// An entry is `None` when an infinite bound leaves that direction unbounded. The
/// terms that cause that are *counted* rather than summed: adding the sentinel to
/// itself produces NaN, and two sentinels of opposite sign would cancel into a
/// finite number that looks like a proof.
fn Reduction::activity(
  self : Reduction,
  terms : Array[(Int32, Double)],
) -> (Double?, Double?) {
  let mut low = 0.0
  let mut low_unbounded = 0
  let mut high = 0.0
  let mut high_unbounded = 0
  for term in terms {
    let (k, coefficient) = term
    let lb = self.vars[k].lb
    let ub = self.vars[k].ub
    let low_bound = if coefficient > 0.0 { lb } else { ub }
    let high_bound = if coefficient > 0.0 { ub } else { lb }
    let low_contribution = coefficient * low_bound
    let high_contribution = coefficient * high_bound
    if is_sentinel(low_bound) || is_sentinel(low_contribution) {
      low_unbounded = low_unbounded + 1
    } else {
      low = low + low_contribution
    }
    if is_sentinel(high_bound) || is_sentinel(high_contribution) {
      high_unbounded = high_unbounded + 1
    } else {
      high = high + high_contribution
    }
  }
  let low_result = if low_unbounded > 0 { None } else { Some(low) }
  let high_result = if high_unbounded > 0 { None } else { Some(high) }
  (low_result, high_result)
}

///|
/// What the row's own activity range proves.
fn Reduction::row_verdict(self : Reduction, row : WorkRow) -> RowVerdict {
  let (low, high) = self.activity(row.terms)
  let tolerance = scale_tolerance(row.rhs)
  match row.rel {
    @model.Rel::LessEqual =>
      match (low, high) {
        (Some(smallest), _) =>
          if smallest > row.rhs + tolerance {
            Never
          } else {
            match high {
              Some(largest) =>
                if largest <= row.rhs + tolerance {
                  Always
                } else {
                  Undecided
                }
              None => Undecided
            }
          }
        (None, _) =>
          match high {
            Some(largest) =>
              if largest <= row.rhs + tolerance {
                Always
              } else {
                Undecided
              }
            None => Undecided
          }
      }
    @model.Rel::GreaterEqual =>
      match (low, high) {
        (_, Some(largest)) =>
          if largest < row.rhs - tolerance {
            Never
          } else {
            match low {
              Some(smallest) =>
                if smallest >= row.rhs - tolerance {
                  Always
                } else {
                  Undecided
                }
              None => Undecided
            }
          }
        (_, None) =>
          match low {
            Some(smallest) =>
              if smallest >= row.rhs - tolerance {
                Always
              } else {
                Undecided
              }
            None => Undecided
          }
      }
    @model.Rel::Equal =>
      match (low, high) {
        (Some(smallest), Some(largest)) =>
          if smallest > row.rhs + tolerance || largest < row.rhs - tolerance {
            Never
          } else if smallest >= row.rhs - tolerance &&
            largest <= row.rhs + tolerance {
            Always
          } else {
            Undecided
          }
        _ => Undecided
      }
  }
}

///|
/// Marks the run as infeasible, keeping the first reason found.
fn Reduction::prove_infeasible(self : Reduction, site : String) -> Unit {
  if self.infeasible == "" {
    self.infeasible = "presolve proved the model infeasible at " + site
  }
}

///|
/// Marks the objective as unbounded, keeping the first reason found.
fn Reduction::prove_unbounded(self : Reduction, site : String) -> Unit {
  if self.unbounded == "" {
    self.unbounded = "presolve proved the objective unbounded at " + site
  }
}

///|
/// Drops terms that refer to eliminated variables or carry a zero coefficient.
/// Returns the number of rows that changed.
fn Reduction::prune_terms(self : Reduction) -> Int32 {
  let mut changed = 0
  for i = 0; i < self.rows.length(); i = i + 1 {
    if !self.rows[i].alive {
      continue
    }
    let kept : Array[(Int32, Double)] = []
    let mut removed = false
    for term in self.rows[i].terms {
      let (k, coefficient) = term
      if !self.vars[k].alive || @core.approx_zero(coefficient, abs=1.0e-12) {
        removed = true
      } else {
        kept.push(term)
      }
    }
    if removed {
      self.rows[i].terms = kept
      changed = changed + 1
    }
  }
  changed
}

///|
/// Removes rows the current bounds already satisfy, and stops the run when the
/// bounds make a row impossible.
fn Reduction::drop_settled_rows(self : Reduction) -> Int32 {
  let mut changed = 0
  for i = 0; i < self.rows.length(); i = i + 1 {
    if !self.rows[i].alive {
      continue
    }
    match self.row_verdict(self.rows[i]) {
      Never => self.prove_infeasible(self.rows[i].name)
      Always => {
        if self.rows[i].terms.length() == 0 {
          self.rows_removed_empty = self.rows_removed_empty + 1
        } else {
          self.rows_removed_redundant = self.rows_removed_redundant + 1
        }
        self.rows[i].alive = false
        changed = changed + 1
      }
      Undecided => ()
    }
  }
  changed
}

///|
/// Raises a lower bound, counting a change only when it actually moved.
fn Reduction::raise_lower(
  self : Reduction,
  k : Int32,
  value : Double,
  tolerance : Double,
) -> Int32 {
  if @core.is_nan(value) {
    return 0
  }
  if value > self.vars[k].lb + tolerance {
    self.vars[k].lb = value
    self.bounds_tightened = self.bounds_tightened + 1
    return 1
  }
  0
}

///|
/// Lowers an upper bound, counting a change only when it actually moved.
fn Reduction::lower_upper(
  self : Reduction,
  k : Int32,
  value : Double,
  tolerance : Double,
) -> Int32 {
  if @core.is_nan(value) {
    return 0
  }
  if value < self.vars[k].ub - tolerance {
    self.vars[k].ub = value
    self.bounds_tightened = self.bounds_tightened + 1
    return 1
  }
  0
}

///|
/// Uses a row to move the bounds of the variables in it.
///
/// The two directions are not symmetric, and getting them the wrong way round is
/// the classic presolve bug:
///
/// | row | the row bounds each term | the other terms enter through |
/// | --- | --- | --- |
/// | `Σ aⱼ xⱼ ≤ b` | above: `aₖ xₖ ≤ b − min(others)` | their **minimum** |
/// | `Σ aⱼ xⱼ ≥ b` | below: `aₖ xₖ ≥ b − max(others)` | their **maximum** |
///
/// A `≤` row bounds a term above because the others can be as small as their
/// minimum; a `≥` row bounds it below because the others can be as large as their
/// maximum. Which side of the variable that lands on then depends on the sign of
/// `aₖ`, since dividing by a negative coefficient flips the inequality.
///
/// The "others" value is built from aggregates over the row rather than by
/// subtracting the term's own contribution: a variable's bound is usually
/// infinite in exactly the direction being tightened, and `∞ − ∞` would turn the
/// most useful case into a NaN that looks like "no information".
fn Reduction::tighten_from_row(self : Reduction, row : WorkRow) -> Int32 {
  let tolerance = scale_tolerance(row.rhs)
  let count = row.terms.length()
  let low_finite : Array[Double] = Array::make(count, 0.0)
  let high_finite : Array[Double] = Array::make(count, 0.0)
  let low_unbounded_here : Array[Bool] = Array::make(count, false)
  let high_unbounded_here : Array[Bool] = Array::make(count, false)
  let mut low_sum = 0.0
  let mut low_unbounded = 0
  let mut high_sum = 0.0
  let mut high_unbounded = 0
  for t = 0; t < count; t = t + 1 {
    let (k, coefficient) = row.terms[t]
    let lb = self.vars[k].lb
    let ub = self.vars[k].ub
    let low_bound = if coefficient > 0.0 { lb } else { ub }
    let high_bound = if coefficient > 0.0 { ub } else { lb }
    let low_contribution = coefficient * low_bound
    let high_contribution = coefficient * high_bound
    if is_sentinel(low_bound) || is_sentinel(low_contribution) {
      low_unbounded_here[t] = true
      low_unbounded = low_unbounded + 1
    } else {
      low_finite[t] = low_contribution
      low_sum = low_sum + low_contribution
    }
    if is_sentinel(high_bound) || is_sentinel(high_contribution) {
      high_unbounded_here[t] = true
      high_unbounded = high_unbounded + 1
    } else {
      high_finite[t] = high_contribution
      high_sum = high_sum + high_contribution
    }
  }
  let bound_above = row.rel == @model.Rel::LessEqual ||
    row.rel == @model.Rel::Equal
  let bound_below = row.rel == @model.Rel::GreaterEqual ||
    row.rel == @model.Rel::Equal
  let mut changed = 0
  for t = 0; t < count; t = t + 1 {
    let (k, coefficient) = row.terms[t]
    if bound_above {
      let others = if low_unbounded_here[t] {
        if low_unbounded - 1 > 0 {
          None
        } else {
          Some(low_sum)
        }
      } else if low_unbounded > 0 {
        None
      } else {
        Some(low_sum - low_finite[t])
      }
      match others {
        Some(value) => {
          let rest = row.rhs - value
          if coefficient > 0.0 {
            changed = changed +
              self.lower_upper(k, rest / coefficient, tolerance)
          } else {
            changed = changed +
              self.raise_lower(k, rest / coefficient, tolerance)
          }
        }
        None => ()
      }
    }
    if bound_below {
      let others = if high_unbounded_here[t] {
        if high_unbounded - 1 > 0 {
          None
        } else {
          Some(high_sum)
        }
      } else if high_unbounded > 0 {
        None
      } else {
        Some(high_sum - high_finite[t])
      }
      match others {
        Some(value) => {
          let rest = row.rhs - value
          if coefficient > 0.0 {
            changed = changed +
              self.raise_lower(k, rest / coefficient, tolerance)
          } else {
            changed = changed +
              self.lower_upper(k, rest / coefficient, tolerance)
          }
        }
        None => ()
      }
    }
  }
  changed
}

///|
/// Turns `a x {≤, ≥, =} b` on a single variable into bounds on that variable, and
/// consumes the row: after this it carries no information the bounds do not.
fn Reduction::consume_singleton_rows(self : Reduction) -> Int32 {
  let mut changed = 0
  for i = 0; i < self.rows.length(); i = i + 1 {
    if !self.rows[i].alive || self.rows[i].terms.length() != 1 {
      continue
    }
    let (k, coefficient) = self.rows[i].terms[0]
    let rhs = self.rows[i].rhs
    let tolerance = scale_tolerance(rhs)
    let value = rhs / coefficient
    match self.rows[i].rel {
      @model.Rel::LessEqual =>
        if coefficient > 0.0 {
          self.lower_upper(k, value, tolerance) |> ignore
        } else {
          self.raise_lower(k, value, tolerance) |> ignore
        }
      @model.Rel::GreaterEqual =>
        if coefficient > 0.0 {
          self.raise_lower(k, value, tolerance) |> ignore
        } else {
          self.lower_upper(k, value, tolerance) |> ignore
        }
      @model.Rel::Equal => {
        self.raise_lower(k, value, tolerance) |> ignore
        self.lower_upper(k, value, tolerance) |> ignore
      }
    }
    self.rows[i].alive = false
    self.rows_removed_singleton = self.rows_removed_singleton + 1
    changed = changed + 1
  }
  changed
}

///|
/// Eliminates a variable by substituting its value into every row and into the
/// objective. The value becomes part of the objective offset, so the caller's
/// objective stays comparable with the original model's.
fn Reduction::fix_variable(
  self : Reduction,
  k : Int32,
  value : Double,
) -> Int32 {
  self.offset = self.offset + self.vars[k].cost * value
  for i = 0; i < self.rows.length(); i = i + 1 {
    if !self.rows[i].alive {
      continue
    }
    let kept : Array[(Int32, Double)] = []
    let mut touched = false
    for term in self.rows[i].terms {
      let (j, coefficient) = term
      if j == k {
        self.rows[i].rhs = self.rows[i].rhs - coefficient * value
        touched = true
      } else {
        kept.push(term)
      }
    }
    if touched {
      self.rows[i].terms = kept
    }
  }
  self.vars[k].lb = value
  self.vars[k].ub = value
  self.vars[k].alive = false
  self.fixed_values[k] = value
  self.variables_fixed = self.variables_fixed + 1
  1
}

///|
/// Eliminates every variable whose bounds meet, and every variable whose bounds
/// were proved to meet by a singleton equality.
fn Reduction::eliminate_fixed(self : Reduction) -> Int32 {
  let mut changed = 0
  for k = 0; k < self.vars.length(); k = k + 1 {
    if !self.vars[k].alive {
      continue
    }
    let lb = self.vars[k].lb
    let ub = self.vars[k].ub
    if lb > ub + scale_tolerance(ub) {
      self.prove_infeasible(
        "variable " + self.vars[k].name + " has conflicting bounds",
      )
      continue
    }
    if ub - lb <= scale_tolerance(ub) {
      let value = if is_sentinel(lb) { 0.0 } else { lb }
      changed = changed + self.fix_variable(k, value)
    }
  }
  changed
}

///|
/// Which variables still appear in a live row.
fn Reduction::row_incidence(self : Reduction) -> Array[Bool] {
  let used = Array::make(self.vars.length(), false)
  for i = 0; i < self.rows.length(); i = i + 1 {
    if !self.rows[i].alive {
      continue
    }
    for term in self.rows[i].terms {
      let (k, _) = term
      used[k] = true
    }
  }
  used
}

///|
/// Eliminates variables that no live row mentions.
///
/// Such a variable is decided by its own cost: the objective alone says whether
/// to drive it to a bound, and if that side has no finite bound the model is
/// unbounded. With a zero cost any feasible value does, so the variable is fixed
/// at the first finite bound it has.
fn Reduction::eliminate_empty_columns(self : Reduction) -> Int32 {
  let used = self.row_incidence()
  let mut changed = 0
  for k = 0; k < self.vars.length(); k = k + 1 {
    if !self.vars[k].alive || used[k] {
      continue
    }
    let cost = self.vars[k].cost
    let name = self.vars[k].name
    let lb = self.vars[k].lb
    let ub = self.vars[k].ub
    let mut target : Double? = None
    if @core.approx_zero(cost, abs=1.0e-12) {
      if !is_sentinel(lb) {
        target = Some(lb)
      } else if !is_sentinel(ub) {
        target = Some(ub)
      } else {
        target = Some(0.0)
      }
    } else {
      // Minimisation wants the smallest cost contribution, maximisation the
      // largest, so the improving side flips with the sense.
      let towards_lower = if self.sense == @model.Sense::Minimize {
        cost > 0.0
      } else {
        cost < 0.0
      }
      if towards_lower {
        if is_sentinel(lb) {
          self.prove_unbounded(
            "variable " +
            name +
            " appears in no constraint and has no finite lower bound",
          )
        } else {
          target = Some(lb)
        }
      } else if is_sentinel(ub) {
        self.prove_unbounded(
          "variable " +
          name +
          " appears in no constraint and has no finite upper bound",
        )
      } else {
        target = Some(ub)
      }
    }
    match target {
      Some(value) => {
        self.fix_variable(k, value) |> ignore
        self.columns_removed_empty = self.columns_removed_empty + 1
        changed = changed + 1
      }
      None => ()
    }
  }
  changed
}

///|
/// Fixes every variable whose improving direction cannot violate a row ("dual fixing").
///
/// A variable can be pinned at one of its bounds when moving it the way the objective
/// wants can only relax the constraints. Decreasing `x` relaxes a row written `a·x ≤ b`
/// where its coefficient is positive, and a `≥` row where the coefficient is negative;
/// increasing it is the mirror image. When *every* row the variable appears in is of
/// that kind, any feasible point can be moved to the bound without becoming infeasible
/// and without making the objective worse — so an optimal solution with the variable at
/// that bound exists, and the model can be solved without it.
///
/// The check is per row and one-sided on purpose: a single row where the move tightens
/// the constraint disqualifies the direction, and an equality row disqualifies both.
/// An integer variable is only pinned at an integer bound, because the claim is that an
/// optimal solution *at that value* exists, not that a value may be rounded.
fn Reduction::fix_monotone_columns(self : Reduction) -> Int32 {
  let n = self.vars.length()
  // Per variable: which single-bound moves are safe in every row it appears in.
  let down_safe = Array::make(n, true)
  let up_safe = Array::make(n, true)
  for i = 0; i < self.rows.length(); i = i + 1 {
    if !self.rows[i].alive {
      continue
    }
    let rel = self.rows[i].rel
    for term in self.rows[i].terms {
      let (k, coefficient) = term
      if coefficient > 0.0 {
        if rel != @model.Rel::LessEqual {
          down_safe[k] = false
        }
        if rel != @model.Rel::GreaterEqual {
          up_safe[k] = false
        }
      } else if coefficient < 0.0 {
        if rel != @model.Rel::GreaterEqual {
          down_safe[k] = false
        }
        if rel != @model.Rel::LessEqual {
          up_safe[k] = false
        }
      }
    }
  }
  let mut changed = 0
  for k = 0; k < n; k = k + 1 {
    if !self.vars[k].alive {
      continue
    }
    // Conflicting bounds are a verdict, not a variable to pin: pinning `x` at a bound
    // that its own range no longer contains is how an infeasibility gets papered over.
    // `eliminate_fixed` owns that case and reports it, and it runs before this.
    if self.vars[k].lb > self.vars[k].ub + scale_tolerance(self.vars[k].ub) {
      continue
    }
    let cost = self.vars[k].cost
    let indifferent = @core.approx_zero(cost, abs=1.0e-12)
    let towards_lower = if self.sense == @model.Sense::Minimize {
      cost > 0.0
    } else {
      cost < 0.0
    }
    // A variable the objective is indifferent about may move either way; the lower
    // bound is preferred so the choice does not depend on the order rows were visited.
    let mut use_lower = if indifferent {
      !is_sentinel(self.vars[k].lb)
    } else {
      towards_lower
    }
    if !indifferent &&
      !use_lower &&
      is_sentinel(self.vars[k].ub) &&
      !is_sentinel(self.vars[k].lb) {
      // The improving side has no bound at all, so there is nothing to pin the
      // variable to; reporting unboundedness is the caller's business (an empty column
      // says it outright), and for a constrained one it is simply not provable here.
      use_lower = false
    }
    let safe = if use_lower { down_safe[k] } else { up_safe[k] }
    if !safe {
      continue
    }
    let bound = if use_lower { self.vars[k].lb } else { self.vars[k].ub }
    if is_sentinel(bound) {
      continue
    }
    if self.vars[k].is_int &&
      !@core.approx_eq(
        bound,
        Double::from_int(bound.to_int()),
        rel=0.0,
        abs=1.0e-9,
      ) {
      continue
    }
    changed = changed + self.fix_variable(k, bound)
    self.variables_fixed_dual = self.variables_fixed_dual + 1
  }
  changed
}

///|
/// Runs the reductions to a fixpoint. Each round sees the bounds and rows the
/// previous one produced, which is what lets an implied bound from one row make
/// another row redundant.
fn Reduction::run(self : Reduction) -> Unit {
  let mut round = 0
  while round < 100 && !self.stopped() {
    let mut changed = 0
    changed = changed + self.prune_terms()
    changed = changed + self.drop_settled_rows()
    if self.stopped() {
      break
    }
    for i = 0; i < self.rows.length(); i = i + 1 {
      if self.rows[i].alive {
        changed = changed + self.tighten_from_row(self.rows[i])
      }
    }
    changed = changed + self.consume_singleton_rows()
    changed = changed + self.eliminate_fixed()
    changed = changed + self.eliminate_empty_columns()
    // Dual fixing runs last on purpose: an empty column and a variable whose bounds have
    // already met are more specific explanations for the same fix, and a variable those
    // reductions own should be attributed to them (and, when its bounds conflict, should
    // reach `eliminate_fixed`'s verdict rather than being pinned here).
    changed = changed + self.fix_monotone_columns()
    self.rounds = self.rounds + 1
    round = round + 1
    if changed == 0 {
      break
    }
  }
}

///|
/// Builds the reduced model and the reconstruction map.
fn Reduction::build(self : Reduction) -> (Array[VarForm], @model.Model) {
  let new_index = Array::make(self.vars.length(), -1)
  let out = @model.Model::new(self.sense)
  for k = 0; k < self.vars.length(); k = k + 1 {
    if self.vars[k].alive {
      new_index[k] = out.add_var(
        self.vars[k].name,
        lb=self.vars[k].lb,
        ub=self.vars[k].ub,
        is_int=self.vars[k].is_int,
      )
    }
  }
  let objective : Array[(Int32, Double)] = []
  for k = 0; k < self.vars.length(); k = k + 1 {
    if self.vars[k].alive && !@core.approx_zero(self.vars[k].cost, abs=1.0e-12) {
      objective.push((new_index[k], self.vars[k].cost))
    }
  }
  out.set_objective(@model.normalize_terms(objective))
  for i = 0; i < self.rows.length(); i = i + 1 {
    if !self.rows[i].alive {
      continue
    }
    let mapped : Array[(Int32, Double)] = []
    for term in self.rows[i].terms {
      let (k, coefficient) = term
      if new_index[k] >= 0 {
        mapped.push((new_index[k], coefficient))
      }
    }
    out.add_named_constraint(
      @model.normalize_terms(mapped),
      self.rows[i].rel,
      self.rows[i].rhs,
      self.rows[i].name,
    )
  }
  let forms : Array[VarForm] = []
  for k = 0; k < self.vars.length(); k = k + 1 {
    if self.vars[k].alive {
      forms.push(Linear(0.0, [(new_index[k], 1.0)]))
    } else {
      forms.push(Fixed(self.fixed_values[k]))
    }
  }
  (forms, out)
}

///|
/// Reduces a model that the kernel could otherwise be handed unchanged.
///
/// The verdict is part of the result rather than an exception: a model that
/// presolve proves infeasible or unbounded needs no kernel run at all, and
/// saying so is more useful than handing the kernel a provably hopeless model.
pub fn presolve(model : @model.Model) -> ReducedModel {
  let reduction = Reduction::new(model)
  reduction.run()
  let (forms, reduced) = reduction.build()
  let verdict = if reduction.infeasible != "" {
    Infeasible
  } else if reduction.unbounded != "" {
    Unbounded
  } else {
    Reduced
  }
  let reason = if reduction.infeasible != "" {
    reduction.infeasible
  } else {
    reduction.unbounded
  }
  {
    model: reduced,
    forms,
    objective_offset: reduction.offset,
    stats: {
      rows_removed_empty: reduction.rows_removed_empty,
      rows_removed_redundant: reduction.rows_removed_redundant,
      rows_removed_singleton: reduction.rows_removed_singleton,
      bounds_tightened: reduction.bounds_tightened,
      variables_fixed: reduction.variables_fixed,
      variables_fixed_dual: reduction.variables_fixed_dual,
      rows_strengthened: 0,
      columns_removed_empty: reduction.columns_removed_empty,
      rounds: reduction.rounds,
    },
    verdict,
    reason,
  }
}

///|
/// Tightens the coefficients of an integer model's rows, where integrality licenses it
/// ("coefficient strengthening"). Returns the strengthened model and how many rows
/// changed; a model with no row it applies to is returned untouched.
///
/// A row `Σ aₖxₖ ≤ b` bounds an **integer** variable `xⱼ ≥ lⱼ` by what the right hand
/// side leaves after the other terms: they can contribute no less than some `rest_min`,
/// so `aⱼ(xⱼ − lⱼ) ≤ cap := b − aⱼlⱼ − rest_min`, and the largest value the variable can
/// take is `k := ⌊cap / aⱼ⌋`. The coefficient itself can be raised — but only as far as
/// the other terms allow them to *rise*: they can also contribute as much as `rest_max`,
/// and a bigger coefficient must not cut a value that used to be feasible with them at
/// their largest, so `aⱼ' = ⌊(b − aⱼlⱼ − rest_max) / k⌋`. When `aⱼ' > aⱼ` the row is
/// stronger and the integers it accepts are the same ones. Using `rest_min` on both sides
/// would be wrong, and the difference is not academic: `3x + y ≤ 5` with `x, y ∈ [0, 10]`
/// integer would become `5x + y ≤ 5` and lose `(x, y) = (1, 2)`. The same arithmetic gives
/// the integer upper bound the row implies (`xⱼ ≤ lⱼ + k`), which is applied too.
///
/// Three guards keep the claim honest:
///
/// - **the variable whose coefficient moves has to be integer** — raising a coefficient
///   removes real points, and integrality is what makes the removed ones unreachable;
///   everything else in the row may be continuous;
/// - the least the other terms can contribute has to be **finite**, or there is no `cap`;
/// - equality rows are left alone: the rule is about a one-sided inequality.
///
/// This is a presolve for the *integer* path, which is why it does not live in
/// `Reduction` with the others: the linear presolve never sees an integer model (the
/// answer to an integer model must not depend on what a reduction fixed), so a rule that
/// needs integrality has no row to fire on there.
pub fn strengthen_integer_rows(model : @model.Model) -> (@model.Model, Int32) {
  let n = model.num_vars()
  let lower : Array[Double] = []
  let upper : Array[Double] = []
  let is_int : Array[Bool] = []
  for j = 0; j < n; j = j + 1 {
    let variable = model.get_var(j)
    lower.push(variable.lb)
    upper.push(variable.ub)
    is_int.push(variable.is_int)
  }
  let tighter_upper = upper.copy()
  let rewritten : Array[(String, @model.Rel, Double, Array[(Int32, Double)])] = []
  let mut changed = 0
  for i = 0; i < model.num_constraints(); i = i + 1 {
    let constraint = model.constraint(i)
    let terms = @model.normalize_terms(constraint.terms)
    let out = terms.copy()
    let mut row_changed = false
    // Work in `≤` form: a `≥` row is the same row multiplied by −1.
    let sign = if constraint.rel == @model.Rel::GreaterEqual {
      -1.0
    } else {
      1.0
    }
    if constraint.rel != @model.Rel::Equal {
      let bound = constraint.rhs * sign
      for t = 0; t < terms.length(); t = t + 1 {
        let (j, _) = terms[t]
        let coefficient = out[t].1 * sign
        if coefficient <= 0.0 || !is_int[j] {
          continue
        }
        if is_sentinel(lower[j]) || is_sentinel(upper[j]) {
          continue
        }
        // The largest and the smallest the other terms can contribute. Both are needed
        // and they answer different questions: the *smallest* says how far this variable
        // can reach (the row is easiest for it when the others sit at their minimum), the
        // *largest* says how much room is left when it is at a value the row has to keep
        // feasible. A coefficient raised on the minimum alone cuts points the original
        // row allows — `3x + y ≤ 5` with `x, y ∈ [0, 10]` integer would become
        // `5x + y ≤ 5`, which throws away `(x, y) = (1, 2)`.
        let mut rest_min = 0.0
        let mut rest_max = 0.0
        let mut finite = true
        for u = 0; u < out.length(); u = u + 1 {
          if u == t {
            continue
          }
          let (k, value) = out[u]
          let flipped = value * sign
          let low_end = if flipped > 0.0 { lower[k] } else { upper[k] }
          let high_end = if flipped > 0.0 { upper[k] } else { lower[k] }
          if is_sentinel(low_end) || is_sentinel(high_end) {
            finite = false
            break
          }
          rest_min = rest_min + flipped * low_end
          rest_max = rest_max + flipped * high_end
        }
        if !finite {
          continue
        }
        // `cap` is what this variable's own term may spend, after shifting it to zero.
        let room = bound - coefficient * lower[j]
        let cap = room - rest_min
        if cap <= 0.0 {
          continue
        }
        let reachable = (cap / coefficient).to_int()
        let span = upper[j] - lower[j]
        if reachable < 1 || Double::from_int(reachable) >= span - 1.0e-9 {
          // Either only the lower bound is reachable (bound tightening's business) or
          // the variable's own range already fits, so there is nothing to raise.
          continue
        }
        // The raise must keep every reachable value feasible whatever the other terms
        // do, so it is bounded by the room left when they contribute their maximum.
        let left = room - rest_max
        if left <= 0.0 {
          continue
        }
        let raised = Double::from_int(
          (left / Double::from_int(reachable)).to_int(),
        )
        if raised > coefficient + 1.0e-12 {
          out[t] = (j, raised * sign)
          row_changed = true
          let implied = lower[j] + Double::from_int(reachable)
          if implied < tighter_upper[j] {
            tighter_upper[j] = implied
          }
        }
      }
    }
    if row_changed {
      changed = changed + 1
    }
    rewritten.push((constraint.name, constraint.rel, constraint.rhs, out))
  }
  if changed == 0 {
    return (model, 0)
  }
  let out = @model.Model::new(model.sense())
  for j = 0; j < n; j = j + 1 {
    let variable = model.get_var(j)
    out.add_var(
      variable.name,
      lb=variable.lb,
      ub=tighter_upper[j],
      is_int=variable.is_int,
    )
    |> ignore
  }
  out.set_objective(@model.normalize_terms(model.objective()))
  for row in rewritten {
    let (name, rel, rhs, terms) = row
    out.add_named_constraint(terms, rel, rhs, name)
  }
  (out, changed)
}
