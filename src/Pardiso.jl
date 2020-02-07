__precompile__()

module Pardiso

if !isfile(joinpath(@__DIR__, "..", "deps", "deps.jl"))
    error("""please run Pkg.build("Pardiso") before loading the package""")
end

include("../deps/deps.jl")

function show_build_log()
    logfile = joinpath(@__DIR__, "..", "deps", "build.log")
    if !isfile(logfile)
        error("no log file found")
    else
        println(read(logfile, String))
    end
end

using Libdl
using SparseArrays
using LinearAlgebra
import Base.show

if !LOCAL_MKL_FOUND
    import MKL_jll
end

if Sys.iswindows()
    const libmkl_rt = "mkl_rt"
elseif Sys.isapple()
    const libmkl_rt = "@rpath/libmkl_rt.dylib"
else
    const libmkl_rt = "libmkl_rt"
end

export PardisoSolver, MKLPardisoSolver
export set_iparm!, set_dparm!, set_matrixtype!, set_solver!, set_phase!, set_msglvl!, set_nprocs!
export get_iparm, get_iparms, get_dparm, get_dparms
export get_matrixtype, get_solver, get_phase, get_msglvl, get_nprocs
export set_maxfct!, set_perm!, set_mnum!
export get_maxfct, get_perm, get_mnum
export checkmatrix, checkvec, printstats, pardisoinit, pardiso
export solve, solve!
export get_matrix

struct PardisoException <: Exception
    info::String
end

struct PardisoPosDefException <: Exception
    info::String
end

Base.showerror(io::IO, e::Union{PardisoException,PardisoPosDefException}) = print(io, e.info);


const PardisoNumTypes = Union{Float64,ComplexF64}

abstract type AbstractPardisoSolver end

function collect_gfortran_lib_candidates(main_ver)
    candidates = String[]
    if Sys.isapple()
        homebrew_gcc = "/usr/local/Cellar/gcc/"
        isdir(homebrew_gcc) || return String[]
        vers = readdir(homebrew_gcc)
        filter!(x -> startswith(x, "$main_ver."), vers)
        for v in vers
            push!(candidates, joinpath(homebrew_gcc, v, "lib/gcc/$main_ver/"))
        end
    elseif Sys.islinux()
        gcc_path = "/usr/lib/gcc/x86_64-linux-gnu/"
        isdir(gcc_path) || return String[]
        vers = readdir(gcc_path)
        filter!(x -> startswith(x, "$main_ver.") || isequal(x, "$main_ver"), vers)
        for v in vers
            push!(candidates, joinpath(gcc_path, v))
        end
    end
    return candidates
end

load_lib_fortran(lib::String, v::Int) = load_lib_fortran(lib, [v])
function load_lib_fortran(lib::String, vs::Vector{Int})
    candidates = String[]
    for v in vs
        append!(candidates, collect_gfortran_lib_candidates(v))
    end
    path = Libdl.find_library(lib, candidates)
    isempty(path) && (path = lib)
    Libdl.dlopen(path * "." * Libdl.dlext, Libdl.RTLD_GLOBAL)
end

# Pardiso
const init = Ref{Ptr}()
const pardiso_f = Ref{Ptr}()
const pardiso_chkmatrix = Ref{Ptr}()
const pardiso_chkmatrix_z = Ref{Ptr}()
const pardiso_printstats = Ref{Ptr}()
const pardiso_printstats_z = Ref{Ptr}()
const pardiso_chkvec = Ref{Ptr}()
const pardiso_chkvec_z = Ref{Ptr}()
const PARDISO_LOADED = Ref(false)

