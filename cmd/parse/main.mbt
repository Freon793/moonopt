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
/// moon run cmd/parse -- <file> --solve --max-rows 300
/// moon run cmd/parse -- <file> --presolve --relax
/// moon run cmd/parse -- <file> --mip --max-nodes 5000
/// ```
///
/// A manifest is a text file with one path per line; `#` starts a comment. The
/// paths inside it are resolved relative to the manifest's own directory, which
/// is what makes the checked-in manifest usable from any working directory.
///
/// `--presolve` reduces the model before the kernel sees it and prints what the
/// reduction did, followed by the reconstructed solution's violations against the
/// original rows — the reduction is only useful if the way back is correct.
///
/// `--verify` runs the same solve and then has the independent verifier check the
/// certificate the kernel produced: primal feasibility, the multipliers' signs and
/// dual feasibility, complementary slackness, and the duality gap. It prints the
/// certificate as JSON too, so the check can be repeated somewhere else with
/// `--certificate`, which reads a certificate from a file and checks it without
/// solving anything. A refuted certificate exits non-zero.
///
/// `--mip` solves a model with integer variables by branch and bound instead of
/// reporting a single relaxation: every node's relaxation is verified, and only an
/// exhausted tree is called optimal. `--max-nodes` bounds the search, and a run that
/// stops at that bound prints the incumbent together with the bound still open.

