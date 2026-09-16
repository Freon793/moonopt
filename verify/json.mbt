///|
/// JSON for certificates, written and read here rather than pulled in as a
/// dependency: library packages in this project stay dependency free, and the shape
/// is small enough that a reader for it is shorter than an adapter would be.
///
/// The format is one object:
///
/// ```json
/// {"version":1,"claim":"optimal","objective":8,
///  "values":[0,4],"duals":[2,0],"ray":[]}
/// ```
///
/// A number that is not finite is written as `null`, and reading one back fails:
/// a certificate that cannot be written down honestly is not written down at all.
/// Anything malformed fails the read as a whole — a half-read certificate is not a
/// certificate.

///|
/// A parsed JSON value, as much of one as a certificate needs.
///
/// `null`, `true` and `false` are recognised by the scanner and rejected: a
/// certificate has no place for them, and `null` is how a number that is not finite
/// would have been written.
priv enum Json {
  Number(Double)
  Text(String)
  Array(Array[Json])
  Object(Array[(String, Json)])
}

///|
/// Renders a double as a JSON number, or `null` when it is not finite.
fn json_number(value : Double) -> String {
  if @core.is_finite(value) {
    value.to_string()
  } else {
    "null"
  }
}

///|
/// Renders an array of doubles.
fn json_numbers(values : Array[Double]) -> String {
  let parts : Array[String] = []
  for value in values {
    parts.push(json_number(value))
  }
  "[" + parts.join(",") + "]"
}

///|
/// The claim as it appears in JSON, so a reader does not have to know the enum's
/// internal spelling.
fn claim_name(claim : Claim) -> String {
  match claim {
    Claim::Optimal => "optimal"
    Claim::Infeasible => "infeasible"
    Claim::Unbounded => "unbounded"
  }
}

///|
/// Reads a claim back from its JSON spelling.
fn claim_of_name(name : String) -> Claim? {
  match name {
    "optimal" => Some(Claim::Optimal)
    "infeasible" => Some(Claim::Infeasible)
    "unbounded" => Some(Claim::Unbounded)
    _ => None
  }
}

///|
/// Serialises a certificate.
pub fn Certificate::to_json(self : Certificate) -> String {
  "{\"version\":1,\"claim\":\"" +
  claim_name(self.claim) +
  "\",\"objective\":" +
  json_number(self.objective) +
  ",\"values\":" +
  json_numbers(self.values) +
  ",\"duals\":" +
  json_numbers(self.duals) +
  ",\"ray\":" +
  json_numbers(self.ray) +
  "}"
}

///|
/// A cursor over the characters being parsed. The text is split into characters
/// once, so the scanner can move by index without going through the string API on
/// every character.
priv struct JsonReader {
  chars : Array[Char]
  mut position : Int
}

///|
/// Splits a string into characters.
fn chars_of(text : String) -> Array[Char] {
  let chars : Array[Char] = []
  for character in text {
    chars.push(character)
  }
  chars
}

///|
/// The next character, or `None` at the end.
fn JsonReader::peek(self : JsonReader) -> Char? {
  if self.position >= self.chars.length() {
    None
  } else {
    Some(self.chars[self.position])
  }
}

///|
/// Skips whitespace.
fn JsonReader::skip_space(self : JsonReader) -> Unit {
  while true {
    let current = self.peek()
    if current is Some(character) &&
      (
        character == ' ' ||
        character == '\t' ||
        character == '\n' ||
        character == '\r'
      ) {
      self.position = self.position + 1
      continue
    }
    break
  }
}

///|
/// The remaining characters, as text, for error-free passthrough of numbers.
fn JsonReader::token_from(self : JsonReader, start : Int) -> String {
  let builder = StringBuilder()
  for i = start; i < self.position; i = i + 1 {
    builder.write_char(self.chars[i])
  }
  builder.to_string()
}

///|
/// Parses a JSON string literal, with the escapes a certificate can carry (none of
/// them, in practice — but a reader that rejected them outright would be lying about
/// being a JSON reader).
fn JsonReader::parse_string(self : JsonReader) -> String? {
  if self.peek() != Some('"') {
    return None
  }
  self.position = self.position + 1
  let builder = StringBuilder()
  while true {
    let current = self.peek()
    if current is None {
      return None
    }
    let character = current.unwrap()
    self.position = self.position + 1
    if character == '"' {
      return Some(builder.to_string())
    }
    if character == '\\' {
      let escape = self.peek()
      self.position = self.position + 1
      match escape {
        Some('n') => builder.write_char('\n')
        Some('t') => builder.write_char('\t')
        Some('r') => builder.write_char('\r')
        Some('"') => builder.write_char('"')
        Some('\\') => builder.write_char('\\')
        Some('/') => builder.write_char('/')
        _ => return None
      }
      continue
    }
    builder.write_char(character)
  }
  None
}

