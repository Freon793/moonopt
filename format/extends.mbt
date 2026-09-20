// Promotions the compiler now asks for explicitly — see the root package's `extends.mbt`
// for the full note (E0079 `implicit_impl_as_method`). `#doc(hidden)` keeps the trait
// methods out of the generated interface.

///|
#doc(hidden)
pub extend ParseIssue with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend ParseIssue with Eq::{equal}

///|
#doc(hidden)
pub extend ParseIssue with Eq::{not_equal}
