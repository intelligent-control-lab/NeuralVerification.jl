
function constraint_refinement(nnet::Network,
                               reach::Vector{<:SymbolicIntervalGradient},
                               max_violation_con,
                               splits,
                               splits_order=nothing)
    if splits_order === nothing
        i, j, influence = get_max_nodewise_influence(nnet, reach, max_violation_con, splits)
    else
        i,j = splits_order
    end
    # We can generate three more constraints
    # Symbolic representation of node i j is Low[i][j,:] and Up[i][j,:]
    aL, bL = reach[i].sym.Low[j, 1:end-1], reach[i].sym.Low[j, end]
    aU, bU = reach[i].sym.Up[j, 1:end-1], reach[i].sym.Up[j, end]

    # custom intersection function that doesn't do constraint pruning
    ∩ = (set, lc) -> HPolytope([constraints_list(set); lc])

    subsets = [domain(reach[1])] # all the reaches have the same domain, so we can pick [1]

    # If either of the normal vectors is the 0-vector, we must skip it.
    # It cannot be used to create a halfspace constraint.
    # NOTE: how can this come about, and does it mean anything?
    if !iszero(aL)
        subsets = subsets .∩ [HalfSpace(aL, -bL), HalfSpace(aL, -bL), HalfSpace(-aL, bL)]
    end
    if !iszero(aU)
        subsets = subsets .∩ [HalfSpace(aU, -bU), HalfSpace(-aU, bU), HalfSpace(-aU, bU)]
    end
    
    empty_idx = filter(x->isempty(subsets[x]), eachindex(subsets))
    println("empty_idx")
    println(empty_idx)
    (length(empty_idx) > 0) && (subsets[empty_idx] = nothing)
    return subsets
end

function ordinal_split!(solver, problem, branches::Tree, x::Int, max_size::Int, splits_order::Array{Tuple{Int64,Int64},1})

    (domain, splits) = branches.data[x]
    nnet, output = problem.network, problem.output
    
    reach = forward_network(solver, nnet, domain)
    result, max_violation_con = check_inclusion(solver, nnet, last(reach).sym, output)
    # branches.data[x] = (domain, max_violation_con, splits) # because max_violation_con is not calculated before (set as 0)

    result.status == :unknown || return result

    if tree_size(branches) >= max_size
        return BasicResult(:unknown)
    end
    
    k = length(splits)
    subdomains = constraint_refinement(nnet, reach, max_violation_con, splits, splits_order[k+1])
    for (idx, subdomain) in enumerate(subdomains)
        if subdomain === nothing
            continue
        end
        new_splits = copy(splits)
        push!(new_splits, (splits_order[k+1], idx))
        add_child!(branches, x, (subdomain, new_splits)) # we don't calculate the max_violation_con for now.
    end

    for c in branches.children[x]
        result = ordinal_split!(solver, problem, branches, c, max_size, splits_order)
        result.status == :holds || return result # if status == :unknown, means splitting number exceeds max_iter, return unkown directly.
    end
    return BasicResult(:holds)
end

function generate_ordinal_splits_order(nnet, max_branches)
    splits_order = Array{Tuple{Int64,Int64},1}(undef, max_branches)
    k = 0
    for (i,l) in enumerate(nnet.layers)
        for j in 1:n_nodes(l)
            k += 1
            k > max_branches && break
            splits_order[k] = (i,j)
        end
        k > max_branches && break
    end
    return splits_order
end
function init_split(solver, problem, max_branches, splits_order)
    # split sequantially
    branches = Tree((problem.input, Vector()))
    result = ordinal_split!(solver, problem, branches, 1, max_branches, splits_order)
    return result, branches
end

function check_node(solver, problem, node)
    (domain, splits) = node
    reach = forward_network(solver, problem.network, domain)
    result, max_violation_con = check_inclusion(solver, problem.network, last(reach).sym, problem.output)
    return result
end

function check_all_leaves(solver, problem, branches)
    final_result = BasicResult(:holds)
    result_dict = Dict()
    for leaf in branches.leaves
        # println(branches.data[leaf][2])
        result = check_node(solver, problem, branches.data[leaf])
        result_dict[leaf] = result
    end
    println(":holds ", count(x->x[2].status==:holds,result_dict))
    println(":unknown ", count(x->x[2].status==:unknown,result_dict))
    println(":violated ", count(x->x[2].status==:violated,result_dict))
    
    violated_idx = [k for (k,v) in result_dict if v.status==:violated]
    length(violated_idx) > 0 && return result_dict[violated_idx[1]], result_dict
    count(x->x[2].status==:unknown,result_dict) > 0 && return BasicResult(:unknown), result_dict
    return BasicResult(:holds), result_dict
