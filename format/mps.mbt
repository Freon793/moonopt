///|
/// MPS reader.
///
/// Layout: the reader accepts both the classic fixed-column layout and the free
/// layout, because it works on whitespace separated tokens and only falls back
/// to column arithmetic where the format genuinely needs it. Section keywords
/// are recognised case-insensitively, `*` starts a comment line, and data is
/// only converted into a model after the whole file has been read — the
/// `BOUNDS` section comes last but decides the final bounds of columns that
/// `COLUMNS` already introduced.
///
/// Deliberate limits, all reported instead of guessed:
///
/// - semicontinuous bounds (`SC`, `SI`) are not supported;
/// - rows carrying a `RANGES` entry are expanded into two inequalities named
///   `<row>.lo` and `<row>.up`, since a single constraint cannot express a range;
/// - extra `N` rows beyond the first are ignored (only the first is the objective);
/// - a missing `ENDATA` is an error, so a truncated file is never silently
///   accepted as a smaller model.

///|
/// Section keywords, matched case-insensitively.
let mps_sections : Array[String] = [
  "NAME", "ROWS", "COLUMNS", "RHS", "RANGES", "BOUNDS", "OBJSENSE", "ENDATA",
]

///|
/// Bound types understood by the reader.
let mps_bound_types : Array[String] = [
  "LO", "UP", "FX", "FR", "MI", "PL", "BV", "LI", "UI",
]

///|
/// Bound types that are recognised but not supported yet.
let mps_unsupported_bound_types : Array[String] = ["SC", "SI"]

///|
/// Returns `true` when the token is a section keyword.
fn is_mps_section(token : String) -> Bool {
  for keyword in mps_sections {
    if keyword == token {
      return true
    }
  }
  false
}

///|
/// Removes surrounding single quotes (`'MARKER'` → `MARKER`).
fn strip_quotes(text : String) -> String {
  text.trim(chars="'").to_owned()
}

