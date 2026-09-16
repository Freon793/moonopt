# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

- Package layout of this project:
  - `moonopt.mbt` (module root package): public entry points — `Model::solve`,
    `SolveStatus`, `Solution`, `SolveOptions`. Keep it thin: orchestration only.
    Presolve is on by default here, so this is also the layer that reconstructs the
    solution into the original variables and **verifies** it against the original
    model before reporting `Optimal`; integer models skip the reduction so the
    kernel's refusal stays independent of what a reduction happened to fix.
  - `core/`: numeric and sparse infrastructure (tolerances, compensated
    summation, CSC sparse matrix). Must not depend on other packages here.
  - `model/`: variables, linear expressions, constraints, objective, validation.
  - `format/`: MPS and LP readers and writers, plus the shared `ParseIssue`
    position reporting. Implemented.
  - `oracle/`: dense two-phase tableau simplex used as the *reference* for
    differential tests. Deliberately simple; it is not the shipped solver.
  - `simplex/`: the sparse revised simplex kernel. Sparse CSC columns, a **sparse LU
    basis factorization** (`P·B = L·U`, row pivoting with a relative threshold) with
    product-form eta updates and periodic refactorization, **bounded-variable
    pivoting** (both bounds in the ratio test, non-basic variables resting at either
    end, and a flip to the other bound when the variable's own range limits the
    step), Phase I and II, Harris ratio test with a feasibility guard and a Bland
    fallback, a pivot stability check that rebuilds stale factors before pivoting,
    one recovery attempt with Bland's rule after a numerical failure, a row ceiling
    and a fill budget that refuse a problem worth refusing, and a residual
    self-check before it will report `Optimal`. Pricing is Dantzig plus a **measured
    gain** rule (`gain_candidates`): the reduced cost is an improvement rate, so the
    column that enters is chosen by the gain `|r| · step` measured for a bounded
    candidate set (Dantzig's pick, a pool of recently good columns, a rotating window
    over the column space), because the step is only known after a ratio test. A
    **bounded-variable dual simplex** (`dual.mbt`) reoptimizes from a basis a previous
    run left behind: a bound change leaves the reduced costs alone, so the previous
    optimal basis is still dual feasible and only primal feasibility is missing. Its
    one invariant — the basis stays dual feasible — is checked once at the end, and a
    violation hands the problem to the cold path instead of reporting an answer. A warm
    start is otherwise trusted only for its shape and its dual feasibility, because
    "faster" must never mean "a different answer".
    `lu.mbt` holds the factorization;
    its factors are verified against a dense reference that lives in the test file,
    not in the kernel. A pivot step is passed in by the ratio test rather than
    recomputed from the pivot row: with two bounds per variable, which bound a
    leaving variable came to rest on decides the step, and guessing it from the rate
    is how a step of the wrong sign (or the size of an unbounded column's sentinel)
    gets into the state.
  - `presolve/`: model reduction and postsolve. Empty rows and columns, rows the
    bounds already settle, singleton rows turned into bounds, implied bounds, and
    fixed-variable elimination with an objective offset; `reconstruct` maps a
    reduced solution back to the original variables and `max_row_violation` /
    `max_bound_violation` check it against the original model instead of trusting
    the reduction's bookkeeping. Every reduction must be proved before it fires,
    and a model presolve proves infeasible or unbounded is reported as such rather
    than handed to the kernel.
  - `verify/`: the **independent** checker for a claimed answer. Primal feasibility,
    dual feasibility, complementary slackness and the duality gap for an optimality
    claim; a Farkas ray for an infeasibility claim; a feasible point plus a recession
    direction for an unboundedness claim; certificates as JSON. It imports
    `core`, `model` and `moonbitlang/core/string` and **never** `simplex` — that the
    checker shares nothing with the solver is the point, and `verify/moon.pkg` is
    where a reviewer checks it. The multiplier convention and the weak-duality
    derivation are documented in `verify/verify.mbt`; a producer has to use that
    convention, and the kernel's mapping onto it lives in `simplex/certificate.mbt`.
  - `mip/`: branch and bound over the linear kernel, added milestone by milestone,
    see `docs/roadmap.md`. A node is its parent plus one tightened bound, rebuilt
    from the root along the chain rather than copied per node; the child is solved
    warm from the basis its parent ended on (`solve_model_with_basis`), because a
    bound change leaves the reduced costs alone. The search is best-bound, prunes
    against the incumbent, and **verifies every relaxation with `@verify` before
    branching on it** — a refused certificate stops the run as `Unverified` instead
    of becoming a branch. Only an exhausted tree (or one whose open bounds are all
    closed against the incumbent) is reported `Optimal`; a node budget ends the run
    as `NodeLimit` with the incumbent and the bound still open, a relaxation that
    reached no verdict is counted as open work rather than as a refused claim, and
    an unbounded relaxation is `UnboundedRelaxation` because an improving ray of the
    relaxation carries no integrality of its own. A model that fails validation is
    `Invalid`, never `Infeasible`.
  - `cmd/main/`: demo CLI. `cmd/parse/`: model file inspection CLI. `examples/`:
    runnable examples. `bench/`: data policy, fetch and report scripts, reports.
    `docs/`: design notes, technical roadmap and the ecosystem survey that
    defines the design boundary.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

- Numeric code rules for this project:
  - never compare floats with `==` unless the values are integers by
    construction; use the `core` tolerance helpers;
  - every "is this zero / is this positive" decision must be tolerance-aware;
  - use compensated summation when accumulating many terms;
  - any routine that can fail numerically must report that explicitly instead of
    silently returning a wrong answer;
  - a routine whose cost follows the caller's problem size must bound that cost
    **before** it starts. Two shapes exist here and they need different bounds: a
    row ceiling (`TooLarge`) for "would this run have any chance of finishing", and
    a fill budget (`max_factor_entries`) for the one quantity a sparse
    factorization cannot predict in advance. A model's row count is not a proxy for
    the kernel's row count: a free variable with a finite upper bound has to be a
    difference of two columns, and a difference has no per-column bound, so it stays
    an explicit row. Before the basis was factored sparsely, a large kernel row
    count was an allocation of tens of gigabytes and an access violation on the
    native backend rather than a slow solve; finite upper bounds used to cost a row
    each as well, and on one 507 constraint instance that inflated the kernel to
    63 516 rows. Bounds are bounds now, and removing those rows cut the cost of a
    pivot by an order of magnitude — the pivot count follows the row count.

- Keep the public surface small. Anything that appears in a `.mbti` is a
  contract.

- Library packages stay dependency free. Only CLI packages may import
  `moonbitlang/x`; today that is `cmd/parse`, which uses `fs` and `sys`.

- Scripts under `bench/` are ASCII only: Windows PowerShell 5.1 decodes UTF-8
  script files without a BOM as ANSI, so non-ASCII characters become mojibake.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## Solver invariants (must hold in every change)

- The sparse matrix never stores structural zeros, and row indices stay sorted
  ascending inside each column.
- `verify` must reject a wrong solution produced by an intentionally broken
  solver; there are tests for exactly that case.
- A report under `bench/` is evidence, so a script must not write one unless the
  run it describes finished and covered every manifest entry.
- A presolve reduction may only fire on a proved reduction, and a reconstructed
  solution must be checked against the **original** model by an independent
  routine (`max_row_violation` / `max_bound_violation`), never against the
  reduction's own bookkeeping. A reduction that cannot be verified is worse than
  no reduction.
- Adding an algorithm requires a unit test, an invariant test, and — when it
  overlaps the oracle — a differential test against `oracle/`.
- Never enlarge the promised model class silently. If support for a construct is
  missing, the call must return `NotSolved` with a reason, not a plausible
  answer.
