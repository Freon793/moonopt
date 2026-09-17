///|
/// The search itself.

///|
/// One node of the tree.
///
/// A node is its parent plus one tightened bound, and that is all it stores: rebuilding the
/// model from the root along the chain is O(depth) bound changes, where copying the model
/// at every node would be O(model) each time.
priv struct Node {
  parent : Int
  depth : Int
  variable : Int
  lb : Double
  ub : Double
  /// The parent's optimal basis, so the relaxation can be reoptimized instead of rebuilt.
  basis : @simplex.SimplexBasis?
  /// Best objective the node can still reach, in the model's own sense: the parent's
  /// relaxation objective. Used to order the queue and to prune before solving.
  bound : Double
  /// Ordering key: the bound in minimisation terms, so the heap can always keep the
  /// smallest.
  key : Double
}

///|
/// `-1` for a minimisation, `+1` for a maximisation: the sign that turns "better" into
/// "smaller", so one comparison serves both senses.
fn sense_sign(model : @model.Model) -> Double {
  match model.sense() {
    @model.Sense::Minimize => 1.0
    @model.Sense::Maximize => -1.0
  }
}

///|
/// A binary heap over node indices, ordered by `Node::key`. Written out rather than pulled
/// from a library because the whole structure is twenty lines and the ordering rule is the
/// part worth reading.
priv struct NodeQueue {
  nodes : Array[Node]
  heap : Array[Int]
}

///|
fn NodeQueue::new(nodes : Array[Node]) -> NodeQueue {
  { nodes, heap: [], }
}

///|
fn NodeQueue::is_empty(self : NodeQueue) -> Bool {
  self.heap.length() == 0
}

///|
fn NodeQueue::push(self : NodeQueue, index : Int) -> Unit {
  self.heap.push(index)
  let mut child = self.heap.length() - 1
  while child > 0 {
    let parent = (child - 1) / 2
    if self.nodes[self.heap[parent]].key <= self.nodes[self.heap[child]].key {
      break
    }
    let swapped = self.heap[parent]
    self.heap[parent] = self.heap[child]
    self.heap[child] = swapped
    child = parent
  }
}

///|
fn NodeQueue::pop(self : NodeQueue) -> Int {
  let top = self.heap[0]
  let last = self.heap[self.heap.length() - 1]
  self.heap.pop() |> ignore
  if self.heap.length() > 0 {
    self.heap[0] = last
    let mut parent = 0
    while true {
      let left = 2 * parent + 1
      if left >= self.heap.length() {
        break
      }
      let right = left + 1
      let mut best = left
      if right < self.heap.length() &&
        self.nodes[self.heap[right]].key < self.nodes[self.heap[left]].key {
        best = right
      }
      if self.nodes[self.heap[parent]].key <= self.nodes[self.heap[best]].key {
        break
      }
      let swapped = self.heap[parent]
      self.heap[parent] = self.heap[best]
      self.heap[best] = swapped
      parent = best
    }
  }
  top
}

///|
/// The best bound still open, in the model's own sense: the smallest key in the queue turned
/// back into an objective value. This is what an unfinished run's incumbent has to be
/// measured against, because every remaining node is somewhere below its own bound.
fn open_bound(nodes : Array[Node], queue : NodeQueue, sign : Double) -> Double {
  let mut best = 0.0
  for k = 0; k < queue.heap.length(); k = k + 1 {
    let key = nodes[queue.heap[k]].key
    if k == 0 || key < best {
      best = key
    }
  }
  sign * best
}

///|
/// The model of one node: the root model with the bounds along the chain applied.
fn node_model(
  root : @model.Model,
  nodes : Array[Node],
  index : Int,
) -> @model.Model {
  let chain : Array[Int] = []
  let mut current = index
  while current >= 0 {
    chain.push(current)
    current = nodes[current].parent
  }
  let model = root.clone()
  // From the root down, so that a variable branched on twice ends at the deeper bound.
  let mut k = chain.length() - 1
  while k >= 0 {
    let node = nodes[chain[k]]
    if node.variable >= 0 {
      // The node carries both ends, so this is the whole of the change it represents.
      model.set_var_bounds(node.variable, node.lb, node.ub)
    }
    k = k - 1
  }
  model
}

