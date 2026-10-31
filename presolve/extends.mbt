// Promotions the compiler now asks for explicitly — see the root package's `extends.mbt`
// for the full note (E0079 `implicit_impl_as_method`). `#doc(hidden)` keeps the trait
// methods out of the generated interface.

///|
#doc(hidden)
pub extend PresolveStats with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend StrengthenStats with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend StrengthenStats with Eq::{equal}

///|
#doc(hidden)
pub extend StrengthenStats with Eq::{not_equal}

///|
#doc(hidden)
pub extend DominationStats with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend DominationStats with Eq::{equal}

///|
#doc(hidden)
pub extend DominationStats with Eq::{not_equal}

///|
#doc(hidden)
pub extend PresolveVerdict with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend PresolveVerdict with Eq::{equal}

///|
#doc(hidden)
pub extend PresolveVerdict with Eq::{not_equal}

///|
#doc(hidden)
pub extend VarForm with @debug.Debug::{to_repr}
