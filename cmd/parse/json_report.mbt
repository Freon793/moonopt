///|
/// The machine-readable half of the CLI: the same runs the text path performs, rendered as
/// a JSON document instead of printed lines.
///
/// Two renderers over one set of runs can drift apart, so the rules here are explicit:
///
/// - the text output is not touched. It is what the scripts in `bench/` parse and what the
///   reports in `bench/` were generated from, so changing it would invalidate evidence
///   rather than add anything;
/// - this file performs the *same* library calls with the *same* options, and the option
///   assembly lives here as `kernel_options` / `branch_options` so both paths can call the
///   same one;
/// - what it does not mirror it refuses instead of approximating: `--json` with
///   `--reoptimize` stops with exit 2, because that flag exists to print a measurement and a
///   document without it would be a quieter answer to a different question.
///
/// Numbers are JSON numbers carrying the shortest representation that reads back to the same
/// value — the project's one formatting policy, the same one `@format.format_number` gives
/// model files. Rounding them here would let a consumer's copy of a report disagree with the
/// report.

///|
/// One file's outcome. Mutable on purpose: the run fills the fields it has an answer for and
/// leaves the rest, which is also how the JSON says what happened — a field that was never
/// set is a field that does not appear.
priv struct FileOutcome {
  path : String
  mut format_name : String
  mut parse_ok : Bool
  mut parse_error : String
  mut vars : Int
  mut cons : Int
  mut nonzeros : Int
  mut integers : Int
  mut sense : String
  issues : Int
  first_issue : String
  /// Which run this outcome describes: `parse`, `solve`, `mip` or `verify`.
  mut mode : String
  /// What the run reported, in words. Empty when the run was skipped or refused.
  mut status : String
  mut has_objective : Bool
  mut objective : Double
  mut iterations : Int
  mut nodes : Int
  mut verified : Int
  mut cuts : Int
  mut has_bound : Bool
  mut bound : Double
  mut gap : Double
  mut message : String
  /// The run was skipped because the model is over the row limit.
  mut skipped : Bool
  mut presolved : Bool
  mut presolve_verdict : String
  mut rows_after : Int
  mut vars_after : Int
  /// The point behind the answer was measured against the original model.
  mut point_checked : Bool
  mut row_violation : Double
  mut bound_violation : Double
  mut integrality_violation : Double
  /// `verify`'s verdict, when the certificate path ran.
  mut verified_claim : String
  mut accepted : Bool
  mut verify_reason : String
  /// The run makes the CLI exit non-zero.
  mut failed : Bool
}

///|
/// A fresh outcome for one file, with the parsing facts filled in and nothing run yet.
fn new_outcome(path : String, model : @model.Model) -> FileOutcome {
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
  let issues = model.validate()
  {
    path,
    format_name: "",
    parse_ok: true,
    parse_error: "",
    vars: model.num_vars(),
    cons: model.num_constraints(),
    nonzeros,
    integers,
    sense: if model.sense() == @model.Sense::Maximize {
      "MAX"
    } else {
      "MIN"
    },
    issues: issues.length(),
    first_issue: if issues.length() > 0 {
      issues[0]
    } else {
      ""
    },
    mode: "parse",
    status: "",
    has_objective: false,
    objective: 0.0,
    iterations: 0,
    nodes: 0,
    verified: 0,
    cuts: 0,
    has_bound: false,
    bound: 0.0,
    gap: 0.0,
    message: "",
    skipped: false,
    presolved: false,
    presolve_verdict: "",
    rows_after: 0,
    vars_after: 0,
    point_checked: false,
    row_violation: 0.0,
    bound_violation: 0.0,
    integrality_violation: 0.0,
    verified_claim: "",
    accepted: false,
    verify_reason: "",
    failed: false,
  }
}

///|
/// A fresh outcome for a file that could not be parsed or read.
fn unusable_outcome(path : String, reason : String) -> FileOutcome {
  let outcome = new_outcome(path, @model.Model::new(@model.Sense::Minimize))
  outcome.parse_ok = false
  outcome.parse_error = reason
  outcome.vars = 0
  outcome.cons = 0
  outcome.nonzeros = 0
  outcome.integers = 0
  outcome.sense = ""
  outcome.failed = true
  outcome
}