///|
/// Largest whole number not above `value`. The core library has no `floor`, and the two
/// functions here are the whole of what branching needs from rounding.
fn floor_of(value : Double) -> Double {
  let truncated = Double::from_int(value.to_int())
  if value < 0.0 && truncated != value {
    truncated - 1.0
  } else {
    truncated
  }
}

///|
/// Smallest whole number not below `value`.
fn ceil_of(value : Double) -> Double {
  let truncated = Double::from_int(value.to_int())
  if value > 0.0 && truncated != value {
    truncated + 1.0
  } else {
    truncated
  }
}

///|
/// The whole number nearest to `value`, halves away from zero.
fn round_of(value : Double) -> Double {
  if value >= 0.0 {
    floor_of(value + 0.5)
  } else {
    ceil_of(value - 0.5)
  }
}

///|
/// How many integer variables are further from a whole number than `tolerance`.
///
/// This is the size of the dive that starts here: fixing one fractional variable per
/// step, and at most two steps per variable because a side that comes back infeasible is
/// undone and the other side tried. It is what lets a launch be *started* only when the
/// walk it implies fits the step budget, so a dive is never cut off in the middle — it
/// either lands on a whole point or runs out of sides, and both of those are answers the
/// caller can act on.
fn fractional_count(
  model : @model.Model,
  values : Array[Double],
  tolerance : Double,
) -> Int {
  let mut count = 0
  for j = 0; j < model.num_vars() && j < values.length(); j = j + 1 {
    if !model.get_var(j).is_int {
      continue
    }
    if @core.fabs(values[j] - round_of(values[j])) > tolerance {
      count = count + 1
    }
  }
  count
}

///|
/// The integer variable furthest from a whole number, or `-1` when the point is integral.
fn most_fractional(
  model : @model.Model,
  values : Array[Double],
  tolerance : Double,
) -> Int {
  let mut worst = -1
  let mut worst_distance = tolerance
  for j = 0; j < model.num_vars() && j < values.length(); j = j + 1 {
    if !model.get_var(j).is_int {
      continue
    }
    let value = values[j]
    let distance = @core.fabs(value - round_of(value))
    if distance > worst_distance {
      worst_distance = distance
      worst = j
    }
  }
  worst
}

///|
/// The certificate check of one node, or the verifier's account of why it refused.
///
/// The claim follows the relaxation's status, and the numbers come from the relaxation
/// itself. Nothing here shares state with the solver: `@verify` reads the model and these
/// arrays.
///
/// A relaxation that reached no verdict is not a claim to check — the caller counts it
/// as an open node instead of stopping the run — so it comes back as no refusal here.
fn node_refusal(
  model : @model.Model,
  solution : NodeSolution,
  tolerance : Double,
) -> String {
  let claim = match solution.status {
    NodeStatus::Optimal => @verify.Claim::Optimal
    NodeStatus::Infeasible => @verify.Claim::Infeasible
    NodeStatus::Unbounded => @verify.Claim::Unbounded
    NodeStatus::Unfinished => return ""
  }
  let certificate : @verify.Certificate = {
    claim,
    values: solution.values,
    duals: solution.duals,
    ray: solution.ray,
    objective: solution.objective,
  }
  let verdict = @verify.verify(model, certificate, tolerance~)
  if verdict.accepted {
    ""
  } else {
    verdict.reason
  }
}

///|
/// What one launch of the primal heuristic came back with: the whole point it reached
/// (`values`, empty when it reached none) and its objective, plus how many relaxations
/// the launch solved and how many of them the verifier accepted.
priv struct Dive {
  values : Array[Double]
  objective : Double
  relaxations : Int
  verified : Int
  /// The verifier's account of the first refused certificate, when one was refused.
  refusal : String
}

