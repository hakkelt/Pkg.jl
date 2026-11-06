using .Utils
using Test
using UUIDs
import LibGit2

# A registry, made by hand, with
#   Solvers 1.0.0  subpackages Common, BDF (needs weakdep Heavy)
#   Solvers 1.1.0  ... and Rosenbrock (needs weakdep Light)
#   SolverUser 0.1.0, which uses Solvers::BDF
const SOLVERS_UUID = UUID("2a1d7b9e-7c55-4a3b-9b1e-2f0e4b6c1d01")
const USER_UUID = UUID("2a1d7b9e-7c55-4a3b-9b1e-2f0e4b6c1d02")
const HEAVY_UUID = UUID("2a1d7b9e-7c55-4a3b-9b1e-2f0e4b6c1d03")
const LIGHT_UUID = UUID("2a1d7b9e-7c55-4a3b-9b1e-2f0e4b6c1d04")

tree_hash_of(repo_path) = LibGit2.with(LibGit2.GitRepo(repo_path)) do repo
    string(LibGit2.GitHash(LibGit2.peel(LibGit2.GitTree, LibGit2.head(repo))))
end
toml_path(p) = replace(p, "\\" => "/")

function write_simple_package(dir, name, uuid)
    path = joinpath(dir, name)
    mkpath(joinpath(path, "src"))
    write(joinpath(path, "Project.toml"), "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n")
    write(joinpath(path, "src", "$name.jl"), "module $name\nf() = \"$(lowercase(name))\"\nend\n")
    git_init_and_commit(path)
    return path, tree_hash_of(path)
end

function write_solvers(path, version, with_rosenbrock)
    mkpath(joinpath(path, "src"))
    mkpath(joinpath(path, "sub"))
    write(
        joinpath(path, "Project.toml"), """
        name = "Solvers"
        uuid = "$SOLVERS_UUID"
        version = "$version"

        [weakdeps]
        Heavy = "$HEAVY_UUID"
        $(with_rosenbrock ? "Light = \"$LIGHT_UUID\"" : "")

        [subpackages]
        Common = []
        BDF = ["Common", "Heavy"]
        $(with_rosenbrock ? "Rosenbrock = [\"Common\", \"Light\"]" : "")

        [compat]
        Heavy = "0.1"
        """
    )
    write(joinpath(path, "src", "Solvers.jl"), "module Solvers\nend\n")
    write(joinpath(path, "sub", "Common.jl"), "module Common\nabstract type Alg end\nend\n")
    write(joinpath(path, "sub", "BDF.jl"), "module BDF\nusing Common, Heavy\nsolve() = \"bdf via \" * Heavy.f()\nend\n")
    with_rosenbrock && write(joinpath(path, "sub", "Rosenbrock.jl"), "module Rosenbrock\nusing Common, Light\nend\n")
    return
end

