///|
/// LP format reader and writer (the CPLEX LP subset that people actually write
/// by hand).
///
/// Supported: a minimise/maximise header, an objective line, `Subject To` rows
/// with `<=` / `>=` / `=` (and the weak `<` / `>` forms), `Bounds` lines
/// (`x >= 0`, `x <= 1`, `0 <= x <= 1`, `x = 2`, `x free`, `-infinity <= x`),
/// `Generals` and `Binary` sections, and `End`. Whole-line comments start with
/// `\`.
///
/// Not supported, and reported instead of guessed: quadratic or piecewise
/// linear objectives, `SOS` sets, and bound expressions that reference other
/// variables.

///|
/// Section keywords, matched case-insensitively against the first token.
let lp_sections : Array[String] = [
  "MINIMIZE", "MINIMUM", "MIN", "MAXIMIZE", "MAXIMUM", "MAX", "SUBJECT", "ST", "S.T.",
  "SUCH", "BOUNDS", "BOUND", "GENERAL", "GENERALS", "GEN", "INTEGER", "INTEGERS",
  "BINARY", "BINARIES", "BIN", "END",
]

///|
/// Returns `true` when the token starts an LP section.
fn is_lp_section(token : String) -> Bool {
  for keyword in lp_sections {
    if keyword == token {
      return true
    }
  }
  false
}

///|
/// Removes the trailing `\` comment, if any.
fn strip_lp_comment(line : String) -> String {
  match line.find("\\") {
    Some(index) => line[:index].to_owned()
    None => line
  }
}

///|
/// Length of the numeric prefix of a token: the leading sign, digits, an
/// optional decimal point and an optional exponent (`1`, `-2.5`, `1e-3`).
/// Returns 0 when the token does not start with a number.
fn numeric_prefix_length(token : String) -> Int {
  let chars = token.to_array()
  let mut i = 0
  if i < chars.length() && (chars[i] == '+' || chars[i] == '-') {
    i = i + 1
  }
  let mut digits = 0
  while i < chars.length() &&
        ((chars[i] >= '0' && chars[i] <= '9') || chars[i] == '.') {
    i = i + 1
    digits = digits + 1
  }
  if digits == 0 {
    return 0
  }
  if i < chars.length() && (chars[i] == 'e' || chars[i] == 'E') {
    let mut j = i + 1
    if j < chars.length() && (chars[j] == '+' || chars[j] == '-') {
      j = j + 1
    }
    let mut exponent_digits = 0
    while j < chars.length() && chars[j] >= '0' && chars[j] <= '9' {
      j = j + 1
      exponent_digits = exponent_digits + 1
    }
    if exponent_digits > 0 {
      i = j
    }
  }
  i
}

///|
/// Splits `3x` into `(Some(3.0), "x")` and `-x` into `(Some(-1.0), "x")`.
///
/// A token that is only a number comes back as `(None, token)`; the caller
/// carries it over to the next token, because LP files write `5 x` as often as
/// `5x`.
fn split_coefficient(token : String) -> (Double?, String) {
  let prefix_length = numeric_prefix_length(token)
  if prefix_length == 0 {
    return match token.get_char(0) {
      Some('-') => (Some(-1.0), token[1:].to_owned())
      Some('+') => (Some(1.0), token[1:].to_owned())
      _ => (None, token)
    }
  }
  let name = token[prefix_length:].to_owned()
  if name == "" {
    return (None, token)
  }
  match parse_number(token[:prefix_length].to_owned()) {
    Some(value) => (Some(value), name)
    None => (None, token)
  }
}

///|
/// Splits a glued expression token at embedded `+` / `-` signs: `x+y` becomes
/// `x` and `+y`, `2x-3y` becomes `2x` and `-3y`.
///
/// A sign at position 0 belongs to the token, and a sign directly after an
/// exponent marker (`1e-3`) is part of the number, not an operator.
fn split_signed_terms(token : String) -> Array[String] {
  let chars = token.to_array()
  let parts : Array[String] = []
  if chars.length() == 0 {
    return parts
  }
  let mut start = 0
  let mut index = 1
  while index < chars.length() {
    let char = chars[index]
    let is_sign = char == '+' || char == '-'
    let after_exponent = chars[index - 1] == 'e' || chars[index - 1] == 'E'
    if is_sign && !after_exponent {
      parts.push(String::from_iter(chars[start:index].iter()))
      start = index
    }
    index = index + 1
  }
  parts.push(String::from_iter(chars[start:].iter()))
  parts
}