///|
/// The primal heuristic: walk a node's relaxation down to a whole point.
///
/// Best-bound branching is a search for a *bound*, and it can spend an entire budget
/// without ever standing on an integer point — thirteen of the fourteen instances the
/// first branch and bound report stopped at the node budget on had no incumbent at all,
/// which is exactly the state in which a bound prunes nothing. This is the cheapest thing
/// that produces one: take the integer variable furthest from a whole number, follow the
/// nearer of its two whole sides, and re-solve; the point the walk lands on is feasible
/// because every step is a relaxation of a *restricted* model, and whole because that is
/// where the walk stops.
///
/// Neither side is guaranteed to work, so a side that comes back infeasible is undone and
/// the other one is tried at the same depth. A dive is not a proof of anything and is not
/// treated as one: it only ever *offers* an incumbent, and the search keeps its own
/// branching exactly as it was.
///
/// Every step is a relaxation of a model this package built, so every step is verified
/// like a node's relaxation is — a certificate the verifier refuses stops the run rather
/// than being quietly dropped, because a dive is not a reason to trust the kernel more
/// than the tree is.
fn dive_for_incumbent(
  problem : @model.Model,
  options : MipOptions,
  start : NodeSolution,
  basis : @simplex.SimplexBasis?,
  budget : Int,
) -> Dive {
  let model = problem.clone()
  let mut values = start.values
  let mut objective = start.objective
  let mut dive_basis = basis
  let mut relaxations = 0
  let mut verified = 0
  while true {
    // Whole already is the state the walk is looking for, and it is checked before the
    // budget is: a walk that spends its last step landing on a whole point has found one,
    // and reading the budget first would throw that away.
    let fractional = most_fractional(model, values, options.tolerance)
    if fractional < 0 {
      return { values, objective, relaxations, verified, refusal: "", }
    }
    if relaxations >= budget {
      return { values: [], objective: 0.0, relaxations, verified, refusal: "", }
    }
    let variable = model.get_var(fractional)
    let value = values[fractional]
    let down = floor_of(value)
    let up = ceil_of(value)
    let down_bound = if down < variable.lb { variable.lb } else { down }
    let up_bound = if up > variable.ub { variable.ub } else { up }
    // The nearer side first: it is the smaller step away from the point the relaxation
    // chose, so it is the side that costs the least objective.
    let prefer_down = value - down <= up - value
    let mut landed = false
    let mut side = 0
    while side < 2 && !landed && relaxations < budget {
      let go_down = if side == 0 { prefer_down } else { !prefer_down }
      side = side + 1
      let lb = if go_down { variable.lb } else { up_bound }
      let ub = if go_down { down_bound } else { variable.ub }
      // A side only counts when it actually excludes the value the relaxation chose.
      // `x ≤ floor(v)` where the floor is already the variable's own bound would confine
      // nothing, and re-solving would hand back the same fractional point for ever.
      let moves = if go_down {
        ub < value - options.tolerance
      } else {
        lb > value + options.tolerance
      }
      if !moves {
        continue
      }
      model.set_var_bounds(fractional, lb, ub)
      let (solution, step_basis) = match options.node_solver {
        Some(injected) => (injected(model), None)
        None => kernel_node(model, options, dive_basis)
      }
      relaxations = relaxations + 1
      if options.verify_nodes && solution.status != NodeStatus::Unfinished {
        let refusal = node_refusal(model, solution, options.tolerance)
        if refusal != "" {
          return { values: [], objective: 0.0, relaxations, verified, refusal, }
        }
        verified = verified + 1
      }
      if solution.status == NodeStatus::Optimal {
        values = solution.values
        objective = solution.objective
        dive_basis = step_basis
        landed = true
      } else {
        // The side is empty or the step did not finish: put the bounds back and let the
        // other side have its turn.
        model.set_var_bounds(fractional, variable.lb, variable.ub)
      }
    }
    if !landed {
      // Neither side of this variable leads anywhere, so this dive has no whole point to
      // offer. The tree still has both sides queued and will do better with them than a
      // walk that has already given up.
      return { values: [], objective: 0.0, relaxations, verified, refusal: "", }
    }
  }
  // Every way out of the loop above returns; this is here because the loop is an
  // expression and the checker wants one.
  { values: [], objective: 0.0, relaxations, verified, refusal: "", }
}

