///|
/// The LP / MILP model layer.
///
/// A `Model` is the single source of truth for the optimisation problem: it
/// stores variables (with bounds and integrality flags), the objective and the
/// constraint rows. Nothing in this package knows how to solve anything.
///
/// Two conventions matter for the rest of the project:
/// – coefficients are stored as `(variable index, coefficient)` pairs, sorted by
///   index, duplicate indices merged and exact zeros dropped;
/// – `±1e30` is used as the numeric stand-in for an infinite bound, so that the
///   kernel never has to special-case infinities.

///|
/// Optimisation direction.
///
/// `pub(all)` on purpose: other packages (the parsers, the solver, user code)
/// must be able to build and match these values.
pub(all) enum Sense {
  Minimize
  Maximize
} derive(Debug, Eq)

///|
/// Relation of a constraint row.
pub(all) enum Rel {
  LessEqual
  GreaterEqual
  Equal
} derive(Debug, Eq)

///|
/// One decision variable.
pub struct Var {
  name : String
  lb : Double
  ub : Double
  is_int : Bool
} derive(Debug)

///|
/// One constraint row: `terms relation rhs`.
pub struct Constraint {
  name : String
  rel : Rel
  rhs : Double
  terms : Array[(Int, Double)]
} derive(Debug)

///|
/// Parses an objective sense keyword as used by MPS (`MAX` / `MIN`, also the
/// long forms). Returns `None` for anything else so callers can report a
/// precise parse error.
pub fn Sense::from_symbol(symbol : String) -> Sense? {
  if symbol == "MIN" || symbol == "MINIMIZE" || symbol == "MINIMUM" {
    Some(Minimize)
  } else if symbol == "MAX" || symbol == "MAXIMIZE" || symbol == "MAXIMUM" {
    Some(Maximize)
  } else {
    None
  }
}

///|
/// Parses an MPS row type keyword: `L` (less-equal), `G` (greater-equal),
/// `E` (equal). Returns `None` for anything else.
pub fn Rel::from_symbol(symbol : String) -> Rel? {
  if symbol == "L" || symbol == "LE" || symbol == "<=" || symbol == "=<" {
    Some(LessEqual)
  } else if symbol == "G" || symbol == "GE" || symbol == ">=" || symbol == "=>" {
    Some(GreaterEqual)
  } else if symbol == "E" || symbol == "EQ" || symbol == "=" || symbol == "==" {
    Some(Equal)
  } else {
    None
  }
}

///|
/// Numeric stand-in for an infinite bound.
pub let infinite_bound : Double = 1.0e30

///|
/// An optimisation model under construction.
pub struct Model {
  mut sense : Sense
  mut objective_terms : Array[(Int, Double)]
  vars : Array[Var]
  constraints : Array[Constraint]
} derive(Debug)

///|
/// Creates an empty model with the given optimisation direction.
pub fn Model::new(sense : Sense) -> Model {
  { sense, objective_terms: [], vars: [], constraints: [], }
}

///|
/// Current optimisation direction.
pub fn Model::sense(self : Model) -> Sense {
  self.sense
}

///|
/// Changes the optimisation direction after the fact.
pub fn Model::set_sense(self : Model, sense : Sense) -> Unit {
  self.sense = sense
}

///|
/// Number of variables.
pub fn Model::num_vars(self : Model) -> Int {
  self.vars.length()
}

///|
/// Number of constraint rows.
pub fn Model::num_constraints(self : Model) -> Int {
  self.constraints.length()
}

///|
/// Adds a variable and returns its index.
///
/// `lb = 0.0` and `ub = infinite_bound` give the LP default `x >= 0`. Set
/// `is_int = true` for integer variables (binary variables are `lb = 0`,
/// `ub = 1`, `is_int = true`).
pub fn Model::add_var(
  self : Model,
  name : String,
  lb? : Double = 0.0,
  ub? : Double = infinite_bound,
  is_int? : Bool = false,
) -> Int {
  self.vars.push({ name, lb, ub, is_int, })
  self.vars.length() - 1
}

///|
/// Reads back a variable definition. (`var` is a keyword in MoonBit, hence the
/// name.)
pub fn Model::get_var(self : Model, index : Int) -> Var {
  self.vars[index]
}

///|
/// Replaces the objective, merging duplicates and dropping zeros.
pub fn Model::set_objective(self : Model, terms : Array[(Int, Double)]) -> Unit {
  self.objective_terms = normalize_terms(terms)
}