///|
/// Parses `alpha x + 3y - 2.5 z` into `(variable name, coefficient)` pairs.
///
/// Variables seen here are created in the model on first mention, which is how
/// LP files work: there is no column section, the variables are whatever the
/// expressions name.
fn parse_lp_expression(
  text : String,
  model : @model.Model,
  var_index : Map[String, Int],
  line : Int,
  column_offset : Int,
) -> Result[Array[(Int, Double)], ParseIssue] {
  // Glued terms (`x+y`, `2x-3y`) are split before interpretation, so the rest of
  // the loop only ever sees one term per token.
  let expanded : Array[(String, Int)] = []
  for entry in split_tokens(text) {
    let (token, column) = entry
    let parts = split_signed_terms(token)
    if parts.length() <= 1 {
      expanded.push((token, column))
    } else {
      let mut offset = 0
      for part in parts {
        expanded.push((part, column + offset))
        offset = offset + part.length()
      }
    }
  }
  let tokens = expanded
  let terms : Array[(Int, Double)] = []
  let mut sign = 1.0
  let mut pending : Double? = None
  let mut idx = 0
  while idx < tokens.length() {
    let (token, column) = tokens[idx]
    if token == "+" {
      sign = 1.0
      idx = idx + 1
      continue
    }
    if token == "-" {
      sign = -1.0
      idx = idx + 1
      continue
    }
    if token == "*" {
      idx = idx + 1
      continue
    }
    let (coefficient, name) = split_coefficient(token)
    // A token that is only a number is the coefficient of the next token.
    match parse_number(name) {
      Some(standalone) => {
        pending = Some(sign * standalone)
        sign = 1.0
        idx = idx + 1
        continue
      }
      None => ()
    }
    if name == "" {
      return Err(
        ParseIssue::new(
          line,
          column + column_offset,
          token,
          "expected a variable name",
        ),
      )
    }
    let value = match coefficient {
      Some(explicit) => sign * explicit
      None =>
        match pending {
          Some(saved) => saved
          None => sign
        }
    }
    pending = None
    let index = match var_index.get(name) {
      Some(existing) => existing
      None => {
        let created = model.add_var(name)
        var_index[name] = created
        created
      }
    }
    terms.push((index, value))
    sign = 1.0
    idx = idx + 1
  }
  Ok(terms)
}

///|
/// Parses a bound value: a number, or one of the infinity spellings LP files
/// write (`inf`, `infinity`, with an optional sign).
fn parse_bound_value(text : String) -> Double? {
  let trimmed = text.trim().to_owned()
  let lowered = trimmed.to_lower()
  if lowered == "infinity" ||
    lowered == "inf" ||
    lowered == "+infinity" ||
    lowered == "+inf" {
    return Some(@model.infinite_bound)
  }
  if lowered == "-infinity" || lowered == "-inf" {
    return Some(-@model.infinite_bound)
  }
  parse_number(trimmed)
}

///|
/// Splits `[name:] rest` and returns the offset of `rest` inside the line.
fn split_lp_name(line : String) -> (String, String, Int) {
  match line.find(":") {
    Some(index) => {
      let name = line[:index].trim().to_owned()
      let rest = line[index + 1:].to_owned()
      (name, rest, index + 1)
    }
    None => ("", line, 0)
  }
}