///|
/// The default node solver: the kernel on the relaxed model, reoptimized from the parent's
/// basis when there is one, and the basis the relaxation ended on so its children can do
/// the same.
///
/// Handing each child its parent's basis is what the revised simplex is for: a child
/// differs from its parent by one tightened bound, and a bound change leaves the reduced
/// costs alone, so the parent's optimal basis is still dual feasible on the child and the
/// dual simplex only has to repair primal feasibility.
fn kernel_node(
  model : @model.Model,
  options : MipOptions,
  basis : @simplex.SimplexBasis?,
) -> (NodeSolution, @simplex.SimplexBasis?) {
  let kernel_options = @simplex.SimplexOptions::relaxed().limit_iterations(
    options.max_iterations,
  )
  let outcome = match basis {
    Some(warm) => @simplex.solve_model_with_basis(model, kernel_options, warm)
    None => @simplex.solve_model_with(model, kernel_options)
  }
  match outcome {
    Err(_) =>
      (
        {
          status: NodeStatus::Unfinished,
          values: [],
          objective: 0.0,
          duals: [],
          ray: [],
        },
        None,
      )
    Ok(result) =>
      (
        {
          status: match result.status {
            @simplex.SimplexStatus::Optimal => NodeStatus::Optimal
            @simplex.SimplexStatus::Infeasible => NodeStatus::Infeasible
            @simplex.SimplexStatus::Unbounded => NodeStatus::Unbounded
            _ => NodeStatus::Unfinished
          },
          values: result.values,
          objective: result.objective,
          duals: result.duals,
          ray: result.ray,
        },
        result.basis,
      )
  }
}

