///|
/// Sparse revised simplex kernel.
///
/// What the kernel solves is the standard form
///
///   min cᵀx   subject to   A x = b,   x ≥ 0
///
/// with `A` stored in CSC form. Model level constraints (`≤` / `≥` / `=`) become
/// that form by adding slack, surplus and artificial columns; model level bounds
/// become shifts, free-variable splits and explicit bound rows — `problem.mbt`
/// documents each transformation and its effect on the objective constant.
///
/// Two implementation choices are deliberate and worth stating:
///
/// - **Sparse columns, sparse basis factors.** Pricing walks CSC columns, so the
///   cost of one reduced cost is proportional to that column's nonzeros rather than
///   to the number of rows. The basis is factored as a sparse LU and updated in
///   product form between factorizations (`P·B = L·U`, `B⁻¹ = E_k·…·E₁·B₀⁻¹`), so
///   both the problem data and the linear algebra are sparse: the memory a run
///   needs follows `O(nnz + fill)` rather than the `m²` a dense inverse costs.
///   `lu.mbt` documents the factorization and `revised.mbt` the iteration.
/// - **Every failure is a status.** Infeasible, unbounded, iteration limit and
///   numerical failure stay distinct, and a problem the kernel did not solve
///   never comes back with a plausible looking answer.
