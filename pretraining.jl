using ArgParse, DataFrames

include("io.jl")
include("datagen/maze.jl")
include("datagen/path_generator.jl")
include("datagen/lang_generator.jl")

function parse_commandline()
    s = ArgParseSettings()

    @add_arg_table s begin
        ("--lr"; help = "learning rate"; default = 0.001; arg_type = Float64)
        ("--hidden"; help = "hidden size"; default = 100; arg_type = Int)
        ("--embed"; help = "embedding size"; default = 100; arg_type = Int)
        ("--limactions"; arg_type = Int; default = 35)
        ("--window"; help = "size of the filter"; default = [29, 7, 5]; arg_type = Int; nargs = '+')
        ("--filters"; help = "number of filters"; default = [200, 100, 50]; arg_type = Int; nargs = '+')
        ("--model"; help = "model file"; default = "flex.jl")
        ("--encdrops"; help = "dropout rates"; nargs = '+'; default = [0.5, 0.5]; arg_type = Float64)
        ("--decdrops"; help = "dropout rates"; nargs = '+'; default = [0.5, 0.5]; arg_type = Float64)
        ("--bs"; help = "batch size"; default = 1; arg_type = Int)
        ("--gclip"; help = "gradient clip"; default = 5.0; arg_type = Float64)
        ("--log"; help = "name of the log file"; default = "test.log")
        ("--save"; help = "model path"; default = "")
        ("--load"; help = "model path"; default = "")
        ("--charenc"; help = "charecter embedding"; action = :store_true)
        ("--encoding"; help = "grid or multihot"; default = "grid")
        ("--wvecs"; help = "use word vectors"; action= :store_true)
        ("--greedy"; help = "deterministic or stochastic policy"; action = :store_false)
        ("--seed"; help = "seed number"; arg_type = Int; default = 123)
        ("--percp"; help = "use perception"; action = :store_false)
        ("--preva"; help = "use previous action"; action = :store_true)
        ("--att"; help = "use attention"; action = :store_true)
        ("--inpout"; help = "direct connection from input to output"; action = :store_false)
        ("--prevaout"; help = "direct connection from prev action to output"; action = :store_true)
        ("--attout"; help = "direct connection from attention to output"; action = :store_true)
        ("--level"; help = "log level"; default="info")
        ("--numbatch"; help = "number of batches"; default=100; arg_type=Int)
    end
    return parse_args(s)
end		

args = parse_commandline()

include(args["model"])