function __init__()
    if !haskey(ENV, "PARDISOLICMESSAGE")
        ENV["PARDISOLICMESSAGE"] = 1
    end

    if LOCAL_MKL_FOUND && !haskey(ENV, "MKLROOT")
        @warn "MKLROOT not set, MKL Pardiso solver will not be functional"
    end

    if PARDISO_LIB_FOUND
        try
            libpardiso = Libdl.dlopen(PARDISO_PATH, Libdl.RTLD_GLOBAL)
            init[] = Libdl.dlsym(libpardiso, "pardisoinit")
            pardiso_f[] = Libdl.dlsym(libpardiso, "pardiso")
            pardiso_chkmatrix[] = Libdl.dlsym(libpardiso, "pardiso_chkmatrix")
            pardiso_chkmatrix_z[] = Libdl.dlsym(libpardiso, "pardiso_chkmatrix_z")
            pardiso_printstats[] = Libdl.dlsym(libpardiso, "pardiso_printstats")
            pardiso_printstats_z[] = Libdl.dlsym(libpardiso, "pardiso_printstats_z")
            pardiso_chkvec[] = Libdl.dlsym(libpardiso, "pardiso_chkvec")
            pardiso_chkvec_z[] = Libdl.dlsym(libpardiso, "pardiso_chkvec_z")

            gfortran_v = [8, 9]
            for lib in ("libgfortran", "libgomp")
                load_lib_fortran(lib, gfortran_v)
            end

            # Windows Pardiso lib comes with BLAS + LAPACK prebaked but not on UNIX so we open them here
            # if not MKL is loaded
            if Sys.isunix()
                ptr = C_NULL
                for l in ("libblas", "libblas.so.3")
                    ptr = Libdl.dlopen_e(l, Libdl.RTLD_GLOBAL)
                    if ptr !== C_NULL
                        break
                    end
                end
                if ptr == C_NULL
                    error("could not load blas library")
                end
            end
            PARDISO_LOADED[] = true
        catch e
            @error("Pardiso did not manage to load, error thrown was: $(sprint(showerror, e))")
        end
    end
end
include("enums.jl")
include("project_pardiso.jl")
include("mkl_pardiso.jl")

# Getters and setters
set_matrixtype!(ps::AbstractPardisoSolver, v::Int) = set_matrixtype!(ps, MatrixType(v))
function set_matrixtype!(ps::AbstractPardisoSolver, v::MatrixType)
    ps.mtype = v
end

get_matrixtype(ps::AbstractPardisoSolver) = ps.mtype
get_iparm(ps::AbstractPardisoSolver, i::Integer) = ps.iparm[i]
get_iparms(ps::AbstractPardisoSolver) = ps.iparm
set_iparm!(ps::AbstractPardisoSolver, i::Integer, v::Integer) = ps.iparm[i] = v

get_mnum(ps::AbstractPardisoSolver) = ps.mnum
set_mnum!(ps::AbstractPardisoSolver, mnum::Integer) = ps.mnum = mnum

get_maxfct(ps::AbstractPardisoSolver) = ps.maxfct
set_maxfct!(ps::AbstractPardisoSolver, maxfct::Integer) = ps.maxfct = maxfct

get_perm(ps::AbstractPardisoSolver) = ps.perm
set_perm!(ps::AbstractPardisoSolver, perm::Vector{T}) where {T <: Integer} = ps.perm = convert(Vector{Int32}, perm)

get_phase(ps::AbstractPardisoSolver) = ps.phase

set_phase!(ps::AbstractPardisoSolver, v::Int) = set_phase!(ps, Phase(v))
function set_phase!(ps::AbstractPardisoSolver, v::Phase)
    ps.phase = v
end

get_msglvl(ps::AbstractPardisoSolver) = ps.msglvl

set_msglvl!(ps::AbstractPardisoSolver, v::Integer) = set_msglvl!(ps, MessageLevel(v))
function set_msglvl!(ps::AbstractPardisoSolver, v::MessageLevel)
    ps.msglvl = v
end

function pardisoinit(ps::AbstractPardisoSolver)
    ccall_pardisoinit(ps)
    return
end


function solve(ps::AbstractPardisoSolver, A::SparseMatrixCSC{Tv,Ti},
               B::StridedVecOrMat{Tv}, T::Symbol=:N) where {Ti, Tv <: PardisoNumTypes}
  X = copy(B)
  solve!(ps, X, A, B, T)
  return X
end

