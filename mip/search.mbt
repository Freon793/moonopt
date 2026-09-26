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
/// Whether a run may spend its reserve on one more walk.
///
/// The reserve exists for one state: the run has spent half its budget and does not have a single
/// integer point, so there is nothing to prune against and nothing to report — the state the
/// reports show for `blend2`, whose row says "no integer point found yet" and whose gap is the
/// `1e300` sentinel. A walk is worth taking there, but only a walk that can *finish*: a launch
/// cut short by the reserve discovers what the tree was about to discover anyway, which is why
/// the reserve has to be able to afford `dive_steps` steps before it is used at all. That
/// condition is also what keeps the policy out of small budgets: at 300 nodes the reserve is 18
/// steps, less than one walk, and the run is left alone.
fn reserve_allows_walk(
  extra_dive_budget : Int,
  dive_steps : Int,
  solved : Int,
  max_nodes : Int,
) -> Bool {
  extra_dive_budget >= dive_steps && solved * 2 >= max_nodes
}

///|
/// How much of the root bound one round of cuts has to add before another round is started.
///
/// Measured by counting the root bound after each round on four instances (the `--max-nodes r+2`
/// probe): `khb05250` adds 5.6%, 2.4%, 1.5%, 0.4%, 0.3% over its first five rounds and its proof
/// costs 305 nodes after two rounds, 185 after three and 114 after four; `p0201` adds 2.9%, 1.3%,
/// 0.5%, 0.8%, 0.5% and its proof costs 586 nodes after two rounds against 1135 after three;
/// `flugpl` adds 0.3%, 0.05%, 0.02% and costs 13806 against 14938; `dcmulti` adds 0.7%, 0.3%,
/// 0.03%, 0.04%, 0.18%. A round that adds a percent of the bound does not pay for the tree it
/// costs — and the instances that keep adding it are exactly the ones whose proof gets cheaper.
let cut_round_gain : Double = 0.014

///|
/// The number of rounds a run does whatever that measurement says, which is the number the
/// default always ran: two. The test can only stop rounds *after* these, so a run whose cuts stop
/// paying early is left exactly as it was.
let cut_rounds_always : Int = 2

///|
/// Whether a round that has just been taken is worth following with another one.
fn another_round_pays(round : Int, added : Double) -> Bool {
  round < cut_rounds_always || added >= cut_round_gain
}

///|
/// How much longer than an ordinary relaxation the re-solve that decides a cut round may run.
///
/// The re-solve is one relaxation per round whose verdict decides whether a whole round of cuts is
/// kept, and a verdict of "did not finish" says nothing about the round — it says the round's model
/// did not fit in the cap every relaxation is given. Measured on `mod010` at 300 nodes, where the
/// report hands each relaxation 5000 iterations: its second round's re-solve does not finish, the
/// round is discarded, and the run ends at the budget with a bound of `6540.400000106969` against a
/// published optimum of `6548`; 6000 and 7000 change nothing, and at 20000 the round is kept and
/// the instance is proved **in 31 nodes**. The cap is paid once per round, so the whole run spends
/// at most `cut_rounds × cut_round_iteration_factor × max_iterations` iterations on it — rounds,
/// not nodes.
let cut_round_iteration_factor : Int = 4