///|
/// Reads an MPS file from its text content.
pub fn parse_mps(text : String) -> Result[@model.Model, ParseIssue] {
  // Collected state. Everything is gathered first and turned into a model at the
  // end, because section order and defaults interact (see the package comment).
  let row_names : Array[String] = []
  let row_rels : Array[@model.Rel] = []
  let row_terms : Array[Array[(Int, Double)]] = []
  let row_range : Array[Double?] = []
  let row_rhs : Array[Double] = []
  let row_index : Map[String, Int] = Map([])
  let col_names : Array[String] = []
  let col_index : Map[String, Int] = Map([])
  let col_is_int : Array[Bool] = []
  let col_lb : Array[Double] = []
  let col_ub : Array[Double] = []
  let objective : Array[(Int, Double)] = []
  let mut objective_row = ""
  // Extra `N` rows beyond the first are *free rows*: MPS declares them, but they
  // are neither constraints nor the objective, so their coefficients are
  // ignored. Real instances do use them (dsbmip is one).
  let free_rows : Map[String, Bool] = Map([])
  let mut sense = @model.Sense::Minimize
  let mut section = ""
  let mut in_integer_block = false
  let mut saw_endata = false
  let mut line_number = 0
  for raw in text.split("\n") {
    line_number = line_number + 1
    let line = raw.to_owned()
    let trimmed = line.trim().to_owned()
    if trimmed == "" {
      continue
    }
    match trimmed.find("*") {
      Some(0) => continue
      _ => ()
    }
    let tokens = split_tokens(line)
    if tokens.length() == 0 {
      continue
    }
    let (first, first_col) = tokens[0]
    let upper = first.to_upper()
    let header = is_mps_section(upper) &&
      (tokens.length() == 1 || upper == "NAME")
    if header {
      section = upper
      if upper == "ENDATA" {
        saw_endata = true
        break
      }
      continue
    }
    if section == "" {
      return Err(
        ParseIssue::new(
          line_number, first_col, first, "data before the first section header",
        ),
      )
    }
    if section == "ROWS" {
      if tokens.length() != 2 {
        return Err(
          ParseIssue::new(
            line_number, first_col, first, "a ROWS line must be '<type> <name>'",
          ),
        )
      }
      let (name, name_col) = tokens[1]
      match upper {
        "N" =>
          if objective_row == "" {
            objective_row = name
          } else {
            free_rows[name] = true
          }
        "L" | "G" | "E" => {
          match row_index.get(name) {
            Some(_) =>
              return Err(
                ParseIssue::new(
                  line_number, name_col, name, "row is declared twice",
                ),
              )
            None => ()
          }
          let rel = if upper == "L" {
            @model.Rel::LessEqual
          } else if upper == "G" {
            @model.Rel::GreaterEqual
          } else {
            @model.Rel::Equal
          }
          row_names.push(name)
          row_rels.push(rel)
          row_terms.push([])
          row_range.push(None)
          row_rhs.push(0.0)
          row_index[name] = row_names.length() - 1
        }
        _ =>
          return Err(
            ParseIssue::new(
              line_number, first_col, first, "unknown row type, expected N, L, G or E",
            ),
          )
      }
      continue
    }
    if section == "COLUMNS" {
      // A marker line either declares the start or the end of an integer block.
      let mut is_marker_line = false
      for token_index = 1
          token_index < tokens.length()
          token_index = token_index + 1 {
        if strip_quotes(tokens[token_index].0.to_upper()) == "MARKER" {
          is_marker_line = true
        }
      }
      if is_marker_line {
        let (last, last_col) = tokens[tokens.length() - 1]
        let kind = strip_quotes(last.to_upper())
        if kind == "INTORG" {
          in_integer_block = true
        } else if kind == "INTEND" {
          in_integer_block = false
        } else {
          return Err(
            ParseIssue::new(
              line_number, last_col, last, "unknown marker, expected INTORG or INTEND",
            ),
          )
        }
        continue
      }
      if tokens.length() != 3 && tokens.length() != 5 {
        return Err(
          ParseIssue::new(
            line_number, first_col, first, "a COLUMNS line must hold a column name and one or two (row, value) pairs",
          ),
        )
      }
      let (col_name, _) = tokens[0]
      let ci = match col_index.get(col_name) {
        Some(existing) => {
          if in_integer_block {
            col_is_int[existing] = true
          }
          existing
        }
        None => {
          col_names.push(col_name)
          col_is_int.push(in_integer_block)
          col_lb.push(0.0)
          col_ub.push(@model.infinite_bound)
          let created = col_names.length() - 1
          col_index[col_name] = created
          created
        }
      }
      let mut pair = 1
      while pair + 1 < tokens.length() {
        let (row_name, row_col) = tokens[pair]
        let (value_text, value_col) = tokens[pair + 1]
        let value = match parse_number(value_text) {
          Some(parsed) => parsed
          None =>
            return Err(
              ParseIssue::new(
                line_number, value_col, value_text, "not a number",
              ),
            )
        }
        if row_name == objective_row {
          objective.push((ci, value))
        } else if free_rows.get(row_name) is Some(_) {
          // Free row: declared, but not part of the problem.
          ()
        } else {
          match row_index.get(row_name) {
            Some(ri) => row_terms[ri].push((ci, value))
            None =>
              return Err(
                ParseIssue::new(
                  line_number, row_col, row_name, "coefficient refers to a row that ROWS never declared",
                ),
              )
          }
        }
        pair = pair + 2
      }
      continue
    }
    if section == "RHS" || section == "RANGES" {
      // Shape: [set name] (row value)+, and whether a set name is present has to
      // be decided by looking at the token: a row name is a name we know.
      let (first_token, _) = tokens[0]
      let mut first_is_row = first_token == objective_row
      if !first_is_row {
        match row_index.get(first_token) {
          Some(_) => first_is_row = true
          None =>
            if free_rows.get(first_token) is Some(_) {
              first_is_row = true
            }
        }
      }
      let mut idx = if first_is_row { 0 } else { 1 }
      if idx >= tokens.length() {
        return Err(
          ParseIssue::new(
            line_number, first_col, first, "line holds a set name but no (row, value) pair",
          ),
        )
      }
      let remaining = tokens.length() - idx
      if remaining % 2 != 0 {
        return Err(
          ParseIssue::new(
            line_number, first_col, first, "expected (row, value) pairs after the optional set name",
          ),
        )
      }
      while idx + 1 < tokens.length() {
        let (row_name, row_col) = tokens[idx]
        let (value_text, value_col) = tokens[idx + 1]
        let value = match parse_number(value_text) {
          Some(parsed) => parsed
          None =>
            return Err(
              ParseIssue::new(
                line_number, value_col, value_text, "not a number",
              ),
            )
        }
        if section == "RHS" {
          match row_index.get(row_name) {
            Some(ri) => row_rhs[ri] = value
            None =>
              // The objective row carries the negated objective constant, which
              // this model layer does not represent; free rows are ignored by
              // definition. Anything else is a broken file.
              if row_name != objective_row && free_rows.get(row_name) is None {
                return Err(
                  ParseIssue::new(
                    line_number, row_col, row_name, "RHS refers to a row that ROWS never declared",
                  ),
                )
              }
          }
        } else {
          match row_index.get(row_name) {
            Some(ri) => row_range[ri] = Some(value)
            None =>
              if free_rows.get(row_name) is None {
                return Err(
                  ParseIssue::new(
                    line_number, row_col, row_name, "RANGES refers to a row that ROWS never declared",
                  ),
                )
              }
          }
        }
        idx = idx + 2
      }
      continue
    }
    if section == "BOUNDS" {
      let bound_type = upper
      let mut supported = false
      for known in mps_bound_types {
        if known == bound_type {
          supported = true
        }
      }
      if !supported {
        let mut unsupported = false
        for known in mps_unsupported_bound_types {
          if known == bound_type {
            unsupported = true
          }
        }
        if unsupported {
          return Err(
            ParseIssue::new(
              line_number, first_col, first, "semicontinuous bounds are not supported",
            ),
          )
        }
        return Err(
          ParseIssue::new(
            line_number, first_col, first, "unknown bound type, expected one of LO UP FX FR MI PL BV LI UI",
          ),
        )
      }
      if tokens.length() < 2 {
        return Err(
          ParseIssue::new(
            line_number, first_col, first, "a BOUNDS line needs a column name",
          ),
        )
      }
      // The optional set name precedes the column; the trailing value is
      // optional. Deciding by shape keeps all three real layouts working.
      let mut value : Double? = None
      let mut column_token = tokens[tokens.length() - 1].0
      let mut column_col = tokens[tokens.length() - 1].1
      let last_token = tokens[tokens.length() - 1].0
      match parse_number(last_token) {
        Some(parsed) =>
          if tokens.length() >= 3 {
            value = Some(parsed)
            column_token = tokens[tokens.length() - 2].0
            column_col = tokens[tokens.length() - 2].1
          }
        None => ()
      }
      let ci = match col_index.get(column_token) {
        Some(existing) => existing
        None =>
          return Err(
            ParseIssue::new(
              line_number, column_col, column_token, "bound refers to a column that COLUMNS never declared",
            ),
          )
      }
      let bound_value = match value {
        Some(explicit) => explicit
        None => 0.0
      }
      if bound_type == "LO" {
        col_lb[ci] = bound_value
      } else if bound_type == "UP" {
        col_ub[ci] = bound_value
      } else if bound_type == "FX" {
        col_lb[ci] = bound_value
        col_ub[ci] = bound_value
      } else if bound_type == "FR" {
        col_lb[ci] = -@model.infinite_bound
        col_ub[ci] = @model.infinite_bound
      } else if bound_type == "MI" {
        col_lb[ci] = -@model.infinite_bound
      } else if bound_type == "PL" {
        col_ub[ci] = @model.infinite_bound
      } else if bound_type == "BV" {
        col_lb[ci] = 0.0
        col_ub[ci] = 1.0
        col_is_int[ci] = true
      } else if bound_type == "LI" {
        col_lb[ci] = bound_value
        col_is_int[ci] = true
      } else if bound_type == "UI" {
        col_ub[ci] = bound_value
        col_is_int[ci] = true
      }
      continue
    }
    if section == "OBJSENSE" {
      if upper == "MAX" || upper == "MAXIMIZE" {
        sense = @model.Sense::Maximize
      } else if upper == "MIN" || upper == "MINIMIZE" {
        sense = @model.Sense::Minimize
      } else {
        return Err(
          ParseIssue::new(
            line_number, first_col, first, "OBJSENSE expects MAX or MIN",
          ),
        )
      }
      continue
    }
    // Remaining sections (NAME continues) hold nothing we model.
  }
  if !saw_endata {
    return Err(
      ParseIssue::new(line_number, 1, "", "file ends without an ENDATA line"),
    )
  }
  let model = @model.Model::new(sense)
  for j = 0; j < col_names.length(); j = j + 1 {
    let _ = model.add_var(
      col_names[j],
      lb=col_lb[j],
      ub=col_ub[j],
      is_int=col_is_int[j],
    )
  }
  model.set_objective(objective)
  for i = 0; i < row_names.length(); i = i + 1 {
    let name = row_names[i]
    let rel = row_rels[i]
    let terms = row_terms[i]
    let rhs = row_rhs[i]
    match row_range[i] {
      None => model.add_named_constraint(terms, rel, rhs, name)
      Some(range) => {
        let width = @core.fabs(range)
        match rel {
          @model.Rel::LessEqual => {
            model.add_named_constraint(terms, @model.Rel::LessEqual, rhs, name)
            model.add_named_constraint(
              terms,
              @model.Rel::GreaterEqual,
              rhs - width,
              name + ".lo",
            )
          }
          @model.Rel::GreaterEqual => {
            model.add_named_constraint(
              terms,
              @model.Rel::GreaterEqual,
              rhs,
              name,
            )
            model.add_named_constraint(
              terms,
              @model.Rel::LessEqual,
              rhs + width,
              name + ".up",
            )
          }
          @model.Rel::Equal =>
            if range >= 0.0 {
              model.add_named_constraint(
                terms,
                @model.Rel::GreaterEqual,
                rhs,
                name + ".lo",
              )
              model.add_named_constraint(
                terms,
                @model.Rel::LessEqual,
                rhs + width,
                name + ".up",
              )
            } else {
              model.add_named_constraint(
                terms,
                @model.Rel::GreaterEqual,
                rhs - width,
                name + ".lo",
              )
              model.add_named_constraint(
                terms,
                @model.Rel::LessEqual,
                rhs,
                name + ".up",
              )
            }
        }
      }
    }
  }
  Ok(model)
}
