// Promotions the compiler now asks for explicitly — see the root package's `extends.mbt`
// for the full note (E0079 `implicit_impl_as_method`). `#doc(hidden)` keeps the trait
// methods out of the generated interface.

///|
#doc(hidden)
pub extend OracleResult with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend OracleStatus with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend OracleStatus with Eq::{equal}

///|
#doc(hidden)
pub extend OracleStatus with Eq::{not_equal}
