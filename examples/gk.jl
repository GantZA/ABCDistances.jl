using ABCDistances
using Distributions
import Distributions.length, Distributions._rand!, Distributions._pdf ##So that these can be extended
using PyPlot
using StatsBase
using ProgressMeter

#########################
##DEFINE MODELS AND PRIOR
#########################
##Define prior: uniform on [0,10]^4
type GKPrior <: ContinuousMultivariateDistribution
end

function length(d::GKPrior)
    4
end

function _rand!{T<:Real}(d::GKPrior, x::AbstractVector{T})
    x = 10.0*rand(4)
end

function _pdf{T<:Real}(d::GKPrior, x::AbstractVector{T})
    if (all(0.0 .<= x .<= 10.0))
        return 0.0001
    else
        return 0.0
    end
end

##Define model and summary statistics
quantiles = [1250*i for i in 1:7];
ndataset = 10000;

function sample_sumstats(pars::Array{Float64,1})
    success = true
    stats = rgk_os(pars, quantiles, ndataset)
    (success, stats)
end

################################################
##DETAILED ANALYSIS OF A SINGLE OBSERVED DATASET
################################################
theta0 = [3.0,1.0,1.5,0.5]
srand(1)
(success, sobs) = sample_sumstats(theta0)

abcinput = ABCInput();
abcinput.prior = GKPrior();
abcinput.sample_sumstats = sample_sumstats;
abcinput.abcdist = WeightedEuclidean(sobs);
abcinput.nsumstats = length(quantiles);

##Perform ABC-SMC
smcoutput1 = abcSMC(abcinput, 1000, 1/3, 1000000);
smcoutput2 = abcSMC(abcinput, 1000, 1/3, 1000000, adaptive=true);
smcoutput3 = abcSMC_comparison(abcinput, 1000, 1/3, 1000000);
abcinput.abcdist = MahalanobisEmp(sobs);
smcoutput4 = abcSMC(abcinput, 1000, 1/3, 1000000, adaptive=true);

##Plot MSEs (and also bias^2, variance)
b1 = parameter_means(smcoutput1);
b2 = parameter_means(smcoutput2);
b3 = parameter_means(smcoutput3);
b4 = parameter_means(smcoutput4);
v1 = parameter_vars(smcoutput1);
v2 = parameter_vars(smcoutput2);
v3 = parameter_vars(smcoutput3);
v4 = parameter_vars(smcoutput4);
c1 = smcoutput1.cusims ./ 1000;
c2 = smcoutput2.cusims ./ 1000;
c3 = smcoutput3.cusims ./ 1000;
c4 = smcoutput4.cusims ./ 1000;
PyPlot.figure(figsize=(12,8))
pnames = ("A", "B", "g", "k")
for i in 1:4
    PyPlot.subplot(220+i)
    PyPlot.plot(c3, vec(log10(v3[i,:] .+ (b3[i,:]-theta0[i]).^2)), "b-o")
    PyPlot.plot(c2, vec(log10(v2[i,:] .+ (b2[i,:]-theta0[i]).^2)), "g-^")
    PyPlot.title(pnames[i])
    PyPlot.xlabel("Number of simulations (000s)")
    PyPlot.ylabel("log₁₀(MSE)")
    PyPlot.legend(["Algorithm 3","Algorithm 4"])
end
PyPlot.tight_layout();
PyPlot.savefig("gk_mse.pdf")

PyPlot.figure()
for i in 1:4
    PyPlot.subplot(220+i)
    PyPlot.plot(c1, vec(log10(v1[i,:])), "r-x")
    PyPlot.plot(c2, vec(log10(v2[i,:])), "g-^")
    PyPlot.plot(c3, vec(log10(v3[i,:])), "b-o")
    PyPlot.plot(c4, vec(log10(v4[i,:])), "k-|")
    PyPlot.axis([0,maximum([c1,c2,c3,c4]),-4,1]);
    PyPlot.title(pnames[i])
    PyPlot.xlabel("Number of simulations (000s)")
    PyPlot.ylabel("log₁₀(estimated variance)")
    PyPlot.legend(["Non-adaptive (alg 4)","Adaptive (alg 4)","Non-adaptive (alg 3)", "Mahalanobis"])
end