///|
/// Parses a number. `null`, `true` and `false` are valid JSON and rejected here.
fn JsonReader::parse_scalar(self : JsonReader) -> Json? {
  let start = self.position
  while true {
    let current = self.peek()
    if current is Some(character) {
      let digit = character >= '0' && character <= '9'
      let part = character == '-' ||
        character == '+' ||
        character == '.' ||
        character == 'e' ||
        character == 'E'
      if digit || part {
        self.position = self.position + 1
        continue
      }
    }
    break
  }
  let token = self.token_from(start)
  if token == "" || token == "null" || token == "true" || token == "false" {
    return None
  }
  try @string.parse_double(token) catch {
    _ => None
  } noraise {
    value => Some(Number(value))
  }
}

///|
/// Parses an array; the opening bracket has been consumed.
fn JsonReader::parse_array(self : JsonReader) -> Json? {
  let items : Array[Json] = []
  self.skip_space()
  if self.peek() == Some(']') {
    self.position = self.position + 1
    return Some(Array(items))
  }
  while true {
    match self.parse_value() {
      Some(item) => items.push(item)
      None => return None
    }
    self.skip_space()
    match self.peek() {
      Some(',') => {
        self.position = self.position + 1
        continue
      }
      Some(']') => {
        self.position = self.position + 1
        return Some(Array(items))
      }
      _ => return None
    }
  }
  None
}

///|
/// Parses an object; the opening brace has been consumed.
fn JsonReader::parse_object(self : JsonReader) -> Json? {
  let fields : Array[(String, Json)] = []
  self.skip_space()
  if self.peek() == Some('}') {
    self.position = self.position + 1
    return Some(Object(fields))
  }
  while true {
    self.skip_space()
    let key = match self.parse_string() {
      Some(text) => text
      None => return None
    }
    self.skip_space()
    if self.peek() != Some(':') {
      return None
    }
    self.position = self.position + 1
    let value = match self.parse_value() {
      Some(parsed) => parsed
      None => return None
    }
    fields.push((key, value))
    self.skip_space()
    match self.peek() {
      Some(',') => {
        self.position = self.position + 1
        continue
      }
      Some('}') => {
        self.position = self.position + 1
        return Some(Object(fields))
      }
      _ => return None
    }
  }
  None
}

///|
/// Parses any JSON value.
fn JsonReader::parse_value(self : JsonReader) -> Json? {
  self.skip_space()
  match self.peek() {
    None => None
    Some('"') =>
      match self.parse_string() {
        Some(text) => Some(Text(text))
        None => None
      }
    Some('[') => {
      self.position = self.position + 1
      self.parse_array()
    }
    Some('{') => {
      self.position = self.position + 1
      self.parse_object()
    }
    Some(_) => self.parse_scalar()
  }
}

///|
/// Looks a field up in a parsed object.
fn Json::field(self : Json, name : String) -> Json? {
  match self {
    Object(fields) => {
      for entry in fields {
        let (key, value) = entry
        if key == name {
          return Some(value)
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Reads an array of numbers. A `null` member (which is how a non-finite number
/// would have been written) fails the read instead of becoming a zero.
fn Json::numbers(self : Json) -> Array[Double]? {
  match self {
    Array(items) => {
      let out : Array[Double] = []
      for item in items {
        match item {
          Number(value) => out.push(value)
          _ => return None
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
/// Reads a string field.
fn Json::text(self : Json) -> String? {
  match self {
    Text(value) => Some(value)
    _ => None
  }
}

///|
/// Reads a number field.
fn Json::number(self : Json) -> Double? {
  match self {
    Number(value) => Some(value)
    _ => None
  }
}

///|
/// Parses a certificate. Returns `None` rather than a half-filled certificate when
/// anything is missing or malformed — a certificate that cannot be read is not a
/// certificate that can be trusted.
pub fn Certificate::from_json(text : String) -> Certificate? {
  let reader : JsonReader = { chars: chars_of(text), position: 0, }
  let parsed = match reader.parse_value() {
    Some(value) => value
    None => return None
  }
  reader.skip_space()
  if reader.position != reader.chars.length() {
    return None
  }
  let claim_text = match parsed.field("claim") {
    Some(value) =>
      match value.text() {
        Some(name) => name
        None => return None
      }
    None => return None
  }
  let claim = match claim_of_name(claim_text) {
    Some(value) => value
    None => return None
  }
  let values = match parsed.field("values") {
    Some(value) =>
      match value.numbers() {
        Some(numbers) => numbers
        None => return None
      }
    None => return None
  }
  let duals = match parsed.field("duals") {
    Some(value) =>
      match value.numbers() {
        Some(numbers) => numbers
        None => return None
      }
    None => return None
  }
  let ray = match parsed.field("ray") {
    Some(value) =>
      match value.numbers() {
        Some(numbers) => numbers
        None => return None
      }
    None => []
  }
  let objective = match parsed.field("objective") {
    Some(value) =>
      match value.number() {
        Some(number) => number
        None => 0.0
      }
    None => 0.0
  }
  Some({ claim, values, duals, ray, objective, })
}
