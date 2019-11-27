function vhem_step_E(base::H3M{Z}, reduced::H3M{Z}, τ::Integer, N::Integer) where Z
    ## Expectations
    # logη[i,j][β,ρ][m,l]
    logη = Dict{Tuple{Int,Int}, Dict{Tuple{Int,Int}, Matrix{Float64}}}()

    # lhmm[i,j]: expected log-likelihood
    lhmm = zeros(length(base.M), length(reduced.M))

    ## Aggregated summaries
    ## Coviello14, p. 15, eqn. 23

    # νagg1[i,j][ρ]: expected number of times that
    # HMM j starts from ρ, when modeling sequences
    # generated by HMM i.
    νagg1 = Dict{Tuple{Int,Int}, Vector{Float64}}()

    # νagg[i,j][ρ,β]: expected number of times that
    # HMM j is in state ρ when HMM i is in state β,
    # when both HMMs are modeling sequences generated
    # by HMM i.
    νagg = Dict{Tuple{Int,Int}, Matrix{Float64}}()

    # ξagg[i,j][ρ,ρ']: expected number of transitions
    # from state ρ to ρ' of the HMM j when modeling
    # sequences generated by HMM i.
    ξagg = Dict{Tuple{Int,Int}, Matrix{Float64}}()

    ## Optimal assignments probabilities
    logz = zeros(length(base.M), length(reduced.M))

    # TODO: /Ragged arrays/ instead of dicts ?
    # TODO: "Summary statistics" struct

    logωj = log.(reduced.ω)

    for (i, Mi) in enumerate(base.M)
        # Initial probabilities (π in the paper)
        # Transition matrices (a or A in the paper)
        logai = log.(Mi.a)
        logAi = log.(Mi.A)

        logzacc = LogSumExpAcc()

        for (j, Mj) in enumerate(reduced.M)
            Ki, Kj = size(Mi, 1), size(Mj, 1)

            ## Expectations
            logη[i,j] = Dict{Tuple{Int,Int}, Matrix{Float64}}()

            ## Summary statistics
            logν = zeros(τ, Kj, Ki)
            logξ = zeros(τ, Kj, Kj, Ki)

            ## Aggregate summaries
            νagg1[i,j] = zeros(Kj)
            νagg[i,j]  = zeros(Kj, Ki)
            ξagg[i,j]  = zeros(Kj, Kj)

            logη[i,j], _, (lhmm[i,j], logϕ, logϕ1) = loglikelihood_va(Mi, Mj, τ)

            for ρ in OneTo(Kj), β in OneTo(Ki)
                logν[1,ρ,β]     = logai[β] + logϕ1[β,ρ]
                νagg1[i,j][ρ]  += exp(logν[1,ρ,β])
                νagg[i,j][ρ,β] += exp(logν[1,ρ,β])
            end

            logtmps = zeros(Kj, Ki)

            for t in 2:τ
                for β in OneTo(Ki)
                    for ρp in OneTo(Kj)
                        acc = LogSumExpAcc()
                        for βp in OneTo(Ki)
                            add!(acc, logν[t-1,ρp,βp] + logAi[βp,β])
                        end
                        logtmps[ρp,β] = sum(acc)
                    end
                end

                for ρ in OneTo(Kj)
                    for β in OneTo(Ki)
                        acc = LogSumExpAcc()
                        for ρp in OneTo(Kj)
                            logξ[t,ρp,ρ,β] = logtmps[ρp,β] + logϕ[t,β,ρp,ρ]
                            ξagg[i,j][ρp,ρ] += exp(logξ[t,ρp,ρ,β])
                            add!(acc, logξ[t,ρp,ρ,β])
                        end
                        logν[t,ρ,β] = sum(acc)
                        νagg[i,j][ρ,β] += exp(logν[t,ρ,β])
                    end
                end
            end

            # Compute optimal assignment probabilities
            logz[i,j] = logωj[j] + (N * base.ω[i] * lhmm[i,j])
            add!(logzacc, logz[i,j])
        end

        logz[i,:] .-= sum(logzacc)
    end

    logz, logη, lhmm, νagg, νagg1, ξagg