///|
/// The kernel options the CLI uses, assembled in one place so the text path and the JSON
/// path cannot come to different tolerances or iteration caps.
fn kernel_options(flags : SolveFlags) -> @simplex.SimplexOptions {
  let base = if flags.relax {
    @simplex.SimplexOptions::relaxed()
  } else {
    @simplex.SimplexOptions::default()
  }
  base.limit_iterations(
    if flags.max_iterations > 0 {
      flags.max_iterations
    } else {
      20000
    },
  )
}

///|
/// The branch and bound options, built from the library's own defaults the way the text path
/// builds them: a CLI that spelled its own budgets would be a second set to keep in step.
fn branch_options(flags : SolveFlags) -> @mip.MipOptions {
  let base = @mip.MipOptions::default()
  {
    max_nodes: if flags.max_nodes > 0 {
      flags.max_nodes
    } else {
      20000
    },
    max_iterations: if flags.max_iterations > 0 {
      flags.max_iterations
    } else {
      20000
    },
    tolerance: base.tolerance,
    verify_nodes: base.verify_nodes,
    dive_steps: base.dive_steps,
    dive_attempts: base.dive_attempts,
    cut_rounds: if flags.cut_rounds >= 0 {
      flags.cut_rounds
    } else {
      base.cut_rounds
    },
    primal_rounding: base.primal_rounding,
    node_solver: base.node_solver,
    cut_hook: base.cut_hook,
  }
}

///|
/// The presolve verdict as a word, for the JSON document.
fn presolve_verdict_name(verdict : @presolve.PresolveVerdict) -> String {
  match verdict {
    @presolve.PresolveVerdict::Reduced => "reduced"
    @presolve.PresolveVerdict::Infeasible => "infeasible"
    @presolve.PresolveVerdict::Unbounded => "unbounded"
  }
}

///|
/// Joins the parts of a JSON object or array.
fn join_parts(parts : Array[String], separator : String) -> String {
  let mut text = ""
  for i = 0; i < parts.length(); i = i + 1 {
    if i > 0 {
      text = text + separator
    }
    text = text + parts[i]
  }
  text
}

///|
/// A string as a JSON string literal.
fn json_text(text : String) -> String {
  let mut out = "\""
  for character in text {
    match character {
      '"' => out = out + "\\\""
      '\\' => out = out + "\\\\"
      '\n' => out = out + "\\n"
      '\r' => out = out + "\\r"
      '\t' => out = out + "\\t"
      _ => out = out + character.to_string()
    }
  }
  out + "\""
}

///|
/// A number as a JSON number: the shortest representation that reads back to the same value.
///
/// The library's sentinels (`1e+300` for "no finite gap") are finite JSON numbers, so they
/// travel as they are; a consumer that wants "unknown" reads the status, which is the field
/// that carries it.
fn json_number(value : Double) -> String {
  value.to_string()
}

///|
/// A `"name": value` pair.
fn json_field(name : String, value : String) -> String {
  json_text(name) + ": " + value
}

///|
/// One file's outcome as a JSON object. Fields the run never set are left out rather than
/// filled with a default: a document that says "no status" is one a consumer cannot
/// misread, and a zero would be a number it could.
fn FileOutcome::to_json(self : FileOutcome) -> String {
  let parts : Array[String] = []
  parts.push(json_field("path", json_text(self.path)))
  parts.push(json_field("parsed", if self.parse_ok { "true" } else { "false" }))
  if !self.parse_ok {
    parts.push(json_field("error", json_text(self.parse_error)))
    parts.push(json_field("failed", "true"))
    return "{" + join_parts(parts, ",") + "}"
  }
  parts.push(json_field("format", json_text(self.format_name)))
  parts.push(json_field("vars", self.vars.to_string()))
  parts.push(json_field("constraints", self.cons.to_string()))
  parts.push(json_field("nonzeros", self.nonzeros.to_string()))
  parts.push(json_field("integer_vars", self.integers.to_string()))
  parts.push(json_field("sense", json_text(self.sense)))
  parts.push(json_field("validation_issues", self.issues.to_string()))
  if self.issues > 0 {
    parts.push(json_field("first_issue", json_text(self.first_issue)))
  }
  parts.push(json_field("mode", json_text(self.mode)))
  if self.skipped {
    parts.push(json_field("status", json_text("skipped")))
    parts.push(json_field("skipped", "true"))
  } else if self.mode != "parse" {
    parts.push(json_field("status", json_text(self.status)))
    if self.has_objective {
      parts.push(json_field("objective", json_number(self.objective)))
    }
    if self.mode == "solve" {
      parts.push(json_field("iterations", self.iterations.to_string()))
      if self.presolved {
        parts.push(json_field("presolved", "true"))
        parts.push(
          json_field("presolve_verdict", json_text(self.presolve_verdict)),
        )
        parts.push(
          json_field("rows_after_presolve", self.rows_after.to_string()),
        )
        parts.push(
          json_field("vars_after_presolve", self.vars_after.to_string()),
        )
      }
    }
    if self.mode == "mip" {
      parts.push(json_field("nodes", self.nodes.to_string()))
      parts.push(json_field("verified", self.verified.to_string()))
      parts.push(json_field("cuts", self.cuts.to_string()))
      if self.has_bound {
        parts.push(json_field("bound", json_number(self.bound)))
        parts.push(json_field("gap", json_number(self.gap)))
      }
    }
    if self.mode == "verify" {
      parts.push(json_field("claim", json_text(self.verified_claim)))
      parts.push(
        json_field("accepted", if self.accepted { "true" } else { "false" }),
      )
      if self.verify_reason != "" {
        parts.push(json_field("reason", json_text(self.verify_reason)))
      }
    }
    if self.message != "" {
      parts.push(json_field("message", json_text(self.message)))
    }
  }
  if self.point_checked {
    let point : Array[String] = []
    point.push(json_field("row_violation", json_number(self.row_violation)))
    point.push(json_field("bound_violation", json_number(self.bound_violation)))
    point.push(
      json_field(
        "integrality_violation",
        json_number(self.integrality_violation),
      ),
    )
    parts.push(json_text("point") + ": {" + join_parts(point, ",") + "}")
  }
  parts.push(json_field("failed", if self.failed { "true" } else { "false" }))
  "{" + join_parts(parts, ",") + "}"
}