///|
/// The iteration cap a cut round's re-solve gets.
fn cut_round_iteration_cap(max_iterations : Int) -> Int {
  max_iterations * cut_round_iteration_factor
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
/// The best bound still open, in the model's own sense: the smallest key over the queue and
/// over the regions the run left without a verdict. This is what an unfinished run's incumbent
/// has to be measured against, because every remaining node is somewhere below its own bound.
///
/// `unjudged` holds the keys of nodes that were popped and never answered. Such a node is not
/// re-queued — solving it again would repeat the same work — but the region below it is still
/// unexplored, and the bound it was queued with (its parent's relaxation objective) bounds
/// every point in that region. Leaving those keys out reported a bound the run had not
/// established, and in the direction that flatters it: this is a best-bound search, so the
/// nodes that fail early are the ones with the smallest keys, and the smallest key is exactly
/// what this function returns. On the small manifest `blend2` and `noswot` end at the node
/// budget with 34 and 93 such nodes, so the bound those rows reported was the best of a
/// strictly smaller open set than the one the run actually had.
fn open_bound(
  nodes : Array[Node],
  queue : NodeQueue,
  unjudged : Array[Double],
  sign : Double,
) -> Double {
  let mut best = 0.0
  let mut seen = false
  for k = 0; k < queue.heap.length(); k = k + 1 {
    let key = nodes[queue.heap[k]].key
    if !seen || key < best {
      best = key
      seen = true
    }
  }
  for k = 0; k < unjudged.length(); k = k + 1 {
    if !seen || unjudged[k] < best {
      best = unjudged[k]
      seen = true
    }
  }
  // An open set that is empty keeps the `0.0` this function has always returned for "the run
  // has not established a bound at all".
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
/// `true` when the repair left the multipliers exactly as they were.
///
/// Written out rather than compared with `==`: what is being asked is whether the repair
/// changed the certificate, and that is a question about the numbers, not about which array
/// is which.
fn unchanged(before : Array[Double], after : Array[Double]) -> Bool {
  if before.length() != after.length() {
    return false
  }
  for i = 0; i < before.length(); i = i + 1 {
    if before[i] != after[i] {
      return false
    }
  }
  true
}

///|
/// The certificate check of one node, or the verifier's account of why it refused.
///
/// The claim follows the relaxation's status, and the numbers come from the relaxation
/// itself. Nothing here shares state with the solver: `@verify` reads the model and these
/// arrays.
///
/// The run's own certificate is offered **first**, and the repair (`repaired_duals`) is only
/// tried when the checker refuses that: a degenerate optimum's dual is not unique, and a
/// simplex can land on a point in that face a few parts in `1e7` outside the sign
/// convention, which the checker refuses while its own duality gap comes out at `1e-13`.
/// Repairing unconditionally got the order wrong and paid for it — the clamp's own size is
/// `violation · cost_scale / row_sign_scale`, so on a model whose objective is large it can
/// remove a multiplier of real size and turn a certificate the checker would have accepted
/// into one it refuses on a *different* check (complementarity, on `blend2` node 30782:
/// `2.96e-6`). Repair the refusals, not the acceptances.
///
/// Either way the checker judges what it is given, and if both attempts are refused the run
/// stops with the refusal of the run's own certificate, because that is the one the solver
/// actually produced.
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
  let offered : @verify.Certificate = {
    claim,
    values: solution.values,
    duals: solution.duals,
    ray: solution.ray,
    objective: solution.objective,
  }
  let verdict = @verify.verify(model, offered, tolerance~)
  if verdict.accepted {
    return ""
  }
  let repaired = repaired_duals(model, solution, tolerance)
  if unchanged(solution.duals, repaired.duals) {
    return verdict.reason
  }
  let cleaned : @verify.Certificate = {
    claim,
    values: repaired.values,
    duals: repaired.duals,
    ray: repaired.ray,
    objective: repaired.objective,
  }
  let retried = @verify.verify(model, cleaned, tolerance~)
  if retried.accepted {
    ""
  } else {
    // Both are named. A refusal is a diagnosis, and the next person to look at it should not
    // have to reproduce the run to find out that the repair was tried and also refused — or
    // on what.
    verdict.reason + " (the repaired certificate: " + retried.reason + ")"
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

///|
/// Tightens a node's variables with the incumbent's cutoff, and says whether anything is left.
///
/// Every point still worth finding is better than the incumbent, and that is a constraint on
/// the objective. The objective is a sum of one term per variable, so bounding one term by the
/// cutoff and the *smallest value the other terms could take over their own boxes* bounds that
/// single variable. It is the information a cutoff row would carry, spent on the box instead of
/// on a new row: a row is only active where the relaxation already knows it can beat the
/// incumbent, while a narrowed box also narrows the branching that follows — and it needs no
/// certificate of its own, because what the node is handed is still a model with bounds.
///
/// This is not a claim about the model's feasible set. The cutoff comes from the incumbent, and
/// an incumbent is a point the search verified against the model it was given; what the
/// tightening drops are *integer* points that cannot beat it, which is exactly what a search
/// for a better point is allowed to ignore. The box is only ever narrowed, never widened, and
/// when it comes out empty the node holds nothing better — pruned with no solve at all.
fn propagate_cutoff(
  model : @model.Model,
  sign : Double,
  incumbent_objective : Double,
  tolerance : Double,
) -> Bool {
  let terms = model.objective()
  if terms.length() == 0 {
    return true
  }
  let cutoff = sign * incumbent_objective
  // The smallest each term can be over its own box, and the sum of those minima. A term whose
  // variable has no bound on the side its coefficient needs has no minimum, and then neither
  // has the sum: there is no cutoff argument to make here, so nothing is changed.
  let minima : Array[Double] = Array::make(terms.length(), 0.0)
  let total = @core.CompensatedSum::new()
  for k = 0; k < terms.length(); k = k + 1 {
    let (variable, coefficient) = terms[k]
    let value = sign * coefficient
    let bounds = model.get_var(variable)
    let minimum = if value > 0.0 {
      if has_lower_bound(bounds.lb) {
        value * bounds.lb
      } else {
        return true
      }
    } else if value < 0.0 {
      if has_upper_bound(bounds.ub) {
        value * bounds.ub
      } else {
        return true
      }
    } else {
      0.0
    }
    minima[k] = minimum
    total.add(minimum)
  }
  let sum_of_minima = total.value()
  for k = 0; k < terms.length(); k = k + 1 {
    let (variable, coefficient) = terms[k]
    let value = sign * coefficient
    if value == 0.0 {
      continue
    }
    // `value · x_k ≤ cutoff − (everything else's smallest possible value)`.
    let budget = cutoff - (sum_of_minima - minima[k])
    let bounds = model.get_var(variable)
    if value > 0.0 {
      let candidate = budget / value
      if candidate < bounds.ub - tolerance * (1.0 + @core.fabs(bounds.ub)) {
        model.set_var_bounds(variable, bounds.lb, candidate)
      }
    } else {
      let candidate = budget / value
      if candidate > bounds.lb + tolerance * (1.0 + @core.fabs(bounds.lb)) {
        model.set_var_bounds(variable, candidate, bounds.ub)
      }
    }
    // An integer variable whose box no longer holds a whole number, or any variable whose box
    // came out reversed, has no point that could beat the incumbent.
    let after = model.get_var(variable)
    if after.lb > after.ub + tolerance * (1.0 + @core.fabs(after.ub)) {
      return false
    }
    if after.is_int && ceil_of(after.lb) > floor_of(after.ub) + tolerance {
      return false
    }
  }
  true
}

///|
/// Solves one node's relaxation. `iterations` overrides the run's per-relaxation cap, which the
/// cut round's retry uses.
fn kernel_node(
  model : @model.Model,
  options : MipOptions,
  basis : @simplex.SimplexBasis?,
  iterations? : Int = 0,
) -> (NodeSolution, @simplex.SimplexBasis?) {
  let cap = if iterations > 0 { iterations } else { options.max_iterations }
  let kernel_options = @simplex.SimplexOptions::relaxed().limit_iterations(cap)
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
      cuts: 0,
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
  // The keys of the nodes that were popped and never answered. They are part of the open set
  // the reported bound is taken over, even though they are no longer in the queue: see
  // `open_bound`.
  let unjudged : Array[Double] = []
  let mut dives_launched = 0
  // What a run keeps in reserve for the walks it takes *after* it has spent half its budget
  // without finding a single integer point — the state the reports show for `blend2`, a bound
  // with nothing to measure it against. The launch conditions below say when a walk is worth
  // starting, not when it is worth trying: with no point at all, an extra walk is the only
  // thing the run can learn about the answer from, and its cost is a *share* of the budget
  // (`max_nodes / 16`) rather than a count, because the same count is a sixteenth of the
  // budget at 20000 nodes and all of it at 300.
  let mut extra_dive_budget = options.max_nodes / 16
  // The model the tree is built on: the caller's model plus the cuts the root earned.
  // Every node below the root is rebuilt from this one, so a cut added here is inherited
  // by the whole tree — which is exactly why it has to be checked before it lands.
  let mut root_model = model.clone()
  let mut cuts_added = 0
  while !queue.is_empty() {
    if solved >= options.max_nodes {
      return limit_result(
        nodes, queue, unjudged, incumbent, incumbent_objective, has_incumbent, solved,
        verified, unfinished_nodes, cuts_added, sign, options,
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
    let mut problem = node_model(root_model, nodes, index)
    // The incumbent's cutoff, spent on the node's box before the node is solved. A node the
    // cutoff empties holds nothing better than the incumbent and costs no solve at all.
    if has_incumbent &&
      !propagate_cutoff(problem, sign, incumbent_objective, options.tolerance) {
      continue
    }
    let (started, started_basis) = match options.node_solver {
      // A node solver supplied from outside carries no basis, so its children restart.
      Some(injected) => (injected(problem), None)
      None => kernel_node(problem, options, node.basis)
    }
    let mut solution = started
    let mut node_basis = started_basis
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
          cuts: cuts_added,
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
    // Root cuts. The relaxation at the root decides every node below it, so one round of
    // tightening there is worth more than tightening any other node, and cutting only at
    // the root is what keeps the tree's "a node is its parent plus one bound" shape and
    // the warm starts between nodes intact. A cut is added only after
    // `@verify.verify_cut` has re-derived it from the witness the tableau gave; a
    // disagreement stops the run, because a cut nothing downstream can check is the one
    // way this search could return a wrong answer without anyone noticing.
    //
    // A round is kept only if it pays: the cuts go into a copy of the root, the copy is
    // re-solved, and unless that relaxation comes back optimal *and* better than the one
    // the cuts were taken from, the whole round is thrown away and the tree is built on the
    // model as it was. That is not a detail. Adding rows to a degenerate relaxation can cost
    // more pivots than it saves — on `noswot` a round of twenty cuts left the root's
    // re-solve unfinished, which under the plain version of this code ended the run at the
    // limit after three relaxations with no bound at all, a strictly worse answer than
    // never having asked. A discarded round still spent its relaxations, so they are
    // counted and verified like any other; what is not kept is the model change.
    if options.cut_rounds > 0 &&
      index == 0 &&
      solution.status == NodeStatus::Optimal {
      let mut round = 0
      let mut keep_going = true
      while keep_going && round < options.cut_rounds {
        round = round + 1
        match node_basis {
          // No basis means no tableau to round from: a test's injected node solver, or a
          // relaxation that reached no verdict. Nothing to do, nothing to refuse.
          None => keep_going = false
          Some(basis) => {
            let cuts = match cut_round(problem, solution, basis, options) {
              Err(reason) =>
                return {
                  status: MipStatus::Unverified,
                  values: [],
                  objective: 0.0,
                  bound: node.bound,
                  gap: 0.0,
                  nodes: solved,
                  verified,
                  cuts: cuts_added,
                  message: reason,
                }
              Ok(cuts) => cuts
            }
            if cuts.length() == 0 {
              keep_going = false
            } else {
              let candidate = root_model.clone()
              for cut in cuts {
                candidate.add_named_constraint(
                  cut.terms,
                  cut.rel,
                  cut.rhs,
                  "cut",
                )
              }
              // The added rows changed the shape of the problem, so the basis the
              // relaxation ended on no longer describes it: this re-solve is cold on
              // purpose, and it is counted and verified like every other relaxation.
              let before_bound = solution.objective
              let tightened_problem = node_model(candidate, nodes, index)
              // The re-solve gets a longer cap than a node's relaxation: its verdict is what
              // decides whether the whole round is kept, and "did not finish" is a statement
              // about the cap rather than about the round (`cut_round_iteration_factor` carries
              // the measurement).
              let (tightened, tightened_basis) = kernel_node(
                tightened_problem,
                options,
                None,
                iterations=cut_round_iteration_cap(options.max_iterations),
              )
              solved = solved + 1
              let mut refused = ""
              if options.verify_nodes &&
                tightened.status != NodeStatus::Unfinished {
                refused = node_refusal(
                  tightened_problem,
                  tightened,
                  options.tolerance,
                )
                if refused == "" {
                  verified = verified + 1
                }
              }
              if refused != "" {
                return {
                  status: MipStatus::Unverified,
                  values: [],
                  objective: 0.0,
                  bound: node.bound,
                  gap: 0.0,
                  nodes: solved,
                  verified,
                  cuts: cuts_added,
                  message: "the relaxation of the cut root was refused: " +
                  refused,
                }
              }
              // Whether the round is kept. Adding valid cuts can only shrink the feasible
              // region of a relaxation, so a relaxed optimum that *moved the wrong way* is
              // arithmetic rather than information, and a re-solve that reached no verdict
              // says nothing at all: both are thrown away rather than believed. Within
              // that, a round is kept even when the root's own optimum did not move,
              // because the cut that is slack at one optimum can still cut a deeper
              // node's — on `pk1` a round that left the root's objective where it was
              // took the incumbent from 45 to 36 further down the tree.
              let resolved = tightened.status == NodeStatus::Optimal
              let not_worse = sign * tightened.objective >=
                sign * solution.objective -
                options.tolerance * (1.0 + @core.fabs(solution.objective))
              let paid = resolved && not_worse
              if paid {
                root_model = candidate
                problem = tightened_problem
                solution = tightened
                node_basis = tightened_basis
                cuts_added = cuts_added + cuts.length()
                // What this round added to the root bound, in the model's own sense. A further
                // round is only *started* while that is worth its cost; the first
                // `cut_rounds_always` rounds happen whatever it says, so the measured behaviour
                // of a run whose cuts stop paying early does not change.
                let added = sign *
                  (tightened.objective - before_bound) /
                  (1.0 + @core.fabs(before_bound))
                if !another_round_pays(round, added) {
                  keep_going = false
                }
              } else {
                keep_going = false
              }
              if solved >= options.max_nodes {
                return limit_result(
                  nodes, queue, unjudged, incumbent, incumbent_objective, has_incumbent,
                  solved, verified, unfinished_nodes, cuts_added, sign, options,
                )
              }
              // Either the tightened relaxation is whole (the round has done its job and
              // the branch below picks the incumbent up) or it is not worth another
              // round of the same rows.
              if !paid ||
                most_fractional(problem, solution.values, options.tolerance) < 0 {
                keep_going = false
              }
            }
          }
        }
      }
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
          cuts: cuts_added,
          message: "a relaxation is unbounded, which does not prove the integer problem is",
        }
      NodeStatus::Unfinished => {
        // The node could not be judged, so the tree cannot be called exhausted. Recorded
        // and counted, not silently pruned — and its bound stays open with it: the node is not
        // re-queued (a second solve would repeat the same work and reach the same verdict), but
        // the region below it is unexplored, and the bound it was queued with is the parent's
        // relaxation objective, which bounds that whole region.
        unfinished_nodes = unfinished_nodes + 1
        unjudged.push(node.key)
      }
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
            !has_incumbent &&
            (
              dives_launched < options.dive_attempts ||
              reserve_allows_walk(
                extra_dive_budget,
                options.dive_steps,
                solved,
                options.max_nodes,
              )
            ) {
            let fractional = fractional_count(
              problem,
              solution.values,
              options.tolerance,
            )
            let needed = 2 * fractional
            let remaining = options.max_nodes - solved
            // Walks past `dive_attempts` are paid out of the reserve, and the reserve is only
            // ever opened when it can afford a whole walk — so every launch here gets the same
            // step budget the first ones get, and the last one cannot overdraw.
            let wanted = options.dive_steps
            let budget = if remaining < wanted { remaining } else { wanted }
            if needed > 0 &&
              needed <= options.dive_steps &&
              budget > 0 &&
              node.depth >= fractional {
              dives_launched = dives_launched + 1
              let dive = dive_for_incumbent(
                problem, options, solution, node_basis, budget,
              )
              if dives_launched > options.dive_attempts {
                extra_dive_budget = extra_dive_budget - dive.relaxations
              }
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
                  cuts: cuts_added,
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
                  nodes, queue, unjudged, incumbent, incumbent_objective, has_incumbent,
                  solved, verified, unfinished_nodes, cuts_added, sign, options,
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
    let bound = open_bound(nodes, queue, unjudged, sign)
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
      cuts: cuts_added,
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
      cuts: cuts_added,
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
    cuts: cuts_added,
    message: "",
  }
}

///|
/// The result of a run that stopped at the node limit: the incumbent it has (which is a
/// feasible integer point and is not proven optimal), and the best bound still open.
fn limit_result(
  nodes : Array[Node],
  queue : NodeQueue,
  unjudged : Array[Double],
  incumbent : Array[Double],
  incumbent_objective : Double,
  has_incumbent : Bool,
  solved : Int,
  verified : Int,
  unfinished : Int,
  cuts_added : Int,
  sign : Double,
  options : MipOptions,
) -> MipResult {
  // The nodes still in the queue, and the regions whose node reached no verdict, are the
  // uncertainty: the best of their bounds is what the incumbent is measured against.
  let bound = open_bound(nodes, queue, unjudged, sign)
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
    cuts: cuts_added,
    message: "relaxation budget of " +
    options.max_nodes.to_string() +
    " reached with " +
    queue.heap.length().to_string() +
    " tree node(s) still open" +
    // A budget that ran out while relaxations were reaching no verdict leaves two kinds of open
    // work behind, and the counts alone do not say which: the message names both, the same way a
    // run whose queue emptied under it does.
    (if unfinished > 0 {
      ", and " + unfinished.to_string() + " relaxation(s) reached no verdict"
    } else {
      ""
    }) +
    (if has_incumbent { "" } else { "; no integer point found yet" }),
  }
}