PyPlot.figure()
for i in 1:4
    PyPlot.subplot(220+i)
    PyPlot.plot(c1, vec(log10((b1[i,:]-theta0[i]).^2)), "b-o")
    PyPlot.plot(c2, vec(log10((b2[i,:]-theta0[i]).^2)), "g-^")
    PyPlot.plot(c3, vec(log10((b3[i,:]-theta0[i]).^2)), "r-x")
    PyPlot.plot(c4, vec(log10((b4[i,:]-theta0[i]).^2)), "k-|")
    PyPlot.title(pnames[i])
    PyPlot.xlabel("Number of simulations (000s)")
    PyPlot.ylabel("log₁₀(bias squared)")
    PyPlot.legend(["Non-adaptive (alg 4)","Adaptive (alg 4)","Non-adaptive (alg 3)", "Mahalanobis"])
end

##Compute weights
w1 = smcoutput1.abcdists[1].w;
w2 = Array(Float64, (smcoutput2.niterations, length(quantiles)));
for i in 1:smcoutput2.niterations
    w2[i,:] = smcoutput2.abcdists[i].w
end
w3 = smcoutput3.abcdists[1].w;

##Plot weights
PyPlot.figure(figsize=(12,4))
PyPlot.plot(quantiles, w3/sum(w3), "-o")
wlast = vec(w2[smcoutput2.niterations, :])
PyPlot.plot(quantiles, wlast/sum(wlast), "-^")
##PyPlot.axis([1.0,9.0,0.0,0.35]) ##Sometimes needed to fit legend in
PyPlot.legend(["Algorithm 3","Algorithm 4\n(last iteration)"])
PyPlot.xlabel("Order statistic")
PyPlot.ylabel("Relative weight")
PyPlot.tight_layout();
PyPlot.savefig("gk_weights.pdf")

###############################
##ANALYSIS OF MULTIPLE DATASETS
###############################
ndatasets = 100;
trueθs = zeros((4, ndatasets));
RMSEs = zeros((4, 4, ndatasets)); ##Indices are: parameters, method, dataset
vars =  zeros((4, 4, ndatasets,));
squaredbiases = zeros((4, 4, ndatasets));

##Returns squared bias, variance and RMSE of weighted posterior sample wrt true parameters
function getError(s::ABCSMCOutput, pobs::Array{Float64, 1})
    n = s.niterations
    p = squeeze(s.parameters[:,:,n], 3)
    wv = WeightVec(vec(s.weights[:,n]))
    bias2 = (mean(p, wv, 2) - pobs).^2
    bias2 = vec(bias2)
    v = var(p, wv, 2)
    v = vec(v)
    rmse = sqrt(bias2 + v)
    (bias2, v, rmse)
end

abcinput = ABCInput();
abcinput.prior = GKPrior();
abcinput.sample_sumstats = sample_sumstats;
abcinput.nsumstats = length(quantiles);

srand(1);
for i in 1:ndatasets
    if i==1
        prog = Progress(4*ndatasets, 1) ##Progress meter
    end
    theta0 = rand(GKPrior())
    (success, sobs) = sample_sumstats(theta0)
    abcinput.abcdist = WeightedEuclidean(sobs)
    smcoutput1 = abcSMC(abcinput, 1000, 1/3, 1000000, silent=true)
    next!(prog)
    smcoutput2 = abcSMC(abcinput, 1000, 1/3, 1000000, adaptive=true, silent=true)
    next!(prog)
    smcoutput3 = abcSMC_comparison(abcinput, 1000, 1/3, 1000000, silent=true)
    next!(prog)
    abcinput.abcdist = MahalanobisEmp(sobs)
    smcoutput4 = abcSMC(abcinput, 1000, 1/3, 1000000, adaptive=true, silent=true)
    next!(prog)    
    trueθs[:,i] = theta0
    (squaredbiases[:,1,i], vars[:,1,i], RMSEs[:,1,i]) = getError(smcoutput1, theta0)
    (squaredbiases[:,2,i], vars[:,2,i], RMSEs[:,2,i]) = getError(smcoutput2, theta0)
    (squaredbiases[:,3,i], vars[:,3,i], RMSEs[:,3,i]) = getError(smcoutput3, theta0)
    (squaredbiases[:,4,i], vars[:,4,i], RMSEs[:,4,i]) = getError(smcoutput4, theta0)
end

##Summarise output
mean(RMSEs, 3)
mean(vars, 3)
mean(squaredbiases, 3)

##Save output for further analysis without lengthy rerun
writedlm("gk_RMSE.txt", RMSEs)
writedlm("gk_vars.txt", vars)
writedlm("gk_bias2.txt", squaredbiases)
writedlm("gk_thetas.txt", trueθs)
