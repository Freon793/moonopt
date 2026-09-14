// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Freon793/moonopt"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/Freon793/moonopt"

license = "Apache-2.0"

keywords = [
  "optimization",
  "linear-programming",
  "mixed-integer-programming",
  "simplex",
  "mps",
]

preferred_target = "wasm"

description = "Optimization kernels for MoonBit: standard MPS/LP model interop, sparse revised and dual simplex, presolve, branch-and-cut, and independently checkable optimality certificates."
