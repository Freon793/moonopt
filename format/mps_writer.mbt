///|
/// MPS writer.
///
/// The output is free-layout MPS with the `OBJSENSE` extension, written so that
/// `parse_mps` reads it back into an equivalent model:
///
/// - row and column names are made unique (two constraints may legitimately carry
///   the same name in memory, but not in a file) and freed of whitespace;
/// - integer columns are wrapped in `MARKER`/`INTORG`/`INTEND` lines, the format's
///   only standard way to express integrality;
/// - every bound that differs from the MPS default `0 <= x <= +inf` is written in
///   `BOUNDS`, so a round trip never changes a bound silently.
///
/// Field widths are a courtesy for humans: the layout stays token based, which is
/// what every modern reader (including this project's) expects.

///|
/// A run of spaces.
fn spaces(count : Int) -> String {
  let chars : Array[Char] = []
  for index = 0; index < count; index = index + 1 {
    chars.push(' ')
  }
  String::from_iter(chars.iter())
}

///|
/// Pads a field to at least `width` characters. Longer fields are left alone
/// rather than truncated: a wrong name is worse than a shifted column.
fn pad(text : String, width : Int) -> String {
  if text.length() >= width {
    text
  } else {
    text + spaces(width - text.length())
  }
}

///|
/// Replaces characters that would break the token layout.
fn sanitize_name(name : String) -> String {
  let replaced = name.replace_all(old=" ", new="_")
  if replaced == "" {
    "unnamed"
  } else {
    replaced
  }
}

///|
/// Emits at most two `(name, value)` pairs per line, which is the classic limit.
fn push_pairs(
  lines : Array[String],
  prefix : String,
  pairs : Array[(String, Double)],
) -> Unit {
  let mut idx = 0
  while idx < pairs.length() {
    let (first_name, first_value) = pairs[idx]
    if idx + 1 < pairs.length() {
      let (second_name, second_value) = pairs[idx + 1]
      lines.push(
        prefix +
        pad(first_name, 10) +
        "  " +
        pad(format_number(first_value), 14) +
        "  " +
        pad(second_name, 10) +
        "  " +
        format_number(second_value),
      )
      idx = idx + 2
    } else {
      lines.push(
        prefix + pad(first_name, 10) + "  " + format_number(first_value),
      )
      idx = idx + 1
    }
  }
}

///|
/// `true` when the value is the negative infinity sentinel of the model layer.
fn is_negative_infinity(value : Double) -> Bool {
  value <= -1.0e29
}

///|
/// `true` when the value is the positive infinity sentinel of the model layer.
fn is_positive_infinity(value : Double) -> Bool {
  value >= 1.0e29
}

