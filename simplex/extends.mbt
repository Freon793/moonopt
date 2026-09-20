// Promotions the compiler now asks for explicitly — see the root package's `extends.mbt`
// for the full note (E0079 `implicit_impl_as_method`). `#doc(hidden)` keeps the trait
// methods out of the generated interface.

///|
#doc(hidden)
pub extend KernelProblem with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend SimplexBasis with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend SimplexOptions with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend SimplexResult with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend SimplexStatus with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend SimplexStatus with Eq::{equal}

///|
#doc(hidden)
pub extend SimplexStatus with Eq::{not_equal}

///|
#doc(hidden)
pub extend TableauRow with @debug.Debug::{to_repr}