///|
/// Solves a model with integer variables by branch and bound.
///
/// See the package doc for what the statuses mean: in particular, only `Optimal` claims an
/// answer, and an unbounded relaxation is reported as such rather than as an unbounded
/// model.
pub fn solve_mip(model : @model.Model, options : MipOptions) -> MipResult {
  let issues = model.validate()
  if issues.length() > 0 {
    return {
      status: MipStatus::Invalid,
      values: [],
      objective: 0.0,
      bound: 0.0,
      gap: 0.0,
      nodes: 0,
      verified: 0,
      message: "model is not well formed: " + issues[0],
    }
  }
  let sign = sense_sign(model)
  let nodes : Array[Node] = [
    {
      parent: -1,
      depth: 0,
      variable: -1,
      lb: 0.0,
      ub: 0.0,
      basis: None,
      bound: 0.0,
      key: 0.0,
    },
  ]
  let queue = NodeQueue::new(nodes)
  queue.push(0)
  let mut incumbent : Array[Double] = []
  let mut incumbent_objective = 0.0
  let mut has_incumbent = false
  let mut solved = 0
  let mut verified = 0
  let mut unfinished_nodes = 0
  let mut dives_launched = 0
  while !queue.is_empty() {
    if solved >= options.max_nodes {
      return limit_result(
        nodes, queue, incumbent, incumbent_objective, has_incumbent, solved, verified,
        sign, options,
      )
    }
    let index = queue.pop()
    let node = nodes[index]
    // Pruning by bound before spending a solve on the node: the parent's relaxation
    // objective is an upper (for a minimisation) bound on everything below it.
    if has_incumbent &&
      sign * node.bound >= sign * incumbent_objective - options.tolerance {
      continue
    }
    let problem = node_model(model, nodes, index)
    let (solution, node_basis) = match options.node_solver {
      // A node solver supplied from outside carries no basis, so its children restart.
      Some(injected) => (injected(problem), None)
      None => kernel_node(problem, options, node.basis)
    }
    solved = solved + 1
    // A relaxation that reached no verdict has no claim to check: it is counted open
    // below instead, so a run whose budget cut a relaxation short ends at a limit
    // rather than at "unverified".
    if options.verify_nodes && solution.status != NodeStatus::Unfinished {
      let refusal = node_refusal(problem, solution, options.tolerance)
      if refusal != "" {
        return {
          status: MipStatus::Unverified,
          values: [],
          objective: 0.0,
          bound: node.bound,
          gap: 0.0,
          nodes: solved,
          verified,
          message: "a relaxation's certificate was refused at node " +
          index.to_string() +
          " (depth " +
          node.depth.to_string() +
          "): " +
          refusal,
        }
      }
      verified = verified + 1
    }
    match solution.status {
      NodeStatus::Infeasible => ()
      NodeStatus::Unbounded =>
        return {
          status: MipStatus::UnboundedRelaxation,
          values: incumbent,
          objective: incumbent_objective,
          bound: node.bound,
          gap: if has_incumbent {
            @core.fabs(incumbent_objective - node.bound)
          } else {
            1.0e300
          },
          nodes: solved,
          verified,
          message: "a relaxation is unbounded, which does not prove the integer problem is",
        }
      NodeStatus::Unfinished =>
        // The node could not be judged, so the tree cannot be called exhausted. Recorded
        // and counted, not silently pruned.
        unfinished_nodes = unfinished_nodes + 1
      NodeStatus::Optimal => {
        let fractional = most_fractional(
          problem,
          solution.values,
          options.tolerance,
        )
        if fractional < 0 {
          if !has_incumbent ||
            sign * solution.objective <
            sign * incumbent_objective - options.tolerance {
            incumbent = solution.values
            incumbent_objective = solution.objective
            has_incumbent = true
          }
        } else {
          // Before branching, give the primal heuristic a chance to produce an incumbent:
          // a bound with nothing to compare against prunes nothing, and best-bound search
          // can spend a whole budget without ever standing on a whole point. It only runs
          // while there is no incumbent, because that is the state it exists to fix.
          //
          // Three conditions keep it from being a way of not searching, and each of them is
          // a measurement rather than a tuning constant:
          //
          // - `depth >= fractional` — the walk has to decide every integer the node has not
          //   decided yet, so it is only worth starting where the search has already
          //   decided at least as many. Launched at a shallow node it spends its whole step
          //   budget discovering what the tree was about to discover anyway: on `noswot` the
          //   launch that lands happens at depth 29 with 15 integers left, while the same
          //   rule at depth 0 or 1 (markshare1, pk1, flugpl, blend2, gt2, markshare2) ran
          //   out of steps every time;
          // - `2·fractional <= dive_steps` — at most two relaxations per undecided integer,
          //   because a side that comes back infeasible is undone and the other side tried;
          // - `dive_attempts` launches in total, since the budget the walk spends is the
          //   budget the tree does not get.
          //
          // A launch gets `dive_steps` steps, not the `2·fractional` the condition above
          // computes. That number is a lower bound on the work rather than the work: a step
          // re-solves, and the re-solve can make a *different* variable fractional, so the
          // count does not have to fall every step. Measured over the public instances, the
          // walks that land need the larger number — `pk1` was one fractional variable short
          // of whole after thirty steps and landed within sixty, and `markshare1` and
          // `markshare2` only produced an incumbent at sixty. What the walk spends is what
          // the tree does not get, so it stays bounded by `dive_attempts × dive_steps`.
          if options.dive_steps > 0 &&
            dives_launched < options.dive_attempts &&
            !has_incumbent {
            let fractional = fractional_count(
              problem,
              solution.values,
              options.tolerance,
            )
            let needed = 2 * fractional
            let remaining = options.max_nodes - solved
            let budget = if remaining < options.dive_steps {
              remaining
            } else {
              options.dive_steps
            }
            if needed > 0 &&
              needed <= options.dive_steps &&
              budget > 0 &&
              node.depth >= fractional {
              dives_launched = dives_launched + 1
              let dive = dive_for_incumbent(
                problem, options, solution, node_basis, budget,
              )
              // The dive's relaxations are the run's relaxations: they are solved with the
              // same solver and checked by the same verifier, so they count in both totals
              // and the node budget bounds them.
              solved = solved + dive.relaxations
              verified = verified + dive.verified
              if dive.refusal != "" {
                return {
                  status: MipStatus::Unverified,
                  values: [],
                  objective: 0.0,
                  bound: node.bound,
                  gap: 0.0,
                  nodes: solved,
                  verified,
                  message: "a certificate was refused while the primal heuristic walked node " +
                  index.to_string() +
                  " down to a whole point: " +
                  dive.refusal,
                }
              }
              if dive.values.length() > 0 &&
                (
                  !has_incumbent ||
                  sign * dive.objective <
                  sign * incumbent_objective - options.tolerance
                ) {
                incumbent = dive.values
                incumbent_objective = dive.objective
                has_incumbent = true
              }
              if solved >= options.max_nodes {
                return limit_result(
                  nodes, queue, incumbent, incumbent_objective, has_incumbent, solved,
                  verified, sign, options,
                )
              }
            }
          }
          let value = solution.values[fractional]
          let variable = problem.get_var(fractional)
          let down = floor_of(value)
          let up = ceil_of(value)
          // Two children: `x <= floor(value)` keeps the lower bound and moves the upper
          // one, `x >= ceil(value)` does the mirror image. Each is only pushed when the
          // bound it imposes is inside the range the variable already has, and the bound
          // it keeps is the parent's — replacing both ends is how a child ends up equal
          // to its parent and the tree never shrinks.
          if down >= variable.lb - options.tolerance {
            let ub = if down < variable.lb { variable.lb } else { down }
            nodes.push({
              parent: index,
              depth: node.depth + 1,
              variable: fractional,
              lb: variable.lb,
              ub,
              basis: node_basis,
              bound: solution.objective,
              key: sign * solution.objective,
            })
            queue.push(nodes.length() - 1)
          }
          if up <= variable.ub + options.tolerance {
            let lb = if up > variable.ub { variable.ub } else { up }
            nodes.push({
              parent: index,
              depth: node.depth + 1,
              variable: fractional,
              lb,
              ub: variable.ub,
              basis: node_basis,
              bound: solution.objective,
              key: sign * solution.objective,
            })
            queue.push(nodes.length() - 1)
          }
        }
      }
    }
  }
  if unfinished_nodes > 0 {
    let bound = open_bound(nodes, queue, sign)
    return {
      status: MipStatus::NodeLimit,
      values: incumbent,
      objective: incumbent_objective,
      bound,
      gap: if has_incumbent {
        @core.fabs(incumbent_objective - bound)
      } else {
        1.0e300
      },
      nodes: solved,
      verified,
      message: unfinished_nodes.to_string() +
      " node relaxation(s) did not finish, so the tree is not exhausted",
    }
  }
  if !has_incumbent {
    return {
      status: MipStatus::Infeasible,
      values: [],
      objective: 0.0,
      bound: 0.0,
      gap: 0.0,
      nodes: solved,
      verified,
      message: "every node was pruned without an integer point, so none exists",
    }
  }
  {
    status: MipStatus::Optimal,
    values: incumbent,
    objective: incumbent_objective,
    bound: incumbent_objective,
    gap: 0.0,
    nodes: solved,
    verified,
    message: "",
  }
}

///|
/// The result of a run that stopped at the node limit: the incumbent it has (which is a
/// feasible integer point and is not proven optimal), and the best bound still open.
fn limit_result(
  nodes : Array[Node],
  queue : NodeQueue,
  incumbent : Array[Double],
  incumbent_objective : Double,
  has_incumbent : Bool,
  solved : Int,
  verified : Int,
  sign : Double,
  options : MipOptions,
) -> MipResult {
  // The nodes still in the queue are the uncertainty: the best of their bounds is what the
  // incumbent is measured against.
  let bound = open_bound(nodes, queue, sign)
  {
    status: MipStatus::NodeLimit,
    values: incumbent,
    objective: incumbent_objective,
    bound,
    gap: if has_incumbent {
      @core.fabs(incumbent_objective - bound)
    } else {
      1.0e300
    },
    nodes: solved,
    verified,
    message: "relaxation budget of " +
    options.max_nodes.to_string() +
    " reached with " +
    queue.heap.length().to_string() +
    " tree node(s) still open" +
    (if has_incumbent { "" } else { "; no integer point found yet" }),
  }
}