CHARS = collect("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
items = filter(x->x!="", collect(keys(Items)))

"""
stage: number of actions except the stop action
"""
function generatedata(stage=1; numins=100)
    h,w = (8,8)
    data = Any[]
    mps = Dict()
    itemcounts = zeros(length(items))

    inscount = 0

    while inscount < numins
        maze, available = generate_maze(h, w; numdel=1)
        navimap = generate_navi_map(maze, ""; iprob=-1.0)

        nodes, path = generate_path(maze, available)

        segments = segment_path(nodes)

        for i=1:length(segments)
            tp, path = segments[i]
            if length(path)-1 != stage || tp == "move"
                continue
            end

            mname = join(rand(CHARS, 20))
            cpmp = copy(navimap)
            cpmp.name = mname

            mps[mname] = cpmp

            inscount += 1

            sits = shuffle(items)

            n1 = path[1]
            nbs = collect(keys(cpmp.edges[n1[1:2]]))

            for j=1:length(nbs); cpmp.nodes[nbs[j]] = Items[sits[j]]; end

            prefx = ""
            nb = nothing
            if tp == "turn"
                nb = getlocation(cpmp, path[2], 1)
                prefx = "turn to the "
            else
                nb = path[2]
                prefx = "move to the "
            end

            itindx = cpmp.nodes[nb[1:2]]
            itemcounts[itindx] += 1

            ins = Instruction(string("artificial_", inscount), split(string(prefx, item_names[itindx])), path, mname, inscount)
            push!(data, ins)
            break
            #=
            if inscount >= numins
                break
            end
            =#
        end
    end

    return data, mps, itemcounts
end

function testgeneratedata()
    Logging.configure(filename=args["log"])
    if args["level"] == "info"
        Logging.configure(level=INFO)
    else
        Logging.configure(level=DEBUG)
    end
    for i=1:100
        info("i: $i")
        dat, maps, counts = generatedata()
        for ins in dat
            m = maps[ins.map]
            fs = filter(t->m.nodes[t] != 7, collect(keys(m.nodes)))
            @assert length(fs) != 0
            its = map(t->m.nodes[t], fs)

            @assert length(its) == length(Set(its))
        end
    end

    info("PASSED")
end

function pretrain(vocab, emb, args)
    w = nothing
    prms = nothing
    avg_lss = 0
    avg_acc = 0

    df = DataFrame(Batch=Int[], Loss=Any[], Acc=Any[])
    itmcnts = zeros(length(items))

    for i=1:args["numbatch"]
        dat, maps, counts = generatedata()
        itmcnts += counts
        data = map(x -> build_instance(x, maps[x.map], vocab; encoding=args["encoding"], emb=nothing), dat)
        trn_data = minibatch(data;bs=args["bs"])
        
        dat2, maps2, _ = generatedata()
        tst_data = map(ins-> (ins, ins_arr(vocab, ins.text)), dat2)
        
        vdims = size(trn_data[1][2][1])

        vocabsize = length(vocab) + 1
        world = length(vdims) > 2 ? vdims[3] : vdims[2]

        if w == nothing
            embedsize = args["wvecs"] ? 300 : args["embed"]
            world = length(vdims) > 2 ? vdims[3] : vdims[2]

            premb = nothing
            if args["wvecs"]
                premb = zeros(Float32, vocabsize, embedsize)
                for k in keys(vocab)
                 premb[vocab[k], :] = emb[k]
                end
            end

            w = initweights(KnetArray, args["hidden"], vocabsize, args["embed"], args["window"], world, args["filters"]; args=args, premb=premb)

            info("Model Prms:")
            for k in keys(w)
                info("$k : $(size(w[k])) ")
                if startswith(k, "filter")
                    for ind=1:length(w[k])
                        info("$k , $ind : $(size(w[k][ind]))")
                    end
                end
            end
        end

        if prms == nothing
            prms = initparams(w; args=args)
        end
        @time lss = train(w, prms, trn_data; args=args)
        @time tst_acc = test([w], tst_data, maps2; args=args)

        avg_lss = avg_lss == 0 ? lss : avg_lss*0.95 + 0.05*lss
        avg_acc = avg_acc == 0 ? tst_acc : avg_acc*0.95 + 0.05*tst_acc

        info("BatchNum: $i , Loss: $lss , Acc: $(tst_acc)")

        push!(df, (i, avg_lss, avg_acc))

        info("$(df[i,:])")
        info("Item counts: $(itmcnts) \n")

        if (1.0 - avg_acc) < 1e-3
            break
        end
    end

    writetable(args["save"], df)
end

function get_maps()
    fname = "data/maps/map-grid.json"
    grid = getmap(fname)

    fname = "data/maps/map-jelly.json"
    jelly = getmap(fname)

    fname = "data/maps/map-l.json"
    l = getmap(fname)

    maps = Dict("Grid" => grid, "Jelly" => jelly, "L" => l)
    return maps
end

function mainpretraining()
    Logging.configure(filename=args["log"])
    if args["level"] == "info"
        Logging.configure(level=INFO)
    else
        Logging.configure(level=DEBUG)
    end
    srand(args["seed"])
    info("*** Parameters ***")
    for k in keys(args); info("$k -> $(args[k])"); end

    grid, jelly, l = getallinstructions()
    lg = length(grid)
    lj = length(jelly)
    ll = length(l)
    dg = floor(Int, lg*0.5)
    dj = floor(Int, lj*0.5)
    dl = floor(Int, ll*0.5)

    maps = get_maps()

    vocab = build_dict(vcat(grid, jelly, l))
    emb = args["wvecs"] ? load("data/embeddings.jld", "vectors") : nothing
    info("\nVocab: $(length(vocab))")

    pretrain(vocab, emb, args)
end

mainpretraining()
#testgeneratedata()