function make_subpackage_registry(dir)
    heavy_path, heavy_tree = write_simple_package(dir, "Heavy", HEAVY_UUID)
    light_path, light_tree = write_simple_package(dir, "Light", LIGHT_UUID)

    solvers_path = joinpath(dir, "Solvers")
    write_solvers(solvers_path, "1.0.0", false)
    git_init_and_commit(solvers_path)
    solvers_tree_1 = tree_hash_of(solvers_path)
    write_solvers(solvers_path, "1.1.0", true)
    LibGit2.with(LibGit2.GitRepo(solvers_path)) do repo
        LibGit2.add!(repo, "*")
        LibGit2.commit(repo, "1.1.0"; author = Utils.TEST_SIG, committer = Utils.TEST_SIG)
    end
    solvers_tree_2 = tree_hash_of(solvers_path)

    user_path = joinpath(dir, "SolverUser")
    mkpath(joinpath(user_path, "src"))
    write(
        joinpath(user_path, "Project.toml"), """
        name = "SolverUser"
        uuid = "$USER_UUID"
        version = "0.1.0"

        [deps]
        Solvers = "$SOLVERS_UUID"

        [subdeps]
        Solvers = ["BDF"]
        """
    )
    write(joinpath(user_path, "src", "SolverUser.jl"), "module SolverUser\nBase.@subpackage import Solvers::BDF\nrun() = BDF.solve()\nend\n")
    git_init_and_commit(user_path)
    user_tree = tree_hash_of(user_path)

    reg = joinpath(dir, "SubReg")
    files = Dict(
        "Registry.toml" => """
            name = "SubReg"
            uuid = "20000000-0000-0000-0000-0000000000aa"
            repo = "$(toml_path(reg))"
            [packages]
            $SOLVERS_UUID = { name = "Solvers", path = "Solvers" }
            $USER_UUID = { name = "SolverUser", path = "SolverUser" }
            $HEAVY_UUID = { name = "Heavy", path = "Heavy" }
            $LIGHT_UUID = { name = "Light", path = "Light" }
            """,
        "Heavy/Package.toml" => "name = \"Heavy\"\nuuid = \"$HEAVY_UUID\"\nrepo = \"$(toml_path(heavy_path))\"\n",
        "Heavy/Versions.toml" => "[\"0.1.0\"]\ngit-tree-sha1 = \"$heavy_tree\"\n",
        "Light/Package.toml" => "name = \"Light\"\nuuid = \"$LIGHT_UUID\"\nrepo = \"$(toml_path(light_path))\"\n",
        "Light/Versions.toml" => "[\"0.1.0\"]\ngit-tree-sha1 = \"$light_tree\"\n",
        "Solvers/Package.toml" => "name = \"Solvers\"\nuuid = \"$SOLVERS_UUID\"\nrepo = \"$(toml_path(solvers_path))\"\n",
        "Solvers/Versions.toml" => """
            ["1.0.0"]
            git-tree-sha1 = "$solvers_tree_1"
            ["1.1.0"]
            git-tree-sha1 = "$solvers_tree_2"
            """,
        "Solvers/WeakDeps.toml" => """
            [1]
            Heavy = "$HEAVY_UUID"
            ["1.1-1"]
            Light = "$LIGHT_UUID"
            """,
        "Solvers/WeakCompat.toml" => "[1]\nHeavy = \"0.1\"\n",
        "Solvers/Subpackages.toml" => """
            [1]
            BDF = ["Common", "Heavy"]
            Common = []
            ["1.1-1"]
            Rosenbrock = ["Common", "Light"]
            """,
        "SolverUser/Package.toml" => "name = \"SolverUser\"\nuuid = \"$USER_UUID\"\nrepo = \"$(toml_path(user_path))\"\n",
        "SolverUser/Versions.toml" => "[\"0.1.0\"]\ngit-tree-sha1 = \"$user_tree\"\n",
        "SolverUser/Deps.toml" => "[0]\nSolvers = \"$SOLVERS_UUID\"\n",
        "SolverUser/Subdeps.toml" => "[0]\nSolvers = [\"BDF\"]\n",
    )
    for (file, content) in files
        mkpath(dirname(joinpath(reg, file)))
        write(joinpath(reg, file), content)
    end
    git_init_and_commit(reg)
    return reg, solvers_path
end

manifest_entry(uuid) = Pkg.Types.EnvCache().manifest[uuid]
in_manifest(uuid) = haskey(Pkg.Types.EnvCache().manifest, uuid)
project_subdeps() = Pkg.Types.EnvCache().project.subdeps
# the subpackages of `uuid` that something in the environment uses
function selected_subpackages(uuid)
    env = Pkg.Types.EnvCache()
    selection = Pkg.Operations.manifest_subpackage_selection(env, env.manifest, Set(keys(env.manifest)))
    return sort!(collect(get(Set{String}, selection, uuid)))