end

function split_given_path(solver, problem, pruned_path)
    # this can be slow because we have to split from the beginning.
    # for example, if we want to merge two paths:
    # 1+2+4+  and  1+2-4+.   We can not directly remove different constraints.
    # Because the activation condition of node 4 is different for  after we split 2+ and 2-.
    # And 1+4+ may not exist, because 4+ can be empty
    nnet, domain, output = problem.network, problem.input, problem.output
    splits = Vector()

    for choice in pruned_path
        (node, sgn) = choice
        reach = forward_network(solver, nnet, domain)
        result, max_violation_con = check_inclusion(solver, nnet, last(reach).sym, output)
        push!(splits, (node, 0)) # set idx=0, because this split_path may not be part of any tree path
        subdomains = constraint_refinement(nnet, reach, max_violation_con, splits, node)
        domain = subdomains[sgn]
        if domain === nothing
            return BasicResult(:holds, )
        end 
    end

    reach = forward_network(solver, nnet, domain)
    result, max_violation_con = check_inclusion(solver, nnet, last(reach).sym, output)
    
    return result, (domain, splits)
end

function merge_holds_nodes_general!(solver, problem, branches, result_dict)
    """
    The split path is in the form:
    ((i1,j1), sgn1), ((i2,j2), sgn2) ...

    (i,j) is the position of the split ReLU node in the network. 
    sgn is the index of the subdomain we choose. 
    In neurify, we split the domain into three subdomains. Therefore, the sign can be 1-3. 

    We denote
        ((i,j), sgn): choice
        (i,j):        node
        sgn:          sign

    To merge paths, we must have 3 holding paths that are only different in one sign.
    To find such paths. We define a dictionary pool.

    pool:   key:   split_path with a choice removed.
            value: [(removed_choice1, path_idx1), (removed_choice2, path_idx2), ... ],
    """
    pool = Dict()
    new_leaves = []
    merged_path_idx = []
    try_cnt = 0
    suc_cnt = 0
    leaves = copy(branches.leaves) # in case the branches.leaves changes in the loop
    for (i, leaf_idx) in enumerate(leaves)
        leaf = branches.data[leaf_idx]
        result_dict[leaf_idx].status == :holds || continue
        (domain, split_path) = leaf
        # println(split_path)
        for j in 1:length(split_path)
            pruned_path = [split_path[1:j-1]; split_path[j+1:end]]  # remove a choice from the split path, then use the pruned path as the key.
            if haskey(pool, pruned_path)  # check all paths that has the same pruned path
                choice_idx = findall(x -> x[1][1]==split_path[j][1], pool[pruned_path])  # find choices that have the same node
                if length(choice_idx) == 2 # find two nodes, that is, all sign of this node hold, possible to merge
                    # println("find identical")
                    # println("split_path")
                    # println(split_path)
                    # println("split_path[j]")
                    # println(split_path[j])
                    idx = [[x[2] for x in pool[pruned_path][choice_idx]]; leaf_idx]  # get all mergable leaf idx
                    idx = filter(x->!(x in merged_path_idx), idx) # remove paths that are already merged
                    length(idx) == 3 || continue 
                    # println("idx (if consecutive, we are actually replacing three leaves with their parent)")
                    println(idx)
                    result, merged_node = split_given_path(solver, problem, pruned_path)
                    # println("merge result")
                    # println(result)
                    try_cnt += 1
                    result.status == :holds || continue
                    suc_cnt += 1
                    merged_path_idx = [merged_path_idx; idx]
                    # println("merged_node")
                    # println(merged_node)
                    id = add_child!(branches, idx[1], merged_node)# remove idx[1] from leaves, set parent of the merged_node as idx[1]
                    connect!(branches, idx[2], id)  # to remove idx[2] from leaves
                    connect!(branches, idx[3], id)  # to remove idx[3] from leaves
                end
            else
                pool[pruned_path] = []
            end
            push!(pool[pruned_path], (split_path[j], leaf_idx))  # store (removed_choice, leaf_idx) as the value.
        end
    end
    println("try merge: ", try_cnt)
    println("success:   ", suc_cnt)
    return [filter(x->!(x in merged_path_idx), branches.leaves); new_leaves]
end

