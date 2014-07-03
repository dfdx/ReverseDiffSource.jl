#########################################################################
#
#   rdiff differentiation function
#
#########################################################################

##########  function version   ##############

function rdiff(f::Function, sig0::Tuple; order::Int=1, evalmod=Main)
    sig = map( typeof, sig0 )
    fs = methods(f, sig)
    length(fs) == 0 && error("no function '$f' found for signature $sig")
    length(fs) > 1  && error("several functions $f found for signature $sig")  # is that possible ?

    fdef  = fs[1].func.code
    fcode = Base.uncompressed_ast(fdef)
    fargs = fcode.args[1]  # function parameters

    cargs = [ (fargs[i], sig0[i]) for i in 1:length(sig0) ]
    dex = rdiff(fcode.args[3]; order=order, evalmod=evalmod, cargs...)

    # Note : new function is created in the same module as original function
    myf = fdef.module.eval( :( $(Expr(:tuple, fargs...)) -> $dex ) )
end


######### expression version   ################
# TODO : break this huge function in smaller blocks

function rdiff(ex; outsym=nothing, order::Int=1, evalmod=Main, params...)

    length(params) >= 1 || error("There should be at least one parameter specified, none found")
    
    order <= 1 || 
    length(params) == 1 || error("Only one param allowed for order >= 2")
    
    order <= 1 || 
    isa(params[1][2], Vector) || 
    isa(params[1][2], Real)   || error("Param should be a real or vector for order >= 2")

    paramsym    = Symbol[ e[1] for e in params]
    paramvalues = [ e[2] for e in params]
    parval      = Dict(paramsym, paramvalues)

    g = tograph(ex)

    haskey(g.set_inodes.vk, outsym) || 
        error("can't find output var $( outsym==nothing ? "" : outsym)")

    # reduce to variable of interest
    g.set_inodes = BiDict{ExNode,Any}([g.set_inodes.vk[outsym]], [ outsym ])    

    g |> splitnary! |> prune! |> simplify!
    calc!(g, params=parval, emod=evalmod)

    ov = g.set_inodes.vk[outsym].val 
    isa(ov, Real) || error("output var should be a Real, $(typeof(ov)) found")

    voi = { outsym }

    if order == 1
        dg = reversegraph(g, g.set_inodes.vk[outsym], paramsym)
        append!(g.nodes, dg.nodes)
        nn = addnode!( g, NCall(:tuple, [ dg.set_inodes.vk[dprefix(p)] for p in paramsym] ) )
        ns = newvar("_dv")
        g.set_inodes[nn] = ns
        push!(voi, ns)

        g |> splitnary! |> prune! |> simplify!

    elseif order > 1 && isa(paramvalues[1], Real)
        for i in 1:order
            dg = reversegraph(g, g.set_inodes.vk[voi[i]], paramsym)
            append!(g.nodes, dg.nodes)
            nn = collect(keys(dg.set_inodes))[1]  # only a single node produced
            ns = newvar("_dv")
            g.set_inodes[nn] = ns
            push!(voi, ns)

            g |> splitnary! |> prune! |> simplify!
            
            calc!(g, params=parval, emod=evalmod)
        end

    elseif order > 1 && isa(paramvalues[1], Vector)
        # do first order as usual
        dg = reversegraph(g, g.set_inodes.vk[outsym], paramsym)
        append!(g.nodes, dg.nodes)
        ns = newvar(:_dv)
        g.set_inodes[ collect(keys(dg.set_inodes))[1] ] = ns
        push!(voi, ns)

        g |> splitnary! |> prune! |> simplify!

        # now order 2 to n
        for i in 2:order  
            # launch derivation on a single value of the preceding
            #   derivation vector
            no = g.set_inodes.vk[voi[i]]
            si = newvar(:_idx)
            ni = addnode!(g, NExt(si))
            ns = addnode!(g, NRef(:getidx, [ no, ni ]))

            calc!(g, params=Dict([paramsym, si], [paramvalues, 1.]), emod=evalmod)
            dg = reversegraph(g, ns, paramsym)

            #### We will now wrap dg in a loop scanning all the elements of 'no'
            # first create ext nodes to make dg a complete subgraph
            dg2 = ExNode[]
            nmap = Dict()
            for n in dg.nodes  # n = dg.nodes[2]
                for (j, np) in enumerate(n.parents)  # j,np = 1, n.parents[1]
                    if haskey(nmap, np) # already remapped
                        n.parents[j] = nmap[np]

                    elseif np == ni # it's the loop index
                        nn = NExt(si)
                        push!(dg2, nn)
                        dg.ext_inodes[nn] = si
                        n.parents[j] = nn
                        nmap[np] = nn

                    elseif np == ns # it's the selected element of the deriv vector
                        # create 'no' ref if needed
                        if !haskey(nmap, no)
                            sn = newvar()
                            nn = NExt(sn)
                            push!(dg2, nn)
                            dg.ext_inodes[nn] = sn
                            dg.ext_onodes[no] = sn
                            nmap[no] = nn
                        end

                        nn = NRef(:getidx, [ nmap[no], nmap[ni] ])
                        push!(dg2, nn)
                        nmap[ns] = nn                            

                    elseif !(np in dg.nodes) # it's not in dg (but in g)
                        sn = newvar()
                        nn = NExt(sn)
                        push!(dg2, nn)
                        dg.ext_inodes[nn] = sn
                        dg.ext_onodes[np] = sn
                        n.parents[j] = nn
                        nmap[np] = nn

                    end    
                end

                # update onodes in for loops
                if isa(n, NFor)
                    g2 = n.main[2]
                    for (o,s) in g2.ext_onodes
                        if haskey(nmap, o)
                            g2.ext_onodes[ nmap[o] ] = s  # replace
                        end
                    end
                end
            end
            append!(dg.nodes, dg2)    
            dg |> prune! |> simplify!

            # create for loop node
            nf = addnode!(g, NFor({si, dg}) )

            # create size node
            nsz = addgraph!( :( length( x ) ), g, { :x => g.ext_inodes.vk[paramsym[1]] } )

            # create index range node
            nid = addgraph!( :( 1:sz ),  g, { :sz => nsz } )
            push!(nf.parents, nid)

            # create stride size node
            nst = addgraph!( :( sz ^ $(i-1) ),  g, { :sz => nsz } )
            sst = newvar()
            inst = addnode!(dg, NExt(sst))
            dg.ext_inodes[inst] = sst
            dg.ext_onodes[nst]  = sst
            push!(nf.parents, nst)

            # create result node (alloc in parent graph)
            nsa = addgraph!( :( zeros( $( Expr(:tuple, [:sz for j in 1:i]...) ) ) ), g, { :sz => nsz } )
            ssa = newvar()
            insa = addnode!(dg, NExt(ssa))
            dg.ext_inodes[insa] = ssa
            dg.ext_onodes[nsa]  = ssa
            push!(nf.parents, nsa)

            # create result node update (in subgraph)
            nres = addgraph!( :( res[ ((sidx-1)*st+1):(sidx*st) ] = dx ; res ), dg, 
                                { :res  => insa,
                                  :sidx => nmap[ni],
                                  :st   => inst,
                                  :dx   => collect(dg.set_inodes)[1][1] } )
            dg.set_inodes = BiDict{ExNode, Any}(Dict([nres], [ssa]))

            # create exit node for result
            nex = addnode!(g, NIn(ssa, [nf]))
            dg.set_onodes = BiDict{ExNode, Any}(Dict([nex], [ssa]))

            # update parents of for loop
            append!( nf.parents, setdiff(collect( keys(dg.ext_onodes)), nf.parents[2:end]) )

            ns = newvar(:_dv)
            g.set_inodes[nex] = ns
            push!(voi, ns)

            g |> splitnary! |> prune! |> simplify!
            
            calc!(g, params=Dict(paramsym, paramvalues), emod=evalmod)
        end

    end

    voin = map( s -> g.set_inodes.vk[s], voi)
    ex = addnode!(g, NCall(:tuple, voin))
    g.set_inodes = BiDict(Dict{ExNode,Any}( [ex], [nothing]) )

    resetvar()
    tocode(g)
end