end
# Base support for loading subpackages is a separate change; skip the loading checks without it
const BASE_HAS_SUBPACKAGES = isdefined(Base, Symbol("@subpackage"))
# run `code` in a new process, in the active environment and the test's depot
run_in_env(code) = read(
    addenv(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Pkg.project().path)) -e $code`,
           "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ";" : ":")),
    String)

@testset "subpackages" begin
    isolate(loaded_depot = false) do
        mktempdir() do dir
            reg, solvers_path = make_subpackage_registry(dir)
            Pkg.Registry.add(url = reg)

            @testset "project and registry files" begin
                project = Pkg.Types.read_project(joinpath(solvers_path, "Project.toml"))
                @test sort!(collect(keys(project.subpackages))) == ["BDF", "Common", "Rosenbrock"]
                @test Pkg.Types.subpackage_deps(project, "BDF") == ["Common", "Heavy"]
                registry = only(filter(r -> r.name == "SubReg", Pkg.Registry.reachable_registries()))
                info = Pkg.Registry.registry_info(registry, registry[SOLVERS_UUID])
                @test sort!(collect(keys(Pkg.Registry.query_subpackages(info, v"1.0.0")))) == ["BDF", "Common"]
                @test Pkg.Registry.query_subpackages(info, v"1.1.0")["Rosenbrock"].deps == Set([LIGHT_UUID])
                @test Pkg.Registry.query_subpackages(info, v"1.1.0")["Rosenbrock"].siblings == ["Common"]
                user_info = Pkg.Registry.registry_info(registry, registry[USER_UUID])
                @test Pkg.Registry.query_subdeps(user_info, v"0.1.0") == Dict(SOLVERS_UUID => ["BDF"])
            end

            @testset "add Parent::Sub installs only that subpackage's weak deps" begin
                Pkg.activate(; temp = true)
                Pkg.add("Solvers::BDF")
                @test project_subdeps() == Dict("Solvers" => ["BDF"])
                @test selected_subpackages(SOLVERS_UUID) == ["BDF"]
                @test in_manifest(HEAVY_UUID)
                @test !in_manifest(LIGHT_UUID)
                # the manifest entry records the parent's subpackage definitions
                @test issubset(["BDF", "Common"], keys(manifest_entry(SOLVERS_UUID).subpackages))
                @test Pkg.Types.subpackage_deps(manifest_entry(SOLVERS_UUID).subpackages, "BDF") == ["Common", "Heavy"]
                # status shows the subpackages in use
                @test occursin(r"Solvers v\S+ ::\{BDF\}", sprint(io -> Pkg.status(; io)))
                @test occursin(r"Solvers v\S+ ::\{BDF\}", sprint(io -> Pkg.status(; io, mode = Pkg.PKGMODE_MANIFEST)))
                # the project file round-trips
                @test Pkg.Types.read_project(Pkg.project().path).subdeps == Dict("Solvers" => ["BDF"])
                if BASE_HAS_SUBPACKAGES
                    out = run_in_env("Base.@subpackage using Solvers::BDF; print(BDF.solve())")
                    @test out == "bdf via heavy"
                end

                # Rosenbrock only exists from 1.1, and needs Light
                Pkg.add("Solvers::Rosenbrock")
                @test project_subdeps() == Dict("Solvers" => ["BDF", "Rosenbrock"])
                @test manifest_entry(SOLVERS_UUID).version == v"1.1.0"
                @test selected_subpackages(SOLVERS_UUID) == ["BDF", "Rosenbrock"]
                @test in_manifest(LIGHT_UUID)

                # rm Parent::Sub keeps the package and drops what only that subpackage needed
                Pkg.rm("Solvers::BDF")
                @test project_subdeps() == Dict("Solvers" => ["Rosenbrock"])
                @test in_manifest(SOLVERS_UUID)
                @test !in_manifest(HEAVY_UUID)
                @test in_manifest(LIGHT_UUID)
                Pkg.rm("Solvers::Rosenbrock")
                @test isempty(project_subdeps())
                @test !in_manifest(LIGHT_UUID)
                @test isempty(selected_subpackages(SOLVERS_UUID))
            end

            @testset "versions without the subpackage are ruled out" begin
                Pkg.activate(; temp = true)
                Pkg.add(name = "Solvers", version = "1.0.0")
                Pkg.compat("Solvers", "=1.0.0")
                @test_throws Pkg.Resolve.ResolverError Pkg.add("Solvers::Rosenbrock")
            end

            @testset "errors" begin
                Pkg.activate(; temp = true)
                err = try
                    Pkg.add("Solvers::Nope"); nothing
                catch e
                    e
                end
                @test err isa Pkg.Types.PkgError
                @test occursin("no registered version of package Solvers has the subpackage(s) Nope", err.msg)
                @test_throws Pkg.Types.PkgError Pkg.add("Solvers::")
                @test_throws Pkg.Types.PkgError Pkg.rm("Solvers::BDF")
            end

            @testset "a registered package's [subdeps]" begin
                Pkg.activate(; temp = true)
                Pkg.add("SolverUser")
                @test isempty(project_subdeps())
                @test manifest_entry(USER_UUID).subdeps == Dict("Solvers" => ["BDF"])
                # the project does not use any subpackage itself, but the manifest does
                @test !occursin("::{", sprint(io -> Pkg.status(; io)))
                @test occursin("::{BDF}", sprint(io -> Pkg.status(; io, mode = Pkg.PKGMODE_MANIFEST)))
                @test selected_subpackages(SOLVERS_UUID) == ["BDF"]
                @test in_manifest(HEAVY_UUID)
                @test !in_manifest(LIGHT_UUID)
                if BASE_HAS_SUBPACKAGES
                    out = run_in_env("using SolverUser; print(SolverUser.run())")
                    @test out == "bdf via heavy"
                end
            end

            @testset "a developed parent" begin
                Pkg.activate(; temp = true)
                Pkg.develop(path = solvers_path)
                Pkg.add("Solvers::Rosenbrock")
                @test selected_subpackages(SOLVERS_UUID) == ["Rosenbrock"]
                @test in_manifest(LIGHT_UUID)
                @test !in_manifest(HEAVY_UUID)
                @test_throws Pkg.Types.PkgError Pkg.add("Solvers::Nope")
            end

            @testset "REPL" begin
                Pkg.activate(; temp = true)
                pkg"add Solvers::BDF"
                @test project_subdeps() == Dict("Solvers" => ["BDF"])
                pkg"rm Solvers::BDF"
                @test isempty(project_subdeps())
                @test in_manifest(SOLVERS_UUID)
            end
        end
    end
end
