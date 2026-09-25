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
/// The size of the dive a launch would start, which is what decides whether the primal
/// heuristic runs at all: the walk fixes one fractional integer per step and may spend two
/// steps on a variable whose first side comes back infeasible.
test "the dive size counts fractional integers and only those" {
  let model = @model.Model::new(@model.Sense::Minimize)
  model.add_var("a", lb=0.0, ub=10.0, is_int=true) |> ignore
  // `b` is continuous and very fractional; it is not a step the walk would take.
  model.add_var("b", lb=0.0, ub=10.0, is_int=false) |> ignore
  model.add_var("c", lb=0.0, ub=10.0, is_int=true) |> ignore
  model.add_var("d", lb=0.0, ub=10.0, is_int=true) |> ignore
  assert_eq(fractional_count(model, [0.2, 4.5, 3.7, 2.0], 1.0e-7), 2)
  assert_eq(fractional_count(model, [1.0, 4.5, 2.0, 3.0], 1.0e-7), 0)
  // A value inside the tolerance of a whole number is a whole number, here too.
  assert_eq(fractional_count(model, [1.0 + 1.0e-9, 0.0, 2.0, 3.0], 1.0e-7), 0)
  assert_eq(fractional_count(model, [1.5, 0.0, 2.5, 3.5], 1.0e-7), 3)
}

///|
/// The dive is what a relaxation with no whole point is offered, and its step budget is
/// what keeps it from being a way of not searching. Two properties hold whatever the budget
/// is: the walk never spends more than the budget, and whatever it hands back is a whole
/// point that satisfies the model. The ordering inside the walk matters for the first
/// property — a walk that lands on its last step has found a point, so integrality is read
/// before the budget — and that ordering was a real defect: a two-step walk with a two-step
/// budget used to come back empty.
test "the dive never spends more than its budget" {
  // max x + y  s.t.  x + y <= 3.3, x and y integers in [0, 4]. The relaxation is optimal
  // all along `x + y = 3.3`, so it stands at `(3.3, 0)` or `(0, 3.3)` — either way one
  // fractional variable, and rounding it to the nearer whole number leaves the other one
  // 0.3 short, so the walk needs exactly two relaxations to reach `(3, 0)` or `(0, 3)`.
  // That is what makes the ordering inside the walk observable: with a budget of one the
  // walk must report nothing, because the step it could afford did not make the point whole.
  let model = @model.Model::new(@model.Sense::Maximize)
  let x = model.add_var("x", ub=4.0, is_int=true)
  let y = model.add_var("y", ub=4.0, is_int=true)
  model.set_objective([(x, 1.0), (y, 1.0)])
  model.add_constraint([(x, 1.0), (y, 1.0)], @model.Rel::LessEqual, 3.3)
  let options = MipOptions::default()
  let (start, basis) = kernel_node(model, options, None)
  assert_eq(start.status, NodeStatus::Optimal)
  let mut landed_at = -1
  for budget = 1; budget <= 4; budget = budget + 1 {
    let dive = dive_for_incumbent(model, options, start, basis, budget)
    assert_true(dive.relaxations <= budget)
    assert_true(dive.verified <= dive.relaxations)
    if dive.values.length() > 0 {
      if landed_at < 0 {
        landed_at = budget
      }
      // Whole, inside its bounds, and satisfying the row — checked here rather than taken
      // from the walk's own account of itself.
      for j = 0; j < model.num_vars(); j = j + 1 {
        let value = dive.values[j]
        assert_true(@core.fabs(value - round_of(value)) < 1.0e-6)
        assert_true(value >= -1.0e-6 && value <= 4.0 + 1.0e-6)
      }
      assert_true(dive.values[0] + dive.values[1] <= 3.3 + 1.0e-6)
    }
  }
  // The budget bounds the walk and the walk uses it: one relaxation is not enough for this
  // model, two are, and landing on the last step still reports the point.
  assert_eq(landed_at, 2)
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
  assert_eq(open_bound(minimizing, queue, [], 1.0), 4.0)
  queue.pop() |> ignore
  assert_eq(open_bound(minimizing, queue, [], 1.0), 7.0)
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
  assert_eq(open_bound(maximizing, mirror, [], -1.0), 7.0)
  mirror.pop() |> ignore
  assert_eq(open_bound(maximizing, mirror, [], -1.0), 4.0)
}

