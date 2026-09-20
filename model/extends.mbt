// Promotions the compiler now asks for explicitly — see the root package's `extends.mbt`
// for the full note (E0079 `implicit_impl_as_method`). `#doc(hidden)` keeps the trait
// methods out of the generated interface.

///|
#doc(hidden)
pub extend Constraint with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend Model with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend Rel with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend Rel with Eq::{equal}

///|
#doc(hidden)
pub extend Rel with Eq::{not_equal}

///|
#doc(hidden)
pub extend Sense with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend Sense with Eq::{equal}

///|
#doc(hidden)
pub extend Sense with Eq::{not_equal}

///|
#doc(hidden)
pub extend Var with @debug.Debug::{to_repr}
