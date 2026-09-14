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
/// - **Sparse columns, dense basis inverse.** Pricing walks CSC columns, so the
///   cost of one reduced cost is proportional to that column's nonzeros rather
///   than to the number of rows. The basis inverse itself is a dense m×m array
///   updated by the standard product-form row operations, with periodic
///   refactorization to control drift. A sparse LU with eta updates is the next
///   step; until it lands the kernel is sparse in the problem data and dense in
///   the basis, and the tests only claim what they verify.
/// - **Every failure is a status.** Infeasible, unbounded, iteration limit and
///   numerical failure stay distinct, and a problem the kernel did not solve
///   never comes back with a plausible looking answer.