///|
/// Serialises a model to MPS text.
pub fn write_mps(model : @model.Model) -> String {
  let nvars = model.num_vars()
  let ncons = model.num_constraints()
  let objective_row = "OBJ"
  let lines : Array[String] = []
  lines.push("NAME" + spaces(12) + "MOONOPT")
  lines.push("OBJSENSE")
  lines.push(
    " " + (if model.sense() == @model.Sense::Maximize { "MAX" } else { "MIN" }),
  )
  // Row names: unique, non-empty, never clashing with the objective row.
  let used : Map[String, Bool] = Map([])
  used[objective_row] = true
  let row_names : Array[String] = []
  for i = 0; i < ncons; i = i + 1 {
    let raw = sanitize_name(model.constraint(i).name)
    let base = if raw == "unnamed" { "R" + (i + 1).to_string() } else { raw }
    let mut candidate = base
    let mut attempt = 0
    while (match used.get(candidate) {
            Some(_) => true
            None => false
          }) {
      attempt = attempt + 1
      candidate = base + "." + attempt.to_string()
    }
    used[candidate] = true
    row_names.push(candidate)
  }
  lines.push("ROWS")
  lines.push(" N" + spaces(2) + objective_row)
  for i = 0; i < ncons; i = i + 1 {
    let code = match model.constraint(i).rel {
      @model.Rel::LessEqual => "L"
      @model.Rel::GreaterEqual => "G"
      @model.Rel::Equal => "E"
    }
    lines.push(" " + code + spaces(2) + row_names[i])
  }
  // Column oriented view: the objective coefficient plus the row coefficients.
  let col_objective : Array[Double] = Array::make(nvars, 0.0)
  for term in model.objective() {
    let (index, coefficient) = term
    col_objective[index] = coefficient
  }
  let col_rows : Array[Array[(Int, Double)]] = []
  for index = 0; index < nvars; index = index + 1 {
    col_rows.push([])
  }
  for i = 0; i < ncons; i = i + 1 {
    let terms = model.constraint(i).terms
    for k = 0; k < terms.length(); k = k + 1 {
      let (index, coefficient) = terms[k]
      col_rows[index].push((i, coefficient))
    }
  }
  // Columns are emitted in variable order, so a round trip keeps variable
  // indices stable; each maximal run of integer columns becomes one
  // `INTORG`/`INTEND` block.
  lines.push("COLUMNS")
  let mut inside_integer_block = false
  for j = 0; j < nvars; j = j + 1 {
    let is_int = model.get_var(j).is_int
    if is_int && !inside_integer_block {
      lines.push("    MARKER" + spaces(4) + "'MARKER'" + spaces(4) + "'INTORG'")
      inside_integer_block = true
    } else if !is_int && inside_integer_block {
      lines.push("    MARKER" + spaces(4) + "'MARKER'" + spaces(4) + "'INTEND'")
      inside_integer_block = false
    }
    push_column(
      lines, model, j, col_objective, col_rows, row_names, objective_row,
    )
  }
  if inside_integer_block {
    lines.push("    MARKER" + spaces(4) + "'MARKER'" + spaces(4) + "'INTEND'")
  }
  // RHS
  let rhs_pairs : Array[(String, Double)] = []
  for i = 0; i < ncons; i = i + 1 {
    let rhs = model.constraint(i).rhs
    if rhs != 0.0 {
      rhs_pairs.push((row_names[i], rhs))
    }
  }
  if rhs_pairs.length() > 0 {
    lines.push("RHS")
    push_pairs(lines, "    RHS" + spaces(2), rhs_pairs)
  }
  // BOUNDS
  let bound_lines : Array[String] = []
  for j = 0; j < nvars; j = j + 1 {
    let variable = model.get_var(j)
    let name = sanitize_name(variable.name)
    let lb = variable.lb
    let ub = variable.ub
    if is_negative_infinity(lb) && is_positive_infinity(ub) {
      bound_lines.push(" FR BND" + spaces(2) + name)
    } else if !is_negative_infinity(lb) && !is_positive_infinity(ub) && lb == ub {
      bound_lines.push(
        " FX BND" + spaces(2) + name + spaces(2) + format_number(lb),
      )
    } else {
      if is_negative_infinity(lb) {
        bound_lines.push(" MI BND" + spaces(2) + name)
      } else if lb != 0.0 {
        bound_lines.push(
          " LO BND" + spaces(2) + name + spaces(2) + format_number(lb),
        )
      }
      if !is_positive_infinity(ub) {
        bound_lines.push(
          " UP BND" + spaces(2) + name + spaces(2) + format_number(ub),
        )
      }
    }
  }
  if bound_lines.length() > 0 {
    lines.push("BOUNDS")
    for index = 0; index < bound_lines.length(); index = index + 1 {
      lines.push(bound_lines[index])
    }
  }
  lines.push("ENDATA")
  lines.join("\n") + "\n"
}

///|
/// Emits one column: its objective coefficient followed by its row coefficients.
/// A column that appears nowhere is still declared (with a zero objective
/// coefficient), otherwise the file could not carry the variable at all.
fn push_column(
  lines : Array[String],
  model : @model.Model,
  index : Int,
  col_objective : Array[Double],
  col_rows : Array[Array[(Int, Double)]],
  row_names : Array[String],
  objective_row : String,
) -> Unit {
  let name = sanitize_name(model.get_var(index).name)
  let pairs : Array[(String, Double)] = []
  if col_objective[index] != 0.0 {
    pairs.push((objective_row, col_objective[index]))
  }
  for k = 0; k < col_rows[index].length(); k = k + 1 {
    let (row, coefficient) = col_rows[index][k]
    pairs.push((row_names[row], coefficient))
  }
  if pairs.length() == 0 {
    pairs.push((objective_row, 0.0))
  }
  push_pairs(lines, "    " + pad(name, 12) + "  ", pairs)
}