///|
/// Reads a model from LP text.
pub fn read_lp(text : String) -> Result[@model.Model, ParseIssue] {
  let model = @model.Model::new(@model.Sense::Minimize)
  let var_index : Map[String, Int] = Map([])
  let mut section = "HEADER"
  let mut line_number = 0
  for raw in text.split("\n") {
    line_number = line_number + 1
    let line = strip_lp_comment(raw.to_owned())
    let trimmed = line.trim().to_owned()
    if trimmed == "" {
      continue
    }
    let tokens = split_tokens(line)
    let (first, first_col) = tokens[0]
    let upper = first.to_upper()
    if is_lp_section(upper) {
      if upper == "MINIMIZE" || upper == "MINIMUM" || upper == "MIN" {
        model.set_sense(@model.Sense::Minimize)
        section = "OBJECTIVE"
      } else if upper == "MAXIMIZE" || upper == "MAXIMUM" || upper == "MAX" {
        model.set_sense(@model.Sense::Maximize)
        section = "OBJECTIVE"
      } else if upper == "SUBJECT" ||
        upper == "ST" ||
        upper == "S.T." ||
        upper == "SUCH" {
        section = "SUBJECTTO"
      } else if upper == "BOUNDS" || upper == "BOUND" {
        section = "BOUNDS"
      } else if upper == "GENERAL" ||
        upper == "GENERALS" ||
        upper == "GEN" ||
        upper == "INTEGER" ||
        upper == "INTEGERS" {
        section = "GENERALS"
      } else if upper == "BINARY" || upper == "BINARIES" || upper == "BIN" {
        section = "BINARY"
      } else if upper == "END" {
        section = "END"
      }
      continue
    }
    if section == "HEADER" {
      return Err(
        ParseIssue::new(
          line_number, first_col, first, "expected Minimize or Maximize before any expression",
        ),
      )
    }
    if section == "OBJECTIVE" {
      let (_, rest, offset) = split_lp_name(line)
      let terms = match
        parse_lp_expression(rest, model, var_index, line_number, offset) {
        Ok(parsed) => parsed
        Err(issue) => return Err(issue)
      }
      model.set_objective(terms)
      continue
    }
    if section == "SUBJECTTO" {
      let (name, rest, offset) = split_lp_name(line)
      // The relation may be glued to its operands (`x<=1`), so the split has to
      // happen on the text, not on the tokens.
      let (expression_text, rel, rhs_text, rel_offset) = match
        find_relation(rest) {
        Some(found) => found
        None =>
          return Err(
            ParseIssue::new(
              line_number,
              offset + first_col,
              first,
              "a constraint needs one of <=, >= or =",
            ),
          )
      }
      let terms = match
        parse_lp_expression(
          expression_text, model, var_index, line_number, offset,
        ) {
        Ok(parsed) => parsed
        Err(issue) => return Err(issue)
      }
      let rhs = match parse_number(rhs_text.trim().to_owned()) {
        Some(value) => value
        None =>
          return Err(
            ParseIssue::new(
              line_number,
              offset + rel_offset,
              rhs_text.trim().to_owned(),
              "the right hand side must be a number",
            ),
          )
      }
      model.add_named_constraint(terms, rel, rhs, name)
      continue
    }
    if section == "BOUNDS" {
      match apply_lp_bound(line, line_number, model, var_index) {
        Ok(_) => ()
        Err(issue) => return Err(issue)
      }
      continue
    }
    if section == "GENERALS" || section == "BINARY" {
      for token in tokens {
        let name = token.0
        let column = token.1
        let index = match var_index.get(name) {
          Some(existing) => existing
          None => {
            let created = model.add_var(name)
            var_index[name] = created
            created
          }
        }
        model.set_var_integer(index)
        if section == "BINARY" {
          model.set_var_bounds(index, 0.0, 1.0)
        } else if column < 0 {
          return Err(ParseIssue::new(line_number, column, name, "unreachable"))
        }
      }
      continue
    }
    // After END there is nothing to read.
  }
  Ok(model)
}

///|
/// Finds the relation in a constraint's right hand side and splits the text
/// around it. Returns `(left, relation, right, column of the relation)`.
fn find_relation(text : String) -> (String, @model.Rel, String, Int)? {
  let candidates : Array[(String, @model.Rel)] = [
    ("<=", @model.Rel::LessEqual),
    (">=", @model.Rel::GreaterEqual),
    ("=<", @model.Rel::LessEqual),
    ("=>", @model.Rel::GreaterEqual),
    ("==", @model.Rel::Equal),
    ("=", @model.Rel::Equal),
    ("<", @model.Rel::LessEqual),
    (">", @model.Rel::GreaterEqual),
  ]
  for candidate in candidates {
    let (symbol, relation) = candidate
    match text.find(symbol) {
      Some(index) => {
        let after = index + symbol.length()
        return Some(
          (text[:index].to_owned(), relation, text[after:].to_owned(), index),
        )
      }
      None => ()
    }
  }
  None
}