///|
/// A node that was popped and never answered is still part of the open set. Its key is the parent's
/// relaxation objective, which bounds the whole region below it, and the node is gone from the
/// queue because a second solve would repeat the same work — so this is the only place that key can
/// be counted. Counting only the queue's keys reported a bound the run had not established, and in
/// the direction that flatters it: this is a best-bound search, so the node that failed is the one
/// that came in with one of the queue's *smallest* keys, which is what the reported bound is.
test "the open bound counts the keys of nodes that were never judged" {
  let nodes : Array[Node] = [
    node_of(-1, -1, 0.0, 0.0),
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
  let queue = NodeQueue::new(nodes)
  queue.push(1)
  // The queue alone says 4; the region a failed node stands for can only be better than that.
  assert_eq(open_bound(nodes, queue, [2.0], 1.0), 2.0)
  // A key that is worse than the queue's best does not move the bound.
  assert_eq(open_bound(nodes, queue, [9.0], 1.0), 4.0)
  // Maximisation is the same picture upside down.
  assert_eq(open_bound(nodes, queue, [-2.0], -1.0), 2.0)
  // With nothing open the sentinel the queue-only version returned is kept.
  let empty = NodeQueue::new(nodes)
  assert_eq(open_bound(nodes, empty, [], 1.0), 0.0)
}

///|
/// The cutoff, spent on a node's box instead of on a new row: a variable is bounded by the
/// cutoff and the smallest the *other* terms could take over their own boxes. The three cases
/// that matter are that it tightens what it can, that it leaves alone what it cannot, and that
/// a box it empties is the node being pruned with no solve at all.
test "the incumbent's cutoff narrows a node's box" {
  // min 2x + 3y + z, boxes [0,10] / [0,4] / [0,1], and an incumbent at 12.
  let model = @model.Model::new(@model.Sense::Minimize)
  let x = model.add_var("x", lb=0.0, ub=10.0, is_int=true)
  let y = model.add_var("y", lb=0.0, ub=4.0, is_int=true)
  let z = model.add_var("z", lb=0.0, ub=1.0, is_int=true)
  model.set_objective([(x, 2.0), (y, 3.0), (z, 1.0)])
  // Every term's smallest value is zero, so each budget is the cutoff itself: x ≤ 6 is a real
  // tightening, y ≤ 4 and z ≤ 12 are not, and the ones that are not must not be written.
  assert_true(propagate_cutoff(model, 1.0, 12.0, 1.0e-7))
  assert_eq(model.get_var(x).ub, 6.0)
  assert_eq(model.get_var(y).ub, 4.0)
  assert_eq(model.get_var(z).ub, 1.0)
  assert_eq(model.get_var(x).lb, 0.0)
  // A cutoff below the smallest value the objective can take empties the box, which is the
  // node pruned: no point in it could beat the incumbent.
  assert_false(propagate_cutoff(model, 1.0, -1.0, 1.0e-7))
  // A maximisation is the same argument with the sign carried: better means larger, and the
  // cutoff bounds from below. With both boxes [0,10] and an incumbent at 12, each variable has
  // to be at least 2 for the pair to beat it.
  let maxed = @model.Model::new(@model.Sense::Maximize)
  let a = maxed.add_var("a", lb=0.0, ub=10.0, is_int=true)
  let b = maxed.add_var("b", lb=0.0, ub=10.0, is_int=true)
  maxed.set_objective([(a, 1.0), (b, 1.0)])
  assert_true(propagate_cutoff(maxed, -1.0, 12.0, 1.0e-7))
  assert_eq(maxed.get_var(a).lb, 2.0)
  assert_eq(maxed.get_var(b).lb, 2.0)
  // A term whose variable has no bound on the side its coefficient needs has no minimum, and
  // then neither has the sum: the argument is unavailable for the whole model, so nothing is
  // changed — not even the variable that could have been bounded on its own.
  let unbounded = @model.Model::new(@model.Sense::Minimize)
  let free = unbounded.add_var(
    "free",
    lb=-@model.infinite_bound,
    ub=@model.infinite_bound,
    is_int=true,
  )
  let bounded = unbounded.add_var("bounded", lb=0.0, ub=5.0, is_int=true)
  unbounded.set_objective([(free, 1.0), (bounded, 1.0)])
  assert_true(propagate_cutoff(unbounded, 1.0, 3.0, 1.0e-7))
  assert_eq(unbounded.get_var(bounded).ub, 5.0)
}