///|
/// One file, inspected and run exactly as the text path would, with the outcome kept instead
/// of printed.
///
/// Nothing on this path prints: a line from a helper would land in the middle of the JSON
/// document, which is how `mip <file> --json` first came out unparseable. Failures are
/// reported in the document instead.
fn json_inspect(
  path : String,
  flags : SolveFlags,
  mode : String,
) -> FileOutcome {
  let content = match read_text_quiet(path) {
    Some(text) => text
    None => return unusable_outcome(path, "cannot read the file")
  }
  let is_lp = looks_like_lp(path, content)
  let format_name = if is_lp { "lp" } else { "mps" }
  let parsed = if is_lp {
    @format.read_lp(content)
  } else {
    @format.parse_mps(content)
  }
  let model = match parsed {
    Ok(model) => model
    Err(issue) => {
      let outcome = unusable_outcome(path, issue.to_text())
      outcome.format_name = format_name
      return outcome
    }
  }
  let outcome = new_outcome(path, model)
  outcome.format_name = format_name
  if mode == "parse" {
    return outcome
  }
  if mode == "mip" {
    run_mip(model, outcome, flags)
  } else if mode == "verify" {
    run_verify(model, outcome, flags)
  } else {
    run_solve(model, outcome, flags)
  }
  outcome
}

///|
/// The branch and bound run, with the point behind the answer measured against the model.
fn run_mip(
  model : @model.Model,
  outcome : FileOutcome,
  flags : SolveFlags,
) -> Unit {
  outcome.mode = "mip"
  if model.num_constraints() > flags.max_rows {
    outcome.skipped = true
    return
  }
  let result = @mip.solve_mip(model, branch_options(flags))
  let tolerance = 1.0e-7
  outcome.status = mip_status_name(result.status)
  outcome.has_objective = result.values.length() > 0
  outcome.objective = result.objective
  outcome.nodes = result.nodes
  outcome.verified = result.verified
  outcome.cuts = result.cuts
  outcome.has_bound = result.status == @mip.MipStatus::NodeLimit
  outcome.bound = result.bound
  outcome.gap = result.gap
  outcome.message = result.message
  // A refused certificate is a failure of the run, not of the file, exactly as on the text
  // path: the exit code has to say so.
  outcome.failed = result.status == @mip.MipStatus::Unverified
  if result.values.length() > 0 {
    let rows = @presolve.max_row_violation(model, result.values)
    let bounds = @presolve.max_bound_violation(model, result.values)
    let integrality = max_integrality_violation(model, result.values)
    outcome.point_checked = true
    outcome.row_violation = rows
    outcome.bound_violation = bounds
    outcome.integrality_violation = integrality
    if !(rows <= tolerance && bounds <= tolerance && integrality <= tolerance) {
      outcome.failed = true
    }
  }
}

