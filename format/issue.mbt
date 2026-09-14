///|
/// One problem found while reading a model file.
///
/// Positions are 1-based: `line` counts from the start of the file, `column`
/// counts characters from the start of that line, and `token` is the exact text
/// the parser rejected (empty when the problem is not tied to a single token).
pub(all) struct ParseIssue {
  line : Int
  column : Int
  token : String
  message : String
} derive(Debug, Eq)

///|
/// Builds an issue record.
pub fn ParseIssue::new(
  line : Int,
  column : Int,
  token : String,
  message : String,
) -> ParseIssue {
  { line, column, token, message, }
}

///|
/// Single line rendering, used by the CLI and asserted in tests.
pub fn ParseIssue::to_text(self : ParseIssue) -> String {
  let position = "line " +
    self.line.to_string() +
    ", column " +
    self.column.to_string()
  if self.token == "" {
    position + ": " + self.message
  } else {
    position + ": " + self.message + " (token '" + self.token + "')"
  }
}

///|
/// Splits a line into whitespace separated tokens.
///
/// Each token is returned together with its 1-based starting column: a reader
/// that only reports "line 4021 is bad" is useless on a real instance, so the
/// position has to survive tokenisation.
pub fn split_tokens(line : String) -> Array[(String, Int)] {
  let out : Array[(String, Int)] = []
  let normalized = line.replace_all(old="\t", new=" ")
  let mut column = 1
  for part in normalized.split(" ") {
    let token = part.to_owned()
    if token != "" {
      out.push((token, column))
    }
    column = column + token.length() + 1
  }
  out
}

///|
/// Parses a numeric field the way model files write them.
///
/// Besides the usual decimal and exponent forms this also accepts the Fortran
/// style exponent marker (`1.5D+02`) that appears in older MPS files.
pub fn parse_number(token : String) -> Double? {
  let normalized = if token.contains_char('D') {
    token.replace_all(old="D", new="E")
  } else if token.contains_char('d') {
    token.replace_all(old="d", new="E")
  } else {
    token
  }
  try @string.parse_double(normalized) catch {
    _ => None
  } noraise {
    value => Some(value)
  }
}

///|
/// Parses an integer field, used for counts and indices inside model files.
pub fn parse_index(token : String) -> Int? {
  let mut digits = 0
  let mut negative = false
  for c in token {
    if c == '-' && digits == 0 {
      negative = true
    } else if c == '+' && digits == 0 {
      continue
    } else if c >= '0' && c <= '9' {
      digits = digits + 1
    } else {
      return None
    }
  }
  if digits == 0 {
    return None
  }
  try @string.parse_int(token) catch {
    _ => None
  } noraise {
    value => Some(if negative { value } else { value })
  }
}

///|
/// Formats a coefficient for output.
///
/// `Double::to_string` gives the shortest representation that reads back to the
/// same value, which is exactly what a model file needs — no rounding policy of
/// our own on top of it.
pub fn format_number(value : Double) -> String {
  value.to_string()
}
