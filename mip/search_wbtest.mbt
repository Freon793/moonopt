///|
/// The pieces of the search that the black box tests can only see through a whole run:
/// the rounding, the choice of branching variable, the node model, and the queue.
///
/// They are white box tests because these are the parts where a mistake is invisible from
/// outside — a child that never tightened a bound is still a well formed model and still
/// solves, it just makes the tree infinite.

///|
fn node_of(parent : Int, variable : Int, lb : Double, ub : Double) -> Node {
  { parent, depth: 0, variable, lb, ub, basis: None, bound: 0.0, key: 0.0, }
}

///|
test "rounding goes to the whole number on the correct side" {
  assert_eq(floor_of(2.0), 2.0)
  assert_eq(ceil_of(2.0), 2.0)
  assert_eq(floor_of(2.75), 2.0)
  assert_eq(ceil_of(2.25), 3.0)
  assert_eq(floor_of(-2.25), -3.0)
  assert_eq(ceil_of(-2.75), -2.0)
  assert_eq(round_of(2.5), 3.0)
  assert_eq(round_of(-2.5), -3.0)
  assert_eq(round_of(2.4), 2.0)
  assert_eq(round_of(-2.4), -2.0)
  assert_eq(round_of(0.0), 0.0)
}

///|
test "the branching variable is the integer one furthest from a whole number" {
  let model = @model.Model::new(@model.Sense::Minimize)
  model.add_var("a", lb=0.0, ub=10.0, is_int=true) |> ignore
  // `b` is continuous and very fractional; it is not a candidate.
  model.add_var("b", lb=0.0, ub=10.0, is_int=false) |> ignore
  model.add_var("c", lb=0.0, ub=10.0, is_int=true) |> ignore
  // `a` sits 0.2 from a whole number and `c` 0.1: the further one is the candidate, and
  // `b` at 4.5 is the most fractional variable of all but is not an integer one.
  assert_eq(most_fractional(model, [0.2, 4.5, 3.9], 1.0e-7), 0)
  // Now `c` is the furthest.
  assert_eq(most_fractional(model, [0.2, 4.5, 3.7], 1.0e-7), 2)
  // Both remaining variables are whole: nothing to branch on.
  assert_eq(most_fractional(model, [2.0, 4.5, 3.0], 1.0e-7), -1)
  // A value within the tolerance of a whole number counts as whole.
  assert_eq(most_fractional(model, [1.0 + 1.0e-9, 4.5, 2.0], 1.0e-7), -1)
  assert_eq(most_fractional(model, [1.6, 4.5, 1.5], 1.0e-7), 2)
}

///|
/// The point of the node model: a child is its parent with one bound tightened, and the
/// root is left alone. A child that came back equal to its parent would solve the same
/// relaxation forever.
test "a node model is the root with the chain's bounds applied" {
  let root = @model.Model::new(@model.Sense::Minimize)
  let x = root.add_var("x", lb=0.0, ub=8.0, is_int=true)
  let y = root.add_var("y", lb=0.0, ub=8.0, is_int=true)
  root.set_objective([(x, 1.0), (y, 1.0)])
  let nodes : Array[Node] = [node_of(-1, -1, 0.0, 0.0)]
  // x <= 3
  nodes.push(node_of(0, x, 0.0, 3.0))
  // then y >= 2 within that
  nodes.push(node_of(1, y, 2.0, 8.0))
  // then x >= 2 within that
  nodes.push(node_of(2, x, 2.0, 3.0))
  let deep = node_model(root, nodes, 3)
  assert_eq(deep.get_var(x).lb, 2.0)
  assert_eq(deep.get_var(x).ub, 3.0)
  assert_eq(deep.get_var(y).lb, 2.0)
  assert_eq(deep.get_var(y).ub, 8.0)
  // The parent of the deep node is the one with only the two looser changes.
  let shallow = node_model(root, nodes, 2)
  assert_eq(shallow.get_var(x).lb, 0.0)
  assert_eq(shallow.get_var(x).ub, 3.0)
  // And the root is untouched, so the next node starts from the original bounds.
  assert_eq(root.get_var(x).lb, 0.0)
  assert_eq(root.get_var(x).ub, 8.0)
  assert_eq(root.get_var(y).lb, 0.0)
}

///|
test "the queue always hands back the smallest key" {
  let nodes : Array[Node] = [
    {
      parent: -1,
      depth: 0,
      variable: -1,
      lb: 0.0,
      ub: 0.0,
      basis: None,
      bound: 9.0,
      key: 9.0,
    },
    {
      parent: 0,
      depth: 1,
      variable: 0,
      lb: 0.0,
      ub: 1.0,
      basis: None,
      bound: 3.0,
      key: 3.0,
    },
    {
      parent: 0,
      depth: 1,
      variable: 0,
      lb: 0.0,
      ub: 1.0,
      basis: None,
      bound: 1.0,
      key: 1.0,
    },
    {
      parent: 0,
      depth: 1,
      variable: 0,
      lb: 0.0,
      ub: 1.0,
      basis: None,
      bound: 2.0,
      key: 2.0,
    },
    {
      parent: 0,
      depth: 1,
      variable: 0,
      lb: 0.0,
      ub: 1.0,
      basis: None,
      bound: 0.5,
      key: 0.5,
    },
  ]
  let queue = NodeQueue::new(nodes)
  assert_true(queue.is_empty())
  for k = 0; k < nodes.length(); k = k + 1 {
    queue.push(k)
  }
  assert_true(!queue.is_empty())
  let order : Array[Int] = []
  while !queue.is_empty() {
    order.push(queue.pop())
  }
  assert_eq(order, [4, 2, 3, 1, 0])
}

///|
/// The key of a node is in minimisation terms — `sense_sign` times its objective — so the
/// same two nodes are ordered oppositely depending on the sense the run is in.
test "the open bound is the best of what is left in the queue" {
  let minimizing : Array[Node] = [
    node_of(-1, -1, 0.0, 0.0),
    {
      parent: 0,
      depth: 1,
      variable: 0,
      lb: 0.0,
      ub: 1.0,
      basis: None,
      bound: 7.0,
      key: 7.0,
    },
    {
      parent: 0,
      depth: 1,
      variable: 0,
      lb: 0.0,
      ub: 1.0,
      basis: None,
      bound: 4.0,
      key: 4.0,
    },
  ]
  let queue = NodeQueue::new(minimizing)
  queue.push(1)
  queue.push(2)
  // Minimisation: the best node is the one that can reach the smallest objective.
  assert_eq(open_bound(minimizing, queue, 1.0), 4.0)
  queue.pop() |> ignore
  assert_eq(open_bound(minimizing, queue, 1.0), 7.0)
  // Maximisation stores the negation, so the same bounds come back the right way up.
  let maximizing : Array[Node] = [
    node_of(-1, -1, 0.0, 0.0),
    {
      parent: 0,
      depth: 1,
      variable: 0,
      lb: 0.0,
      ub: 1.0,
      basis: None,
      bound: 7.0,
      key: -7.0,
    },
    {
      parent: 0,
      depth: 1,
      variable: 0,
      lb: 0.0,
      ub: 1.0,
      basis: None,
      bound: 4.0,
      key: -4.0,
    },
  ]
  let mirror = NodeQueue::new(maximizing)
  mirror.push(1)
  mirror.push(2)
  assert_eq(open_bound(maximizing, mirror, -1.0), 7.0)
  mirror.pop() |> ignore
  assert_eq(open_bound(maximizing, mirror, -1.0), 4.0)
}