///|
/// The linear run: the model as written, or the reduction followed by the reconstruction
/// check the text path prints.
fn run_solve(
  model : @model.Model,
  outcome : FileOutcome,
  flags : SolveFlags,
) -> Unit {
  outcome.mode = "solve"
  if model.num_constraints() > flags.max_rows {
    outcome.skipped = true
    return
  }
  let options = kernel_options(flags)
  if !flags.presolve {
    let result = match @simplex.solve_model_with(model, options) {
      Err(reason) => {
        // A model the kernel does not accept is not a failed run: the text path reports the
        // refusal and still exits zero, and failing here would make "not in the kernel's
        // model class" look like a crash.
        outcome.status = "refused"
        outcome.message = reason
        return
      }
      Ok(result) => result
    }
    with_solve_result(outcome, result)
    return
  }
  let presolved = @presolve.presolve(model)
  outcome.presolved = true
  outcome.presolve_verdict = presolve_verdict_name(presolved.verdict())
  match presolved.verdict() {
    @presolve.PresolveVerdict::Infeasible => {
      outcome.status = "infeasible"
      outcome.message = "from presolve: " + presolved.reason()
    }
    @presolve.PresolveVerdict::Unbounded => {
      outcome.status = "unbounded"
      outcome.message = "from presolve: " + presolved.reason()
    }
    @presolve.PresolveVerdict::Reduced => {
      let reduced = presolved.reduced()
      outcome.rows_after = reduced.num_constraints()
      outcome.vars_after = reduced.num_vars()
      if reduced.num_vars() == 0 {
        // Everything was eliminated; the reduction's own answer is the answer.
        outcome.status = "optimal"
        outcome.has_objective = true
        outcome.objective = presolved.objective(0.0)
        outcome.message = "presolve eliminated every variable"
        return
      }
      let result = match @simplex.solve_model_with(reduced, options) {
        Err(reason) => {
          outcome.status = "refused"
          outcome.message = reason
          return
        }
        Ok(result) => result
      }
      with_solve_result(outcome, result)
      outcome.objective = presolved.objective(result.objective)
      if result.status != @simplex.SimplexStatus::Optimal {
        return
      }
      // The reduced solve and the original model have to agree on the objective too: the
      // offset is easy to get wrong, and a wrong offset leaves a solution that is perfectly
      // feasible while the reported number is not the objective of anything.
      let values = presolved.reconstruct(result.values)
      let rows = @presolve.max_row_violation(model, values)
      let bounds = @presolve.max_bound_violation(model, values)
      let reported = presolved.objective(result.objective)
      let recomputed = @presolve.objective_value(model, values)
      let agrees = @core.approx_eq(reported, recomputed, rel=1.0e-9, abs=1.0e-6)
      outcome.point_checked = true
      outcome.row_violation = rows
      outcome.bound_violation = bounds
      outcome.message = if agrees {
        "the reconstructed objective agrees with the reported one"
      } else {
        "the reconstructed objective DISAGREES with the reported one"
      }
      if !(rows <= 1.0e-7 && bounds <= 1.0e-7 && agrees) {
        outcome.failed = true
      }
    }
  }
}

///|
/// Copies a kernel run's outcome into the file's record.
fn with_solve_result(
  outcome : FileOutcome,
  result : @simplex.SimplexResult,
) -> Unit {
  outcome.status = status_name(result.status)
  outcome.iterations = result.iterations
  if result.status == @simplex.SimplexStatus::Optimal {
    outcome.has_objective = true
    outcome.objective = result.objective
  }
}

///|
/// The certificate path: check a certificate read from a file, or solve and check what the
/// kernel produced, exactly as the text path does.
fn run_verify(
  model : @model.Model,
  outcome : FileOutcome,
  flags : SolveFlags,
) -> Unit {
  outcome.mode = "verify"
  let certificate = if flags.certificate_path != "" {
    match read_certificate_quiet(flags.certificate_path) {
      Some(value) => value
      None => {
        outcome.status = "certificate-unreadable"
        outcome.message = flags.certificate_path
        outcome.failed = true
        return
      }
    }
  } else {
    let result = match @simplex.solve_model_with(model, kernel_options(flags)) {
      Err(reason) => {
        outcome.status = "refused"
        outcome.message = reason
        return
      }
      Ok(result) => result
    }
    with_solve_result(outcome, result)
    certificate_of(result)
  }
  let verdict = @verify.verify(model, certificate)
  outcome.verified_claim = claim_word(verdict.claim)
  outcome.accepted = verdict.accepted
  outcome.verify_reason = verdict.reason
  outcome.failed = !verdict.accepted
}