///|
/// Applies one `Bounds` line. Layouts handled: `x >= 0`, `0 <= x`, `x <= 1`,
/// `0 <= x <= 1`, `x = 2`, `x free`, `-infinity <= x <= +infinity`.
fn apply_lp_bound(
  line : String,
  line_number : Int,
  model : @model.Model,
  var_index : Map[String, Int],
) -> Result[Unit, ParseIssue] {
  let tokens = split_tokens(line)
  let normalized = line.trim().to_owned()
  let lowered = normalized.to_lower()
  // `x free`
  if lowered.find("free") is Some(_) {
    let name = tokens[0].0
    let index = ensure_lp_var(name, model, var_index)
    model.set_var_bounds(index, -@model.infinite_bound, @model.infinite_bound)
    return Ok(())
  }
  let (left, first_rel, rest, first_offset) = match find_relation(normalized) {
    Some(found) => found
    None =>
      return Err(
        ParseIssue::new(
          line_number,
          tokens[0].1,
          tokens[0].0,
          "a bounds line needs a relation, `free`, or an assignment",
        ),
      )
  }
  let (middle, second_rel, right) = match find_relation(rest) {
    Some(found) => {
      let (middle_text, relation, right_text, _) = found
      (middle_text, Some(relation), right_text)
    }
    None => (rest, None, "")
  }
  let left_value = parse_bound_value(left)
  let middle_value = parse_bound_value(middle)
  let right_value = parse_bound_value(right)
  match middle_value {
    // `x <= 1`, `x >= 2`, `x = 7`: a number on the right, the name on the left.
    Some(number) =>
      if left_value is Some(_) {
        return Err(
          ParseIssue::new(
            line_number, first_offset, normalized, "expected a variable name, found two numbers",
          ),
        )
      } else {
        let name = left.trim().to_owned()
        if name == "" {
          return Err(
            ParseIssue::new(
              line_number, first_offset, "", "expected a variable name",
            ),
          )
        }
        let index = ensure_lp_var(name, model, var_index)
        apply_bound_side(index, model, true, first_rel, number)
        Ok(())
      }
    // The middle holds the name: `0 <= x`, `x <= 1 <= ...` is not a thing, but
    // `0 <= x <= 1` and `-infinity <= x <= +infinity` are.
    None => {
      let name = middle.trim().to_owned()
      if name == "" {
        return Err(
          ParseIssue::new(
            line_number, first_offset, "", "expected a variable name",
          ),
        )
      }
      let index = ensure_lp_var(name, model, var_index)
      let mut applied = false
      match left_value {
        Some(number) => {
          apply_bound_side(index, model, false, first_rel, number)
          applied = true
        }
        None => ()
      }
      match second_rel {
        Some(relation) =>
          match right_value {
            Some(number) => {
              apply_bound_side(index, model, true, relation, number)
              applied = true
            }
            None =>
              return Err(
                ParseIssue::new(
                  line_number,
                  first_offset,
                  right.trim().to_owned(),
                  "the bound must be a number",
                ),
              )
          }
        None => ()
      }
      if !applied {
        return Err(
          ParseIssue::new(
            line_number, first_offset, normalized, "a bounds line needs a number on at least one side",
          ),
        )
      }
      Ok(())
    }
  }
}

///|
/// Applies one side of a bound statement.
///
/// `name_on_left` distinguishes `x <= 1` from `0 <= x`: the same relation means
/// opposite things depending on which side the variable sits.
fn apply_bound_side(
  index : Int,
  model : @model.Model,
  name_on_left : Bool,
  relation : @model.Rel,
  value : Double,
) -> Unit {
  match relation {
    @model.Rel::Equal => model.set_var_bounds(index, value, value)
    @model.Rel::LessEqual =>
      if name_on_left {
        model.set_var_bounds(index, current_lower(model, index), value)
      } else {
        model.set_var_bounds(index, value, current_upper(model, index))
      }
    @model.Rel::GreaterEqual =>
      if name_on_left {
        model.set_var_bounds(index, value, current_upper(model, index))
      } else {
        model.set_var_bounds(index, current_lower(model, index), value)
      }
  }
}

///|
/// Current lower bound of a variable, used when a `Bounds` line only updates one
/// side.
fn current_lower(model : @model.Model, index : Int) -> Double {
  model.get_var(index).lb
}

///|
/// Current upper bound of a variable.
fn current_upper(model : @model.Model, index : Int) -> Double {
  model.get_var(index).ub
}

