// Promotions the compiler now asks for explicitly.
//
// A method from an `impl Trait for Type` — including one that `derive(...)` generates —
// used to be attached to the type implicitly, so `value.to_repr()` worked without anyone
// writing that down. The compiler reports that compatibility behavior as E0079
// (`implicit_impl_as_method`) and asks for the promotion to be written out or dropped;
// dropping it is not an option here, because `derive(Debug, Eq)` is what the tests
// format and compare their values with. So each one is written out below.
//
// `#doc(hidden)` keeps them out of the generated interface: they are the trait's own
// methods, not new promises about these types, and `moon info` confirms no `.mbti` line
// changes. Nothing else about the types changes either — the promotion that used to
// happen implicitly is now spelled out.

///|
#doc(hidden)
pub extend Solution with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend SolveOptions with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend SolveStatus with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend SolveStatus with Eq::{equal}

///|
#doc(hidden)
pub extend SolveStatus with Eq::{not_equal}
