///|
/// The relaxation rows a cut can be rounded from.
///
/// A cut is rounded from one row of an optimal tableau, and that row is a combination
/// of the model's rows: `Σᵢ yᵢ·(row i)` where `y` is a row of the basis inverse. What
/// this module hands out is exactly that combination, in the one form a checker can
/// re-derive it in — **one multiplier per model row**, with the kernel's own
/// normalizations undone, so that
///
/// ```text
///   rⱼ = Σᵢ yᵢ·aᵢⱼ      β = Σᵢ yᵢ·bᵢ
/// ```
///
/// recomputed against the model the caller handed in *is* the tableau row. Nothing else
/// travels: not the kernel's row order, not its slack columns, not its sign flips. The
/// checker in `verify` recomputes `r` and `β` from these numbers and the model, which is
/// the only way a cut can be checked by something that has never seen a simplex.
///
/// Two mapping details are worth stating because they are where a sign goes wrong:
///
/// - the kernel normalizes a row with a negative right hand side by negating it, so a
///   row multiplier of the kernel is the model row's multiplier only after that
///   negation is undone (`row_sign`);
/// - a row the kernel invented — the row form of a free variable's upper bound, or of
///   bounds that contradict each other — has no model row to be a multiplier *of*, and a
///   row whose multipliers touch one is not handed out at all. Nothing is lost: such a
///   row is not a statement about the model that `verify` could check, and a cut whose
///   witness cannot be checked is not a cut this project is willing to use.

///|
/// One tableau row, as the combination of model rows that produced it.
pub(all) struct TableauRow {
  /// The model variable the row is basic in: the variable the row solves for. Its
  /// coefficient in the combination comes out as one.
  basic : Int
  /// Its value in the basis these rows were computed from. Reported for the caller's
  /// benefit — the rounded row's own right hand side is recomputed from the model, not
  /// read off this number, which carries the degeneracy perturbation the run used.
  value : Double
  /// One entry per model row: the coefficient of that row in the combination.
  multipliers : Array[Double]
} derive(Debug)

///|
/// The tableau rows of a solved problem, one per basic model variable.
///
/// The basis has to be one this problem's kernel version produced (`SimplexResult::basis`
/// is the intended source): the rows are read through the basis inverse, and a basis of
/// the wrong shape is refused rather than factored.
pub fn tableau_rows(
  model : @model.Model,
  options : SimplexOptions,
  basis : SimplexBasis,
) -> Result[Array[TableauRow], String] {
  match from_model_with(model, true) {
    Err(reason) => Err(reason)
    Ok(problem) => {
      if basis.nrows != problem.nrows || basis.ncols != problem.ncols {
        return Err(
          "the basis is " +
          basis.nrows.to_string() +
          " x " +
          basis.ncols.to_string() +
          " but this model's kernel problem is " +
          problem.nrows.to_string() +
          " x " +
          problem.ncols.to_string(),
        )
      }
      let state = State::new_with_basis(problem, options, basis)
      if !state.factorized {
        return Err("the basis could not be factorized")
      }
      // Which model variable each structural column belongs to. A variable with no
      // lower bound is two columns (`x = p − n`) and both of them belong to it; the
      // combination's coefficients on the two are opposite, so it is still one
      // coefficient on one model variable, which is what the checker recomputes.
      let variable_of_column : Array[Int] = Array::make(problem.ncols, -1)
      for j = 0; j < problem.var_columns.length(); j = j + 1 {
        for part in problem.var_columns[j] {
          let (column, _) = part
          variable_of_column[column] = j
        }
      }
      let rows : Array[TableauRow] = []
      for i = 0; i < state.m; i = i + 1 {
        let column = state.basis[i]
        if column >= problem.structural {
          continue
        }
        let basic = variable_of_column[column]
        if basic < 0 {
          continue
        }
        let weights = state.inverse_row(i)
        let mut largest = 0.0
        for k = 0; k < state.m; k = k + 1 {
          if @core.fabs(weights[k]) > largest {
            largest = @core.fabs(weights[k])
          }
        }
        // Weights below the round-off of the vector itself are not part of the row;
        // keeping them would put the arithmetic of a zero into the witness.
        let floor = largest * 1.0e-12
        let multipliers : Array[Double] = Array::make(
          model.num_constraints(),
          0.0,
        )
        let mut usable = true
        for k = 0; k < state.m; k = k + 1 {
          let weight = weights[k]
          if @core.fabs(weight) <= floor {
            continue
          }
          let source = problem.row_source[k]
          if source < 0 {
            usable = false
            break
          }
          multipliers[source] = multipliers[source] +
            problem.row_sign[k] * weight
        }
        if !usable {
          continue
        }
        rows.push({ basic, value: state.xb[i], multipliers, })
      }
      Ok(rows)
    }
  }
}