///|
/// Prints the usage line.
fn print_usage() -> Unit {
  println("usage: moon run cmd/parse -- <file> [<file> ...]")
  println("       moon run cmd/parse -- --manifest <list-file>")
  println("       moon run cmd/parse -- <file> --verify")
  println("       moon run cmd/parse -- <file> --mip [--max-nodes <n>]")
  println(
    "       moon run cmd/parse -- <file> --certificate <certificate.json>",
  )
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
/// Flags that decide whether the kernel is run on a parsed model.
pub(all) struct SolveFlags {
  enabled : Bool
  relax : Bool
  presolve : Bool
  max_rows : Int
  /// Zero means the kernel's own default; anything else bounds the run so a large
  /// instance can be sampled instead of waited on.
  max_iterations : Int
  /// Check the run's certificate with the independent verifier instead of only
  /// reporting the status.
  verify : Bool
  /// Path of a certificate to read and check against the model, without solving.
  /// Empty means there is none.
  certificate_path : String
  /// Solve, tighten one bound, and reoptimize from the basis the first solve left
  /// behind — the measurement behind "a warm start is cheaper".
  reoptimize : Bool
  /// Branch and bound instead of a single relaxation: for a model with integer
  /// variables the linear kernel's answer is not the model's answer.
  mip : Bool
  /// Node budget for a branch and bound run; zero means the library default.
  max_nodes : Int
}

///|
/// Turns a kernel result into the certificate `verify` reads.
fn certificate_of(result : @simplex.SimplexResult) -> @verify.Certificate {
  let claim = match result.status {
    @simplex.SimplexStatus::Optimal => @verify.Claim::Optimal
    @simplex.SimplexStatus::Infeasible => @verify.Claim::Infeasible
    @simplex.SimplexStatus::Unbounded => @verify.Claim::Unbounded
    _ => @verify.Claim::Optimal
  }
  {
    claim,
    values: result.values,
    duals: result.duals,
    ray: result.ray,
    objective: result.objective,
  }
}

///|
/// Reads a certificate from a file, or reports why it could not.
fn read_certificate(path : String) -> @verify.Certificate? {
  let content = match read_text(path) {
    Some(text) => text
    None => return None
  }
  match @verify.Certificate::from_json(content) {
    Some(certificate) => Some(certificate)
    None => {
      println("       certificate=unreadable(" + path + ")")
      None
    }
  }
}

///|
/// Checks a certificate against the model, printing the verifier's own measurements.
///
/// Returns `true` when it was accepted. This is the point of a certificate: the status
/// a solver reports is a claim, and this prints the measurement that decides it.
fn verify_and_report(
  model : @model.Model,
  certificate : @verify.Certificate,
) -> Bool {
  let verdict = @verify.verify(model, certificate)
  println(
    "       verify=" +
    (if verdict.accepted { "accepted" } else { "REJECTED" }) +
    (if verdict.reason == "" { "" } else { " (" + verdict.reason + ")" }),
  )
  for item in verdict.checks {
    println(
      "         " +
      (if item.ok { "ok  " } else { "FAIL" }) +
      " " +
      item.name +
      " = " +
      item.measured.to_string() +
      (if item.tolerance > 0.0 {
        " (tolerance " + item.tolerance.to_string() + ")"
      } else {
        ""
      }),
    )
  }
  verdict.accepted
}

///|
/// The certificate path of one model: check a certificate read from a file, or solve
/// and check what the kernel produced.
///
/// A certificate belongs to the model it was stated against, so this path does not
/// presolve: a reduced model's multipliers are not the original model's, and checking
/// one against the other would be a comparison of two different problems.
fn verify_model(model : @model.Model, flags : SolveFlags) -> Bool {
  if flags.certificate_path != "" {
    let certificate = match read_certificate(flags.certificate_path) {
      Some(value) => value
      None => return false
    }
    return verify_and_report(model, certificate)
  }
  let options = (if flags.relax {
    @simplex.SimplexOptions::relaxed()
  } else {
    @simplex.SimplexOptions::default()
  }).limit_iterations(
    if flags.max_iterations > 0 {
      flags.max_iterations
    } else {
      20000
    },
  )
  let result = match @simplex.solve_model_with(model, options) {
    Err(reason) => {
      println("       solve=refused(" + reason + ")")
      return false
    }
    Ok(result) => result
  }
  report_solve_result(result)
  match result.status {
    @simplex.SimplexStatus::Optimal
    | @simplex.SimplexStatus::Infeasible
    | @simplex.SimplexStatus::Unbounded => {
      let certificate = certificate_of(result)
      println("       certificate=" + certificate.to_json())
      verify_and_report(model, certificate)
    }
    _ => {
      // Nothing to prove: the run reached no verdict, so there is no certificate to
      // check, and saying so is the honest output.
      println("       certificate=none(the run did not reach a verdict)")
      false
    }
  }
}

///|
/// Describes what the reduction did, in one line, so a benchmark run shows the
/// effect per instance instead of only the final answer.
fn presolve_line(before_rows : Int, reduced : @presolve.ReducedModel) -> String {
  let stats = reduced.stats()
  "       presolve: rows " +
  before_rows.to_string() +
  " -> " +
  reduced.reduced().num_constraints().to_string() +
  ", vars " +
  reduced.num_original_vars().to_string() +
  " -> " +
  reduced.reduced().num_vars().to_string() +
  " (empty=" +
  stats.rows_removed_empty.to_string() +
  " redundant=" +
  stats.rows_removed_redundant.to_string() +
  " singleton=" +
  stats.rows_removed_singleton.to_string() +
  " tightened=" +
  stats.bounds_tightened.to_string() +
  " fixed=" +
  stats.variables_fixed.to_string() +
  " empty-cols=" +
  stats.columns_removed_empty.to_string() +
  " rounds=" +
  stats.rounds.to_string() +
  ")"
}

///|
/// Prints the kernel's outcome for a solved problem.
///
/// The objective is printed only when the run actually produced one. Every other
/// status returns an empty solution and a zero objective, and a zero is not a
/// measurement — for a presolved run the honest-looking number was the reduction's
/// own objective offset, so a Phase I that was converging at 0.8 units per pivot
/// was read as "stuck at 13" for a whole round of work. An unmeasured field is
/// printed as `-`.
fn report_solve_result(result : @simplex.SimplexResult) -> Unit {
  let status = match result.status {
    @simplex.SimplexStatus::Optimal => "optimal"
    @simplex.SimplexStatus::Infeasible => "infeasible"
    @simplex.SimplexStatus::Unbounded => "unbounded"
    @simplex.SimplexStatus::IterationLimit => "iteration-limit"
    @simplex.SimplexStatus::NumericalFailure => "numerical-failure"
    @simplex.SimplexStatus::TooLarge => "too-large"
  }
  println(
    "       solve=" +
    status +
    " obj=" +
    (if result.status == @simplex.SimplexStatus::Optimal {
      result.objective.to_string()
    } else {
      "-"
    }) +
    " iters=" +
    result.iterations.to_string() +
    (if result.message == "" { "" } else { " (" + result.message + ")" }),
  )
}

///|
/// Same line, with the objective restated in the original model's sense.
///
/// A presolved run optimises the *reduced* model, so its own objective is missing
/// the eliminated variables' contribution. Printing that number next to results
/// from unreduced runs made a 162 000 difference on flugpl look like a wrong
/// answer when it was only a wrong label; the reduction was right and the
/// reconstruction check now proves it every time.
///
/// The mapping is only applied to a run that solved the reduced model. A failed run
/// has no objective to map, and `ReducedModel::objective(0.0)` would hand back the
/// reduction's own offset dressed up as a result — which is exactly how fast0507's
/// Phase I came to be reported as "13" at 500, 1200 and 4000 iterations.
fn report_solve_result_scaled(
  result : @simplex.SimplexResult,
  presolved : @presolve.ReducedModel,
) -> Unit {
  let status = match result.status {
    @simplex.SimplexStatus::Optimal => "optimal"
    @simplex.SimplexStatus::Infeasible => "infeasible"
    @simplex.SimplexStatus::Unbounded => "unbounded"
    @simplex.SimplexStatus::IterationLimit => "iteration-limit"
    @simplex.SimplexStatus::NumericalFailure => "numerical-failure"
    @simplex.SimplexStatus::TooLarge => "too-large"
  }
  println(
    "       solve=" +
    status +
    " obj=" +
    (if result.status == @simplex.SimplexStatus::Optimal {
      presolved.objective(result.objective).to_string()
    } else {
      "-"
    }) +
    " iters=" +
    result.iterations.to_string() +
    (if result.message == "" { "" } else { " (" + result.message + ")" }),
  )
}

///|
/// Status as text, so the report lines read the same for every status.
fn status_name(status : @simplex.SimplexStatus) -> String {
  match status {
    @simplex.SimplexStatus::Optimal => "optimal"
    @simplex.SimplexStatus::Infeasible => "infeasible"
    @simplex.SimplexStatus::Unbounded => "unbounded"
    @simplex.SimplexStatus::IterationLimit => "iteration-limit"
    @simplex.SimplexStatus::NumericalFailure => "numerical-failure"
    @simplex.SimplexStatus::TooLarge => "too-large"
  }
}

///|
/// Solves the model, tightens one bound, and solves again twice: once from the basis
/// the first solve left behind, once from scratch. Prints both runs' pivot counts.
///
/// This exists because "a warm start is cheaper" is a claim, and the way to keep such a
/// claim honest is to measure it on real instances instead of assuming it. The shape of
/// the run is also the shape reoptimization takes inside a branch and bound tree: a
/// bound changes and the same model is solved again.
fn reoptimize_report(model : @model.Model, flags : SolveFlags) -> Bool {
  let options = (if flags.relax {
    @simplex.SimplexOptions::relaxed()
  } else {
    @simplex.SimplexOptions::default()
  }).limit_iterations(
    if flags.max_iterations > 0 {
      flags.max_iterations
    } else {
      20000
    },
  )
  let first = match @simplex.solve_model_with(model, options) {
    Err(reason) => {
      println("       solve=refused(" + reason + ")")
      return false
    }
    Ok(result) => result
  }
  println(
    "       cold1=" +
    status_name(first.status) +
    " iters=" +
    first.iterations.to_string(),
  )
  let basis = match first.basis {
    Some(value) => value
    None => {
      println(
        "       reoptimize=no(the first run reached no verdict, so it has no basis)",
      )
      return false
    }
  }
  // Tighten a bound the optimum actually uses, which is the change a branch makes: a
  // bound that the solution already respects would leave the basis optimal and the
  // measurement would say nothing about reoptimizing.
  let mut changed = -1
  let mut binding = false
  for j = 0; j < model.num_vars() && j < first.values.length(); j = j + 1 {
    let variable = model.get_var(j)
    if variable.ub < 1.0e29 {
      let lowered = variable.lb + (variable.ub - variable.lb) * 0.5
      if lowered > variable.lb && first.values[j] > lowered + 1.0e-7 {
        model.set_var_bounds(j, variable.lb, lowered)
        changed = j
        binding = true
        break
      }
    }
  }
  if changed < 0 {
    // Nothing the optimum uses has a bound to halve, so take any finite bound and say
    // so: the run is still a reoptimization, it just is not a binding change.
    for j = 0; j < model.num_vars(); j = j + 1 {
      let variable = model.get_var(j)
      if variable.ub < 1.0e29 {
        let lowered = variable.lb + (variable.ub - variable.lb) * 0.5
        if lowered > variable.lb {
          model.set_var_bounds(j, variable.lb, lowered)
          changed = j
          break
        }
      }
    }
  }
  if changed < 0 && model.num_vars() > 0 {
    let variable = model.get_var(0)
    if variable.lb <= 1.0 {
      model.set_var_bounds(0, variable.lb, 1.0)
      changed = 0
    }
  }
  if changed < 0 {
    println("       reoptimize=no(there is no bound to tighten)")
    return false
  }
  println(
    "       tightened: variable " +
    changed.to_string() +
    (if binding { " (binding: the optimum used it)" } else { " (not binding)" }),
  )
  let warm = match @simplex.solve_model_with_basis(model, options, basis) {
    Ok(result) => result
    Err(reason) => {
      println("       warm=refused(" + reason + ")")
      return false
    }
  }
  let cold = match @simplex.solve_model_with(model, options) {
    Ok(result) => result
    Err(reason) => {
      println("       cold2=refused(" + reason + ")")
      return false
    }
  }
  let agrees = warm.status == cold.status &&
    @core.approx_eq(warm.objective, cold.objective, rel=1.0e-7, abs=1.0e-7)
  let warm_verdict = @verify.verify(model, certificate_of(warm))
  let cold_verdict = @verify.verify(model, certificate_of(cold))
  println(
    "       warm=" +
    status_name(warm.status) +
    " iters=" +
    warm.iterations.to_string() +
    " verify=" +
    (if warm_verdict.accepted {
      "accepted"
    } else {
      "REJECTED(" + warm_verdict.reason + ")"
    }) +
    " | cold2=" +
    status_name(cold.status) +
    " iters=" +
    cold.iterations.to_string() +
    " verify=" +
    (if cold_verdict.accepted {
      "accepted"
    } else {
      "REJECTED(" + cold_verdict.reason + ")"
    }) +
    (if agrees {
      " (agree)"
    } else {
      " (DISAGREE: obj " +
      warm.objective.to_string() +
      " vs " +
      cold.objective.to_string() +
      ")"
    }),
  )
  agrees
}

///|
/// Solves a parsed model and prints the outcome.
///
/// The row limit is explicit because no one wants to start a run that cannot
/// finish: the basis is factored sparsely now, so the kernel would not run out of
/// memory, but a model far beyond what this kernel has been exercised on would
/// spend its time in Phase I instead of answering. Instances over the limit are
/// reported as skipped, not as failures.
///
/// With `--presolve` the reduction runs first, and the reconstructed solution is
/// checked against the *original* rows before the outcome is printed. A reduction
/// that is wrong is worse than no reduction, so the check is part of the report
/// rather than something the caller has to remember to do.
fn solve_and_report(model : @model.Model, flags : SolveFlags) -> Bool {
  if flags.verify {
    return verify_model(model, flags)
  }
  if flags.mip {
    return mip_report(model, flags)
  }
  if flags.reoptimize {
    return reoptimize_report(model, flags)
  }
  report_solution(model, flags)
  true
}

///|
/// Status as text, so the branch and bound report reads the same way the kernel's does.
fn mip_status_name(status : @mip.MipStatus) -> String {
  match status {
    @mip.MipStatus::Optimal => "optimal"
    @mip.MipStatus::Infeasible => "infeasible"
    @mip.MipStatus::NodeLimit => "node-limit"
    @mip.MipStatus::UnboundedRelaxation => "unbounded-relaxation"
    @mip.MipStatus::Unverified => "unverified"
    @mip.MipStatus::Invalid => "invalid"
  }
}

///|
/// The largest distance between an integer variable's value and a whole number. Written
/// here rather than taken from the search so the report is not the search marking its own
/// homework.
fn max_integrality_violation(
  model : @model.Model,
  values : Array[Double],
) -> Double {
  let mut worst = 0.0
  for j = 0; j < model.num_vars() && j < values.length(); j = j + 1 {
    if !model.get_var(j).is_int {
      continue
    }
    let value = values[j]
    let truncated = Double::from_int(value.to_int())
    let mut nearest = truncated
    if value - truncated >= 0.5 {
      nearest = truncated + 1.0
    } else if truncated - value >= 0.5 {
      nearest = truncated - 1.0
    }
    let distance = @core.fabs(value - nearest)
    if distance > worst {
      worst = distance
    }
  }
  worst
}

///|
/// The branch and bound path: solve a model with integer variables and report what the
/// search proved.
///
/// Only `optimal` claims an answer, and it is only reached when the tree is exhausted or
/// every open node's bound is closed against the incumbent; anything else prints the
/// incumbent it has together with the bound still open. The point behind an answer is
/// checked against the original rows and bounds by the presolve package's own routines,
/// plus an integrality count written for this report, so the line says "checked" rather
/// than "believed". Presolve is deliberately not applied to an integer model here: the
/// search's own certificates are stated against the model it was handed, and reducing
/// that model would leave the two describing different problems.
fn mip_report(model : @model.Model, flags : SolveFlags) -> Bool {
  if model.num_constraints() > flags.max_rows {
    println(
      "       mip=skipped(rows=" +
      model.num_constraints().to_string() +
      " > " +
      flags.max_rows.to_string() +
      ")",
    )
    return true
  }
  if flags.presolve {
    println(
      "       mip=presolve-skipped(an integer model goes to the kernel as it is)",
    )
  }
  let options : @mip.MipOptions = {
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
    tolerance: 1.0e-7,
    verify_nodes: true,
    node_solver: None,
  }
  let result = @mip.solve_mip(model, options)
  let mut line = "       mip=" +
    mip_status_name(result.status) +
    " nodes=" +
    result.nodes.to_string() +
    " verified=" +
    result.verified.to_string()
  if result.values.length() > 0 {
    line = line + " obj=" + result.objective.to_string()
  }
  if result.status == @mip.MipStatus::NodeLimit {
    line = line +
      " bound=" +
      result.bound.to_string() +
      " gap=" +
      result.gap.to_string()
  }
  if result.message != "" {
    line = line + " (" + result.message + ")"
  }
  println(line)
  let tolerance = 1.0e-7
  if result.values.length() > 0 {
    let rows = @presolve.max_row_violation(model, result.values)
    let bounds = @presolve.max_bound_violation(model, result.values)
    let integrality = max_integrality_violation(model, result.values)
    let ok = rows <= tolerance &&
      bounds <= tolerance &&
      integrality <= tolerance
    println(
      "       point: worst row violation " +
      rows.to_string() +
      ", worst bound violation " +
      bounds.to_string() +
      ", worst integrality violation " +
      integrality.to_string() +
      (if ok {
        " (feasible and whole)"
      } else {
        " (FAILED: the reported point is not an integer point of the model)"
      }),
    )
    if !ok {
      return false
    }
  }
  // A refused certificate is a failure of the run, not of the file: the exit code has to
  // say so, exactly as it does on the single relaxation path.
  result.status != @mip.MipStatus::Unverified
}

///|
/// The plain solve path: report the kernel's outcome, with the reduction in front of
/// it when `--presolve` is on.
fn report_solution(model : @model.Model, flags : SolveFlags) -> Unit {
  if model.num_constraints() > flags.max_rows {
    println(
      "       solve=skipped(rows=" +
      model.num_constraints().to_string() +
      " > " +
      flags.max_rows.to_string() +
      ")",
    )
    return
  }
  let options = (if flags.relax {
    @simplex.SimplexOptions::relaxed()
  } else {
    @simplex.SimplexOptions::default()
  }).limit_iterations(
    if flags.max_iterations > 0 {
      flags.max_iterations
    } else {
      20000
    },
  )
  if !flags.presolve {
    match @simplex.solve_model_with(model, options) {
      Err(reason) => println("       solve=refused(" + reason + ")")
      Ok(result) => report_solve_result(result)
    }
    return
  }
  let presolved = @presolve.presolve(model)
  println(presolve_line(model.num_constraints(), presolved))
  match presolved.verdict() {
    @presolve.PresolveVerdict::Infeasible =>
      println(
        "       solve=infeasible (from presolve: " + presolved.reason() + ")",
      )
    @presolve.PresolveVerdict::Unbounded =>
      println(
        "       solve=unbounded (from presolve: " + presolved.reason() + ")",
      )
    @presolve.PresolveVerdict::Reduced => {
      let reduced = presolved.reduced()
      if reduced.num_vars() == 0 {
        // Everything was eliminated; the reduction's own answer is the answer.
        println(
          "       solve=optimal obj=" +
          presolved.objective(0.0).to_string() +
          " iters=0 (presolve eliminated every variable)",
        )
        return
      }
      match @simplex.solve_model_with(reduced, options) {
        Err(reason) => println("       solve=refused(" + reason + ")")
        Ok(result) => {
          report_solve_result_scaled(result, presolved)
          if result.status == @simplex.SimplexStatus::Optimal {
            let values = presolved.reconstruct(result.values)
            let rows = @presolve.max_row_violation(model, values)
            let bounds = @presolve.max_bound_violation(model, values)
            // The reduced solve and the original model must agree on the
            // objective as well. The offset is easy to get wrong, and a wrong
            // offset leaves a solution that is perfectly feasible while the
            // reported number is not the objective of anything.
            let reported = presolved.objective(result.objective)
            let recomputed = @presolve.objective_value(model, values)
            let agrees = @core.approx_eq(
              reported,
              recomputed,
              rel=1.0e-9,
              abs=1.0e-6,
            )
            println(
              "       reconstructed: rows " +
              values.length().to_string() +
              " vars, worst row violation " +
              rows.to_string() +
              ", worst bound violation " +
              bounds.to_string() +
              ", objective " +
              recomputed.to_string() +
              (if agrees {
                " (agrees with the reported " + reported.to_string() + ")"
              } else {
                " (DISAGREES with the reported " + reported.to_string() + ")"
              }) +
              (if rows <= 1.0e-7 && bounds <= 1.0e-7 && agrees {
                " (feasible)"
              } else {
                " (FAILED: the reduction is not trustworthy here)"
              }),
            )
          }
        }
      }
    }
  }
}

///|
/// Parses one file and prints the outcome. Returns `true` on success.
fn inspect(path : String, flags : SolveFlags) -> Bool {
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
      if flags.enabled && !solve_and_report(model, flags) {
        // A certificate the verifier refused is a failure of the run, not of the file:
        // the exit code has to say so or a pipeline would treat it as a clean answer.
        return false
      }
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
  let mut solve_enabled = false
  let mut relax = false
  let mut presolve_enabled = false
  let mut max_rows = 200
  let mut max_iterations = 0
  let mut verify_enabled = false
  let mut reoptimize_enabled = false
  let mut mip_enabled = false
  let mut max_nodes = 0
  let mut certificate_path = ""
  let mut index = 1
  while index < args.length() {
    let argument = args[index]
    if argument == "--solve" {
      solve_enabled = true
      index = index + 1
      continue
    }
    if argument == "--verify" {
      verify_enabled = true
      solve_enabled = true
      index = index + 1
      continue
    }
    if argument == "--reoptimize" {
      reoptimize_enabled = true
      solve_enabled = true
      index = index + 1
      continue
    }
    if argument == "--mip" {
      mip_enabled = true
      solve_enabled = true
      index = index + 1
      continue
    }
    if argument == "--max-nodes" {
      if index + 1 < args.length() {
        match @format.parse_index(args[index + 1]) {
          Some(value) => max_nodes = value
          None => ()
        }
        index = index + 2
        continue
      }
    }
    if argument == "--certificate" {
      if index + 1 < args.length() {
        certificate_path = args[index + 1]
        verify_enabled = true
        solve_enabled = true
        index = index + 2
        continue
      }
      print_usage()
      @sys.exit(2)
    }
    if argument == "--relax" {
      relax = true
      solve_enabled = true
      index = index + 1
      continue
    }
    if argument == "--presolve" {
      presolve_enabled = true
      solve_enabled = true
      index = index + 1
      continue
    }
    if argument == "--max-rows" {
      if index + 1 < args.length() {
        match @format.parse_index(args[index + 1]) {
          Some(value) => max_rows = value
          None => ()
        }
        index = index + 2
        continue
      }
    }
    if argument == "--max-iterations" {
      if index + 1 < args.length() {
        match @format.parse_index(args[index + 1]) {
          Some(value) => max_iterations = value
          None => ()
        }
        index = index + 2
        continue
      }
    }
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
  let flags : SolveFlags = {
    enabled: solve_enabled,
    relax,
    presolve: presolve_enabled,
    max_rows,
    max_iterations,
    verify: verify_enabled,
    certificate_path,
    reoptimize: reoptimize_enabled,
    mip: mip_enabled,
    max_nodes,
  }
  for path in files {
    if !inspect(path, flags) {
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