function solve!(ps::AbstractPardisoSolver, X::StridedVecOrMat{Tv},
                A::SparseMatrixCSC{Tv,Ti}, B::StridedVecOrMat{Tv},
                T::Symbol=:N) where {Ti, Tv <: PardisoNumTypes}

    pardisoinit(ps)

    # We need to set the transpose flag in PARDISO when we DON'T want
    # a transpose in Julia because we are passing a CSC formatted
    # matrix to PARDISO which expects a CSR matrix.
    if T == :N
        if isa(ps, PardisoSolver)
            set_iparm!(ps, 12, 1)
        else
            set_iparm!(ps, 12, 2)
        end
    elseif T == :C || T == :T
        set_iparm!(ps, 12, 0)
    else
        throw(ArgumentError("only :T, :N and :C, are valid transpose symbols"))
    end

    # If we want the matrix to only be transposed and not conjugated
    # we have to conjugate it before sending it to Pardiso due to CSC CSR
    # mismatch.

    # This is the heuristics for choosing what matrix type to use
    ##################################################################
    # - If hermitian try to solve with symmetric positive definite.
    #   - On pos def exception, solve instead with symmetric indefinite.
    # - If complex and symmetric, solve with symmetric complex solver
    # - Else solve as unsymmetric.
    if ishermitian(A)
        eltype(A) == Float64 ? set_matrixtype!(ps, REAL_SYM_POSDEF) : set_matrixtype!(ps, COMPLEX_HERM_POSDEF)
        try
            if typeof(ps) == PardisoSolver
                   pardiso(ps, X, get_matrix(ps, A, T), B)
            else
                # Workaround for #3
                if eltype(A) == ComplexF64
                    throw(PardisoPosDefException(""))
                end
                pardiso(ps, X, get_matrix(ps, A, T), B)
            end
        catch e
            isa(e, PardisoPosDefException) || rethrow(e)
            eltype(A) == Float64 ? set_matrixtype!(ps, REAL_SYM_INDEF) : set_matrixtype!(ps, COMPLEX_HERM_INDEF)
            pardiso(ps, X, get_matrix(ps, A, T), B)
        end
    elseif issymmetric(A)
        set_matrixtype!(ps, COMPLEX_SYM)
        pardiso(ps, X, get_matrix(ps, A, T), B)
    else
        eltype(A) == Float64 ? set_matrixtype!(ps, REAL_NONSYM) : set_matrixtype!(ps, COMPLEX_NONSYM)
        pardiso(ps, X, get_matrix(ps, A, T), B)
    end
    original_phase = get_phase(ps)

    # Release memory, TODO: We are running the convert on IA and JA here
    # again which is unnecessary.
    set_phase!(ps, RELEASE_ALL)
    pardiso(ps, X, A, B)
    set_phase!(ps, original_phase)
    return X
end

function get_matrix(ps::AbstractPardisoSolver, A, T)
    mtype = get_matrixtype(ps)

    if isposornegdef(mtype)
        if ps isa MKLPardisoSolver
            T == :C && return conj(tril(A))
            return tril(A)
        elseif ps isa PardisoSolver
            T == :T && return tril(A)
            return conj(tril(A))
        end
    end

    if !issymmetric(mtype)
        T == :C && return conj(A)
        return A
    end

    if mtype == COMPLEX_SYM
        T == :C && return conj(tril(A))
        return tril(A)
    end

    error("Unhandled matrix type")
end

function pardiso(ps::AbstractPardisoSolver, X::StridedVecOrMat{Tv}, A::SparseMatrixCSC{Tv,Ti},
                 B::StridedVecOrMat{Tv}) where {Ti, Tv <: PardisoNumTypes}
    if length(X) != 0
        dim_check(X, A, B)
    end

    if Tv <: Complex && isreal(get_matrixtype(ps))
        throw(ErrorException(string("input matrix is complex while PardisoSolver ",
                                    "has a real matrix type set: $(get_matrixtype(ps))")))
    end

    if Tv <: Real && !isreal(get_matrixtype(ps))
        throw(ErrorException(string("input matrix is real while PardisoSolver ",
                                    "has a complex matrix type set: $(get_matrixtype(ps))")))
    end

    N = Int32(size(A, 2))

    AA = A.nzval
    IA = convert(Vector{Int32}, A.colptr)
    JA = convert(Vector{Int32}, A.rowval)

    resize!(ps.perm, size(B, 1))

    NRHS = Int32(size(B, 2))

    ccall_pardiso(ps, N, AA, IA, JA, NRHS, B, X)
end

pardiso(ps::AbstractPardisoSolver) = ccall_pardiso(ps, Int32(0), Float64[], Int32[], Int32[], Int32(0), Float64[], Float64[])
function pardiso(ps::AbstractPardisoSolver, A::SparseMatrixCSC{Tv,Ti}, B::StridedVecOrMat{Tv}) where {Ti, Tv <: PardisoNumTypes}
    pardiso(ps, Tv[], A, B)
end

function dim_check(X, A, B)
    size(X) == size(B) || throw(DimensionMismatch(string("solution has $(size(X)), ",
                                                         "RHS has size as $(size(B)).")))
    size(A, 1) == size(B, 1) || throw(DimensionMismatch(string("matrix has $(size(A,1)) ",
                                                               "rows, RHS has $(size(B,1)) rows.")))
    size(B, 1) == stride(B, 2) || throw(DimensionMismatch(
                                            string("Only memory-contiguous RHS supported")))
end

end # module