end

function vhem_step(base::H3M{Z}, reduced::H3M{Z}, τ::Integer, N::Integer) where Z
    ## E step
    logz, logη, lhmm, νagg, νagg1, ξagg = vhem_step_E(base, reduced, τ, N)

    # TODO: Use logz below instead ?
    z = exp.(logz)

    ## M step

    # 1. Compute H3M weights
    newω = zeros(length(reduced))
    norm = 0.0
    
    for j in OneTo(length(reduced)), i in OneTo(length(base))
        newω[j] += z[i,j]
        norm += z[i,j]
    end

    for j in OneTo(length(reduced))
        newω[j] /= norm
    end

    # 2. Compute H3M models
    newM = Vector{Z}(undef, length(reduced))

    for j in OneTo(length(reduced))
        Mj, ωj = reduced.M[j], reduced.ω[j]
        Kj = size(Mj, 1)

        # 2.a Compute initial probabilities
        newa = zeros(Kj)
        norm = 0.0

        for ρ in OneTo(Kj)
            for i in OneTo(length(base))
                newa[ρ] += z[i,j] * base.ω[i] * νagg1[i,j][ρ]
            end
            norm += newa[ρ]
        end

        newa /= norm

        # 2.b Compute transition matrix
        newA = zeros(Kj, Kj)

        for ρ in OneTo(Kj)
            norm = 0.0
            for ρp in OneTo(Kj)
                for i in OneTo(length(base))
                    newA[ρ,ρp] += z[i,j] * base.ω[i] * ξagg[i,j][ρ,ρp]
                end
                norm += newA[ρ,ρp]
            end

            for ρp in OneTo(Kj)
                newA[ρ,ρp] /= norm
            end
        end

        # 2.c Compute observation mixtures
        newB = Vector{UnivariateDistribution}(undef, Kj)

        for (ρ, Mjρ) in enumerate(Mj.B)
            norm = 0.0
            newc = zeros(ncomponents(Mjρ))
            newd = Vector{Normal}(undef, length(Mj.B[ρ].components))

            for (l, Mjρl) in enumerate(Mj.B[ρ].components)
                newc[l] = Ω(base, j, ρ, z, νagg) do i, β, m
                    exp(logη[i,j][β,ρ][m,l])
                end

                newμ = Ω(base, j, ρ, z, νagg) do i, β, m
                    exp(logη[i,j][β,ρ][m,l]) * base.M[i].B[β].components[m].μ
                end

                newσ2 = Ω(base, j, ρ, z, νagg) do i, β, m
                    exp(logη[i,j][β,ρ][m,l]) * (base.M[i].B[β].components[m].σ^2 + (base.M[i].B[β].components[m].μ - Mjρl.μ)^2)
                end

                newμ  /= newc[l]
                newσ2 /= newc[l]
                norm  += newc[l]

                newd[l] = Normal(newμ, sqrt(newσ2))
            end
            
            newc /= norm
            newB[ρ] = MixtureModel(newd, newc)
        end

        # 2.d Build HMM
        newM[j] = HMM(newa, newA, newB)
    end

    H3M(newM, newω), lhmm, z
end

# TODO: Cleanup (perform computations in the M-step loop instead ?)
function Ω(f, b::H3M, j::Integer, ρ::Integer, z::AbstractMatrix, νagg)
    tot = 0.0
    for (i, ωi) in enumerate(b.ω)
        s = 0.0
        for β in 1:size(b.M[i],1)
            ss = 0.0
            for (m, c) in enumerate(b.M[i].B[β].prior.p)
                ss += c * f(i, β, m)
            end
            s += νagg[i,j][ρ,β] * ss
        end
        tot += z[i,j] * s
    end
    tot
end
