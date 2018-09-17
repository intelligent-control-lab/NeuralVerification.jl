abstract type Feasibility end

# General structure for Feasibility Problems
function solve(solver::Feasibility, problem::Problem)
    model = JuMP.Model(solver = solver.optimizer)
    encode(solver, model, problem)
    status = JuMP.solve(model)
    return interpret_result(solver, status)
end

# Presolve to determine the bounds of variables
# This function calls maxSens to compute the bounds
# Bounds are computed AFTER activation function
function get_bounds(problem::Problem)
    solver = MaxSens()
    bounds = Vector{Hyperrectangle}(length(problem.network.layers) + 1)
    bounds[1] = problem.input
    for (i, layer) in enumerate(problem.network.layers)
        bounds[i+1] = forward_layer(solver, layer, bounds[i])
    end
    return bounds
end

#=
Initialize JuMP variables corresponding to neurons and deltas of network for problem
=#
function init_nnet_vars(solver::Feasibility, model::Model, network::Network)
    layers = network.layers
    neurons = Vector{Vector{Variable}}(length(layers) + 1) # +1 for input layer
    deltas  = Vector{Vector{Variable}}(length(layers) + 1)
    # input layer is treated differently from other layers
    input_layer_n = size(first(layers).weights, 2)
    all_layers_n  = [length(l.bias) for l in layers]
    insert!(all_layers_n, 1, input_layer_n)

    for (i, n) in enumerate(all_layers_n)
        neurons[i] = @variable(model, [1:n])
        deltas[i]  = @variable(model, [1:n], Bin)
    end

    return neurons, deltas
end

#=
Add input/output constraints to model
=#
function add_complementary_output_constraint(model::Model, output::AbstractPolytope, neuron_vars::Vector{Variable})
    out_A, out_b = tosimplehrep(output)
    # Needs to take the complementary of output constraint
    # Here let's assume that the output constraint is a half space
    # So the complementary is just out_A * y .> out_b
    @constraint(model, out_A * neuron_vars .<= out_b)
    return nothing
end

function add_input_constraint(model::Model, input::AbstractPolytope, neuron_vars::Vector{Variable})
    in_A,  in_b  = tosimplehrep(input)
    @constraint(model,  in_A * neuron_vars .<= in_b)
    return nothing
end

function add_output_constraint(model::Model, output::AbstractPolytope, neuron_vars::Vector{Variable})
    out_A, out_b = tosimplehrep(output)
    @constraint(model, out_A * neuron_vars .<= out_b)
    return nothing
end