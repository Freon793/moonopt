// Promotions the compiler now asks for explicitly — see the root package's `extends.mbt`
// for the full note (E0079 `implicit_impl_as_method`). `#doc(hidden)` keeps the trait
// methods out of the generated interface.

///|
#doc(hidden)
pub extend Certificate with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend Check with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend Claim with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend Claim with Eq::{equal}

///|
#doc(hidden)
pub extend Claim with Eq::{not_equal}

///|
#doc(hidden)
pub extend CutCertificate with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend CutRow with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend CutVerdict with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend Verdict with @debug.Debug::{to_repr}