function merge_holds_nodes!(solver, problem, branches, result_dict)
    """
    If all the siblings of a leaf node and itself hold, try to replace them with their parent.
    """
    holds_cnt = zeros(branches.size)
    branches.size == 1 && return
    leaves = copy(branches.leaves)
    try_cnt = 0
    suc_cnt = 0
    while !isempty(leaves)
        leaf = pop!(leaves)
        result_dict[leaf].status == :holds || continue
        # println(leaf, ' ', branches.parent[leaf])
        holds_cnt[branches.parent[leaf]] += 1
        if holds_cnt[branches.parent[leaf]] == 3
            # println("try to merge")
            try_cnt += 1
            result, max_violation_con = check_node(solver, problem, branches.data[branches.parent[leaf]])
            # result = BasicResult(:holds) # to test split
            result.status == :holds || continue
            # println("merge success")
            suc_cnt += 1
            # println("branches.parent[leaf]")
            # println(branches.parent[leaf])
            # println("before")
            # println(branches.leaves)
            result_dict[branches.parent[leaf]] = result
            push!(leaves, branches.parent[leaf])
            delete_all_children!(branches, branches.parent[leaf])
            # println("after")
            # println(branches.leaves)
        end
    end
    println("try merge: ", try_cnt)
    println("success:   ", suc_cnt)
end

function solve(problems::TrainingProblem, max_branches=50, fix_branch=true, branch_management=false, perturbation_tolerence=false, incremental_computation=false)
    
    solver = Neurify(max_iter = 1) # max_iter=1 because we are doing branch management outside.
    
    problems = TrainingProblem(problems.networks, convert(HPolytope, problems.input), convert(HPolytope, problems.output))

    cnt = 0
    total_time = 0

    sat_idx = []
    vio_idx = []
    tim_idx = []
    err_idx = []
    tim_rec = []
    sat_rec = []

    problem = Problem(problems.networks[1], problems.input, problems.output)
    splits_order = generate_ordinal_splits_order(problems.networks[1], max_branches)
    result, branches = init_split(solver, problem, max_branches, splits_order)
    # println(solve(solver, problem))
    
    for (i, nnet) in enumerate(problems.networks)
        
        println("====")

        problem = Problem(nnet, problems.input, problems.output)

        timed_result = @timed check_all_leaves(solver, problem, branches)
        result, result_dict = timed_result.value
        total_time += timed_result.time

        # for leaf in branches.leaves
        #     println(leaf, ' ', result_dict[leaf].status)
        # end
        # println("====")

        append!(tim_rec, timed_result.time)
        # println("Output: ")
        # println(result)
        # println("")

        # println(branches.size)
        merge_holds_nodes!(solver, problem, branches, result_dict) # try to merge holds nodes to save memory resources.
        # merge_holds_nodes_general!(solver, problem, branches, result_dict) # try to merge holds nodes to save memory resources.
        # break
        # println(branches.size)
        # println(result_dict)
        unknown_leaves = [k for (k,v) in result_dict if v.status==:unknown] # because branches.leaves may change in the split process
        # println(unknown_leaves)
        for leaf in unknown_leaves
            # println(leaf, ' ', result_dict[leaf].status)
            result_dict[leaf].status == :unknown && ordinal_split!(solver, problem, branches, leaf, max_branches, splits_order) # split unknown nodes
        end

        # println(branches.size)

        if result.status == :violated 
            noisy = NeuralVerification.compute_output(nnet, result.counter_example)
            append!(vio_idx, i)
            # println("======== found counter example ========")
            # println("index: " * string(i))
            # println("Time: " * string(timed_result[2]) * " s")
            # println("counter_pred   ", noisy[:,:]')
            # println("=======================================")
        elseif result.status == :unknown
            append!(tim_idx, i)
            # println("Timed out")
        else
            append!(sat_idx, i)
            # println("Holds")
        end
    end

    return total_time, sat_idx, vio_idx, tim_idx

end


function solve(solver, problem::Problem, branches = nothing)
    problem = Problem(problem.network, convert(HPolytope, problem.input), convert(HPolytope, problem.output))
    reach_lc = problem.input.constraints
    output_lc = problem.output.constraints
    n = size(reach_lc, 1)
    m = size(reach_lc[1].a, 1)
    model = Model(GLPK.Optimizer)
    @variable(model, x[1:m], base_name="x")
    @constraint(model, [i in 1:n], reach_lc[i].a' * x <= reach_lc[i].b)

    reach, last_reach = forward_network(solver, problem.network, problem.input, true)

    result, max_violation_con = check_inclusion(solver, reach.sym, problem.output, problem.network) # This calls the check_inclusion function in ReluVal, because the constraints are Hyperrectangle
    result.status == :unknown || return result, branches

    if branches === nothing
        branches = Tree((last_reach, Vector()))
    end

    # check all existing branches, find the leaves whose status is unknown
    result, unknown_leaves = dfs_check(solver, problem, branches, 1)

    result.status == :unknown || return result, branches

    for leaf in unknown_leaves
        result = dfs_split(solver, problem, branches, leaf, solver.max_iter)
        result.status == :holds || return result, branches
    end

    return BasicResult(:holds), branches
end