///|
/// The claim a verdict is about, as a word.
fn claim_word(claim : @verify.Claim) -> String {
  match claim {
    @verify.Claim::Optimal => "optimal"
    @verify.Claim::Infeasible => "infeasible"
    @verify.Claim::Unbounded => "unbounded"
  }
}

///|
/// Reads a text file without printing anything, for the paths that must not put a line in
/// the middle of their output.
fn read_text_quiet(path : String) -> String? {
  try @fs.read_file_to_string(path) catch {
    @fs.IOError(_) => None
  } noraise {
    content => Some(content)
  }
}

///|
/// Reads a certificate without printing: the JSON path reports a failure in the document
/// instead of on the terminal.
fn read_certificate_quiet(path : String) -> @verify.Certificate? {
  match read_text_quiet(path) {
    None => None
    Some(text) => @verify.Certificate::from_json(text)
  }
}

///|
/// Reads a model the way `inspect` does, for the `fmt` verb: the same readers, the same
/// format decision.
fn load_model(path : String) -> Result[(@model.Model, String), String] {
  let content = match read_text_quiet(path) {
    Some(text) => text
    None => return Err("cannot read the file")
  }
  let is_lp = looks_like_lp(path, content)
  let format_name = if is_lp { "lp" } else { "mps" }
  let parsed = if is_lp {
    @format.read_lp(content)
  } else {
    @format.parse_mps(content)
  }
  match parsed {
    Ok(model) => Ok((model, format_name))
    Err(issue) => Err(issue.to_text())
  }
}

///|
/// The whole run as one JSON document: the tool, the command, one object per file, and the
/// summary the exit code is made of.
fn document_json(
  command : String,
  outcomes : Array[FileOutcome],
  failures : Int,
) -> String {
  let files : Array[String] = []
  for outcome in outcomes {
    files.push(outcome.to_json())
  }
  let summary : Array[String] = []
  summary.push(json_field("files", outcomes.length().to_string()))
  summary.push(json_field("failed", failures.to_string()))
  "{" +
  join_parts(
    [
      json_field("tool", json_text("moonopt")),
      json_field("command", json_text(command)),
      json_text("files") + ": [" + join_parts(files, ",") + "]",
      json_text("summary") + ": {" + join_parts(summary, ",") + "}",
    ],
    ",",
  ) +
  "}"
}

///|
/// Writes a model back out: the `fmt` verb.
///
/// The reader decides the format unless `--format` overrides it, and the writer is the
/// library's own, so `fmt` is a round trip through the same code a caller would use rather
/// than a second formatter written for the CLI.
///
/// Without `-o` the formatted model is what is printed and nothing is written, which is what
/// makes the verb pipeable — and, more to the point, it means a bare `fmt <file>` cannot
/// rewrite a file in place, which is the one way this verb could lose work. With `-o` the
/// output goes to that path, and exactly one input is allowed because one output path cannot
/// hold two models. Returns the number of failures.
fn run_fmt(
  files : Array[String],
  format_wanted : String,
  output_path : String,
) -> Int {
  if output_path != "" && files.length() > 1 {
    println(
      "fmt: -o takes one input file, " + files.length().to_string() + " given",
    )
    return files.length()
  }
  let mut failures = 0
  for path in files {
    let (model, read_format) = match load_model(path) {
      Err(reason) => {
        println("FAIL " + path + "\n       " + reason)
        failures = failures + 1
        continue
      }
      Ok(pair) => pair
    }
    let target = if format_wanted != "" { format_wanted } else { read_format }
    let text = if target == "lp" {
      @format.write_lp(model)
    } else if target == "mps" {
      @format.write_mps(model)
    } else {
      println(
        "FAIL " + path + "\n       unknown format '" + target + "' (mps or lp)",
      )
      failures = failures + 1
      continue
    }
    if output_path == "" {
      // The writer's text is the whole point of the verb without `-o`: it goes to stdout and
      // nothing else is printed, so a caller can redirect or pipe it.
      println(text)
      continue
    }
    try @fs.write_string_to_file(output_path, text) catch {
      @fs.IOError(message) => {
        println("cannot write " + output_path + ": " + message)
        failures = failures + 1
        continue
      }
    } noraise {
      _ => ()
    }
    println("wrote " + output_path + " (" + target + ")")
  }
  failures
}