///|
/// Looks a variable up, creating it on first mention.
fn ensure_lp_var(
  name : String,
  model : @model.Model,
  var_index : Map[String, Int],
) -> Int {
  match var_index.get(name) {
    Some(existing) => existing
    None => {
      let created = model.add_var(name)
      var_index[name] = created
      created
    }
  }
}

///|
/// Formats `terms` the way LP files write them: `2 x - y + 0.5 z`.
fn format_lp_terms(
  model : @model.Model,
  terms : Array[(Int, Double)],
) -> String {
  let parts : Array[String] = []
  for k = 0; k < terms.length(); k = k + 1 {
    let (index, coefficient) = terms[k]
    let name = model.get_var(index).name
    let body = if coefficient == 1.0 {
      name
    } else if coefficient == -1.0 {
      name
    } else {
      format_number(@core.fabs(coefficient)) + " " + name
    }
    let negative = coefficient < 0.0
    if parts.length() == 0 {
      parts.push(if negative { "- " + body } else { body })
    } else {
      parts.push(if negative { "- " + body } else { "+ " + body })
    }
  }
  if parts.length() == 0 {
    "0"
  } else {
    parts.join(" ")
  }
}

///|
/// Serialises a model to LP text.
pub fn write_lp(model : @model.Model) -> String {
  let lines : Array[String] = []
  lines.push(
    if model.sense() == @model.Sense::Maximize {
      "Maximize"
    } else {
      "Minimize"
    },
  )
  lines.push(" obj: " + format_lp_terms(model, model.objective()))
  if model.num_constraints() > 0 {
    lines.push("Subject To")
    for i = 0; i < model.num_constraints(); i = i + 1 {
      let constraint = model.constraint(i)
      let name = if constraint.name == "" {
        "r" + (i + 1).to_string()
      } else {
        constraint.name.replace_all(old=" ", new="_")
      }
      let symbol = match constraint.rel {
        @model.Rel::LessEqual => "<="
        @model.Rel::GreaterEqual => ">="
        @model.Rel::Equal => "="
      }
      lines.push(
        " " +
        name +
        ": " +
        format_lp_terms(model, constraint.terms) +
        " " +
        symbol +
        " " +
        format_number(constraint.rhs),
      )
    }
  }
  let bound_lines : Array[String] = []
  for j = 0; j < model.num_vars(); j = j + 1 {
    let variable = model.get_var(j)
    let name = variable.name.replace_all(old=" ", new="_")
    let lb = variable.lb
    let ub = variable.ub
    if lb <= -1.0e29 && ub >= 1.0e29 {
      bound_lines.push(" " + name + " free")
    } else if lb <= -1.0e29 {
      bound_lines.push(" " + name + " <= " + format_number(ub))
    } else if ub >= 1.0e29 {
      bound_lines.push(" " + format_number(lb) + " <= " + name)
    } else if lb == ub {
      bound_lines.push(" " + name + " = " + format_number(lb))
    } else {
      bound_lines.push(
        " " + format_number(lb) + " <= " + name + " <= " + format_number(ub),
      )
    }
  }
  if bound_lines.length() > 0 {
    lines.push("Bounds")
    for index = 0; index < bound_lines.length(); index = index + 1 {
      lines.push(bound_lines[index])
    }
  }
  let integer_names : Array[String] = []
  for j = 0; j < model.num_vars(); j = j + 1 {
    let variable = model.get_var(j)
    if variable.is_int && !(variable.lb == 0.0 && variable.ub == 1.0) {
      integer_names.push(variable.name.replace_all(old=" ", new="_"))
    }
  }
  let binary_names : Array[String] = []
  for j = 0; j < model.num_vars(); j = j + 1 {
    let variable = model.get_var(j)
    if variable.is_int && variable.lb == 0.0 && variable.ub == 1.0 {
      binary_names.push(variable.name.replace_all(old=" ", new="_"))
    }
  }
  if integer_names.length() > 0 {
    lines.push("Generals")
    for index = 0; index < integer_names.length(); index = index + 1 {
      lines.push(" " + integer_names[index])
    }
  }
  if binary_names.length() > 0 {
    lines.push("Binary")
    for index = 0; index < binary_names.length(); index = index + 1 {
      lines.push(" " + binary_names[index])
    }
  }
  lines.push("End")
  lines.join("\n") + "\n"
}
