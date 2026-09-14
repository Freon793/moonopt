///|
/// Model file readers and writers.
///
/// Two formats are supported:
///
/// - **MPS** (free and fixed layout, the format used by the Netlib LP test set):
///   `NAME` / `ROWS` / `COLUMNS` / `RHS` / `RANGES` / `BOUNDS` / `ENDATA`, plus
///   the widely implemented `OBJSENSE` extension and `MARKER` integer blocks;
/// - **LP** (the CPLEX LP subset): objective, subject-to, bounds, general and
///   binary sections.
///
/// Parsing never panics and never guesses: anything the reader cannot represent
/// comes back as a `ParseIssue` carrying the line, the column and the offending
/// token. The distinction between "the file is wrong" and "we do not support
/// this" is kept in the message text, because both need different fixes.
