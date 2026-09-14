///|
/// Model file inspection CLI.
///
/// It exists to make the `format` package observable from the outside: it reads
/// model files, reports what it found, and exits non-zero if any file failed.
/// The benchmark harness uses the same entry point on the whole Netlib set.
///
/// Usage:
///
/// ```
/// moon run cmd/parse -- <file> [<file> ...]
/// moon run cmd/parse -- --manifest <list-file>
/// ```
///
/// A manifest is a text file with one path per line; `#` starts a comment. The
/// paths inside it are resolved relative to the manifest's own directory, which
/// is what makes the checked-in manifest usable from any working directory.

///|
/// Prints the usage line.
fn print_usage() -> Unit {
  println("usage: moon run cmd/parse -- <file> [<file> ...]")
  println("       moon run cmd/parse -- --manifest <list-file>")
}

///|
/// Reads a text file, reporting the reason instead of aborting.
fn read_text(path : String) -> String? {
  try @fs.read_file_to_string(path) catch {
    @fs.IOError(message) => {
      println("cannot read " + path + ": " + message)
      None
    }
  } noraise {
    content => Some(content)
  }
}

///|
/// `true` when the path names an LP file. Everything else is treated as MPS,
/// which is decided by the content when the extension says nothing.
fn looks_like_lp(path : String, content : String) -> Bool {
  if path.find(".lp") is Some(_) {
    return true
  }
  if path.find(".mps") is Some(_) {
    return false
  }
  // No useful extension: an MPS file starts with a NAME line, an LP file starts
  // with a sense keyword. Netlib instances ship without any extension, which is
  // exactly the case this fallback exists for.
  for raw in content.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    match line.find("*") {
      Some(0) => continue
      _ => ()
    }
    let tokens = @format.split_tokens(line)
    if tokens.length() == 0 {
      continue
    }
    return tokens[0].0.to_upper() != "NAME"
  }
  false
}

///|
/// One summary line per file, in a format that is stable enough to diff.
fn report(path : String, model : @model.Model, format_name : String) -> Unit {
  let mut nonzeros = model.objective().length()
  for i = 0; i < model.num_constraints(); i = i + 1 {
    nonzeros = nonzeros + model.constraint(i).terms.length()
  }
  let mut integers = 0
  for j = 0; j < model.num_vars(); j = j + 1 {
    if model.get_var(j).is_int {
      integers = integers + 1
    }
  }
  let sense = if model.sense() == @model.Sense::Maximize {
    "MAX"
  } else {
    "MIN"
  }
  let issues = model.validate()
  let verdict = if issues.length() == 0 {
    "ok"
  } else {
    "warn[" + issues.length().to_string() + "]"
  }
  println(
    "OK   " +
    path +
    "  format=" +
    format_name +
    "  vars=" +
    model.num_vars().to_string() +
    "  cons=" +
    model.num_constraints().to_string() +
    "  nnz=" +
    nonzeros.to_string() +
    "  int=" +
    integers.to_string() +
    "  sense=" +
    sense +
    "  " +
    verdict,
  )
  if issues.length() > 0 {
    println("       first issue: " + issues[0])
  }
}

///|
/// Parses one file and prints the outcome. Returns `true` on success.
fn inspect(path : String) -> Bool {
  let content = match read_text(path) {
    Some(text) => text
    None => return false
  }
  let is_lp = looks_like_lp(path, content)
  let parsed = if is_lp {
    @format.read_lp(content)
  } else {
    @format.parse_mps(content)
  }
  match parsed {
    Ok(model) => {
      report(path, model, if is_lp { "lp" } else { "mps" })
      true
    }
    Err(issue) => {
      println("FAIL " + path + "\n       " + issue.to_text())
      false
    }
  }
}

///|
/// Resolves a manifest entry against the manifest's directory.
fn resolve(manifest_path : String, entry : String) -> String {
  if entry.find(":") is Some(_) {
    return entry
  }
  let separator = if manifest_path.find("/") is Some(_) { "/" } else { "\\" }
  let parent = match manifest_path.rev_find(separator) {
    Some(index) => manifest_path[:index].to_owned()
    None => "."
  }
  parent + separator + entry
}

///|
/// Entry point.
fn main {
  let args = @env.args()
  let files : Array[String] = []
  let mut manifest = ""
  let mut index = 1
  while index < args.length() {
    let argument = args[index]
    if argument == "--manifest" {
      if index + 1 < args.length() {
        manifest = args[index + 1]
        index = index + 2
        continue
      }
      print_usage()
      @sys.exit(2)
    }
    if argument == "--help" || argument == "-h" {
      print_usage()
      @sys.exit(0)
    }
    files.push(argument)
    index = index + 1
  }
  if manifest != "" {
    let content = match read_text(manifest) {
      Some(text) => text
      None => {
        @sys.exit(2)
        ""
      }
    }
    for raw in content.split("\n") {
      let line = raw.trim().to_owned()
      if line == "" {
        continue
      }
      match line.find("#") {
        Some(0) => continue
        _ => ()
      }
      files.push(resolve(manifest, line))
    }
  }
  if files.length() == 0 {
    print_usage()
    @sys.exit(2)
  }
  let mut failures = 0
  for path in files {
    if !inspect(path) {
      failures = failures + 1
    }
  }
  println("")
  println(
    "checked " +
    files.length().to_string() +
    " file(s), failed " +
    failures.to_string(),
  )
  if failures > 0 {
    @sys.exit(1)
  }
}