///|
/// Objective as sorted `(variable index, coefficient)` pairs.
pub fn Model::objective(self : Model) -> Array[(Int, Double)] {
  self.objective_terms
}

///|
/// Adds an unnamed constraint row.
pub fn Model::add_constraint(
  self : Model,
  terms : Array[(Int, Double)],
  rel : Rel,
  rhs : Double,
) -> Unit {
  self.add_named_constraint(terms, rel, rhs, "")
}

///|
/// Adds a constraint row carrying a human readable name (used by reports and by
/// the MPS writer).
pub fn Model::add_named_constraint(
  self : Model,
  terms : Array[(Int, Double)],
  rel : Rel,
  rhs : Double,
  name : String,
) -> Unit {
  self.constraints.push({ name, rel, rhs, terms: normalize_terms(terms), })
}

///|
/// Reads back a constraint row.
pub fn Model::constraint(self : Model, index : Int) -> Constraint {
  self.constraints[index]
}

///|
/// Checks the model for structural problems. An empty result means the model is
/// well formed; a non-empty result lists human readable issues.
///
/// This is deliberately a pure function returning messages instead of raising,
/// so callers (CLI, tests, future LSP tooling) can render them however they
/// want.
pub fn Model::validate(self : Model) -> Array[String] {
  let issues : Array[String] = []
  let nvars = self.vars.length()
  for i = 0; i < nvars; i = i + 1 {
    let v = self.vars[i]
    if !@core.is_finite(v.lb) {
      issues.push("variable " + v.name + ": lower bound is not finite")
    }
    if !@core.is_finite(v.ub) {
      issues.push("variable " + v.name + ": upper bound is not finite")
    }
    if v.lb > v.ub {
      issues.push("variable " + v.name + ": lower bound exceeds upper bound")
    }
    for k = 0; k < i; k = k + 1 {
      if self.vars[k].name == v.name && v.name != "" {
        issues.push("variable " + v.name + ": duplicate name")
      }
    }
  }
  for j = 0; j < self.objective_terms.length(); j = j + 1 {
    let (index, coeff) = self.objective_terms[j]
    if index < 0 || index >= nvars {
      issues.push("objective: variable index out of range")
    }
    if !@core.is_finite(coeff) {
      issues.push("objective: non-finite coefficient")
    }
  }
  for c = 0; c < self.constraints.length(); c = c + 1 {
    let con = self.constraints[c]
    let label = if con.name == "" { "#" + c.to_string() } else { con.name }
    if con.terms.length() == 0 {
      issues.push("constraint " + label + ": empty row")
    }
    if !@core.is_finite(con.rhs) {
      issues.push("constraint " + label + ": non-finite right hand side")
    }
    for t = 0; t < con.terms.length(); t = t + 1 {
      let (index, coeff) = con.terms[t]
      if index < 0 || index >= nvars {
        issues.push("constraint " + label + ": variable index out of range")
      }
      if !@core.is_finite(coeff) {
        issues.push("constraint " + label + ": non-finite coefficient")
      }
    }
  }
  issues
}

///|
/// Returns `true` when the model passes `validate`.
pub fn Model::is_valid(self : Model) -> Bool {
  self.validate().length() == 0
}

///|
/// Sorts terms by variable index, merges duplicates and drops zeros.
pub fn normalize_terms(terms : Array[(Int, Double)]) -> Array[(Int, Double)] {
  let sorted = terms.copy()
  let n = sorted.length()
  for i = 1; i < n; i = i + 1 {
    let cur = sorted[i]
    let mut j = i - 1
    while j >= 0 && sorted[j].0 > cur.0 {
      sorted[j + 1] = sorted[j]
      j = j - 1
    }
    sorted[j + 1] = cur
  }
  let merged : Array[(Int, Double)] = []
  for k = 0; k < n; k = k + 1 {
    let (index, coeff) = sorted[k]
    if merged.length() > 0 && merged[merged.length() - 1].0 == index {
      let last = merged.length() - 1
      let previous = merged[last].1
      merged[last] = (index, previous + coeff)
    } else {
      merged.push((index, coeff))
    }
  }
  let out : Array[(Int, Double)] = []
  for k = 0; k < merged.length(); k = k + 1 {
    if merged[k].1 != 0.0 {
      out.push(merged[k])
    }
  }
  out
}
