# # Thermal-hypoelasticity driven beam bending.
# ![global](te.mp4)
#
# Combining thermal conduction and linear elasticity, we can do a thermal induced beam bending.
# The source is [here](https://github.com/jxx2/MetaFEM.jl/tree/main/examples/thermal_elasticity)
# ## Geometry
# The geometry in the same as the cantilever case.
using MetaFEM
initialize_Definitions!()

fem_domain = FEM_Domain(dim = 3)
L_box, e_number, LW_ratio = 1., 10, 10
domain_size = (L_box * LW_ratio, L_box, L_box) 
element_number = (Int(e_number * LW_ratio / 4), e_number, e_number)
element_shape = :CUBE

vert, connections = make_Brick(domain_size, element_number, element_shape)
@time ref_mesh = construct_TotalMesh(vert, connections)

@Takeout (vertices, faces) FROM ref_mesh
facet_IDs = get_BoundaryMesh(ref_mesh)
vIDs = faces.vertex_IDs[:, facet_IDs] 

x1_mean = vec(sum(vertices.x1[vIDs], dims = 1)) ./ size(faces.vertex_IDs, 1)
x2_mean = vec(sum(vertices.x2[vIDs], dims = 1)) ./ size(faces.vertex_IDs, 1)
x3_mean = vec(sum(vertices.x3[vIDs], dims = 1)) ./ size(faces.vertex_IDs, 1)

err_scale = L_box / e_number * 0.01

facet_IDs_left = facet_IDs[(x1_mean .< err_scale) .& (x1_mean .> (.- err_scale))]
facet_IDs_right = facet_IDs[(x1_mean .< (L_box * LW_ratio .+ err_scale)) .& (x1_mean .> (L_box * LW_ratio .- err_scale))]
facet_IDs_front = facet_IDs[(x2_mean .< err_scale) .& (x2_mean .> (.- err_scale))]
facet_IDs_back = facet_IDs[(x2_mean .< (L_box .+ err_scale)) .& (x2_mean .> (L_box .- err_scale))]
facet_IDs_bottom = facet_IDs[(x3_mean .< err_scale) .& (x3_mean .> (.- err_scale))]
facet_IDs_top = facet_IDs[(x3_mean .< (L_box .+ err_scale)) .& (x3_mean .> (L_box .- err_scale))]

wp_ID = add_WorkPiece!(ref_mesh; fem_domain = fem_domain)
fix_bg_ID = add_Boundary!(wp_ID, facet_IDs_left; fem_domain = fem_domain) #left fixed
free_bg_ID = add_Boundary!(wp_ID, vcat(facet_IDs_bottom, facet_IDs_top, facet_IDs_right); fem_domain = fem_domain) #bottom & right & front free
thermal_bg_ID = add_Boundary!(wp_ID, vcat(facet_IDs_front, facet_IDs_back); fem_domain = fem_domain) #back will be loaded
# ## Physics
# The mathematical formulation is:
# ```math
# \text{variable}\quad d_i T
# ```
# ```math
# \epsilon_{ij}=\frac{d_{i,j}+d_{j,i}}{2}-\alpha*T*\delta_{ij},\qquad\sigma_{ij}=\lambda\delta_{ij}\epsilon_{mm}+2\mu\epsilon_{ij}
# ```
# ```math
# (d_{i,j},\sigma_{ij})+(d_i,\rho * c*\frac{\partial d_i}{\partial t})+C(T,\frac{\partial T}{\partial t}) + k(T_{,i}, T_{,i})=0,\qquad in\quad\Omega
# ```
# ```math
# (T,h(T - Te)) = 0,\qquad on\quad(\partial\Omega)_{thermal}
# ```
# ```math
# (d_i,\tau*d_i)=0,\qquad on\quad(\partial\Omega)_{fix}
# ```
# The code is:
Δx = L_box / e_number
E = 210e3 
ν = 0.
λ = E * ν / ((1 + ν) * (1 - 2 * ν))
μ = E / (2 * (1 + ν))
τᵇ = 1000 * E / L_box
ρ = 1e3
c = 
h = 100.
C = 1000
k = 100.
α = 0.05e-3

@Sym d T
@External_Sym (Te, CONTROLPOINT_VAR)

@Def begin
    ε{i,j} = (d{i;j} + d{j;i}) / 2. - α * T * δ{i,j}
    σ{i,j} = λ * δ{i,j} * ε{m,m} + 2. * μ * ε{i,j}

    heat_dissipation = C * Bilinear(T, T{;t}) + k * Bilinear(T{;i}, T{;i}) 
    elasticity = Bilinear(ε{i,j}, σ{i,j}) + Bilinear(d{i}, ρ * (c * d{i;t}))

    domain = heat_dissipation + elasticity
    conv_bdy = h * Bilinear(T, T - Te)  # free wall with environment temperature
    fixed_bdy = τᵇ * Bilinear(d{i}, d{i}) # (d, d - 0) where 0 is the wall displacement, denoting fixed, adiabatic wall 
end

@time begin
    assign_WorkPiece_WeakForm!(wp_ID, domain; fem_domain = fem_domain)
    assign_Boundary_WeakForm!(wp_ID, fix_bg_ID, fixed_bdy; fem_domain = fem_domain)
    assign_Boundary_WeakForm!(wp_ID, thermal_bg_ID, conv_bdy; fem_domain = fem_domain)
end
initialize_LocalAssembly!(fem_domain)
# ## Assembly
@time mesh_Classical([wp_ID]; shape = element_shape, itp_type = :Serendipity, itp_order = 2, itg_order = 5, fem_domain = fem_domain)
compile_Updater_GPU(; domain_ID = 1, fem_domain = fem_domain)[2]

@time begin
    wp = fem_domain.workpieces[1]
    update_Mesh(fem_domain.dim, wp, wp.element_space)
    assemble_Global_Variables!(; fem_domain = fem_domain)
end
# ## Run & Gather Data
fem_domain.linear_solver = x -> iterative_Solve!(x; Sv_func! = bicgstabl_GS!, maxiter = 2000, max_pass = 20, s = 8)

fem_domain.globalfield.converge_tol = 1e-6
fem_domain.globalfield.x .= 0
dessemble_X!(fem_domain.workpieces, fem_domain.globalfield)

dx = L_box/e_number
err_scale = 0.05 * dx

cpts = fem_domain.workpieces[1].mesh.controlpoints
front_cp_IDs = findall((cpts.x2 .> - err_scale) .& (cpts.x2 .< err_scale * dx) .& cpts.is_occupied)
cpts.Te[front_cp_IDs] .= 300

counter = 0
fem_domain.globalfield.dt = 1
while true
    counter += 1

    wp = fem_domain.workpieces[1]
    write_VTK("$(@__DIR__)\\history\\3D_MetaFEM_Result_$counter.vtk", wp; scale = 100, shift_sym = :d)

    update_OneStep!(fem_domain.time_discretization; fem_domain = fem_domain, max_iter = 3)
    dessemble_X!(fem_domain.workpieces, fem_domain.globalfield)

    println("-------------------------$counter-----------------")
    Ttmax = maximum(abs.(cpts.T_t))
    umax = maximum(abs.(cpts.d2_t))
    (umax < 1e-4) && (Ttmax < 1e-2) && break
end
dessemble_X!(fem_domain.workpieces, fem_domain.globalfield)
