module TestLearningNetworks

# using Revise
using Test
using MLJ


# TRAINABLE MODELS

X_frame, y = datanow();  # boston data
X = array(X_frame)

knn_ = KNNRegressor(K=7)

# split the rows:
allrows = eachindex(y);
train, valid, test = partition(allrows, 0.7, 0.15);
@test vcat(train, valid, test) == allrows

Xtrain = X[train,:]
ytrain = y[train]

Xs = node(Xtrain)
ys = node(ytrain)

knn1 = trainable(knn_, Xs, ys)
fit!(knn1)
knn_.K = 5
fit!(knn1, 0)
rms(predict(knn1, Xs(X[test,:])), ys(y[test]))

@test MLJ.is_stale(knn1) == false

# TODO: compare to constant regressor and check it's significantly better


## LEARNING NODES

tape = MLJ.get_tape
@test isempty(tape(nothing))
@test isempty(tape(knn1))

XX = node(X_frame[train,:])
yy = node(y[train])

# construct a transformer to standardize the target:
uscale_ = UnivariateStandardizer()
uscale = trainable(uscale_, yy)

# get the transformed inputs, as if `uscale` were already fit:
z = transform(uscale, yy)

# construct a transformer to standardize the inputs:
scale_ = Standardizer() 
scale = trainable(scale_, XX) # no need to fit

# get the transformed inputs, as if `scale` were already fit:
Xt = transform(scale, XX)

# convert DataFrame Xt to an array:
Xa = array(Xt)

# choose a learner and make it trainable:
knn_ = KNNRegressor(K=7) # just a container for hyperparameters
knn = trainable(knn_, Xa, z) # no need to fit

# get the predictions, as if `knn` already fit:
zhat = predict(knn, Xa)

# inverse transform the target:
yhat = inverse_transform(uscale, zhat)

# fit-through training:
fit!(yhat)
fit!(yhat, 0)

rms(yhat(X_frame[test,:]), y[test])


## MAKE A COMPOSITE MODEL

import MLJ: Supervised, Transformer, LearningNode, TrainableModel, MLJType

mutable struct WetSupervised{L<:Supervised,
                             TX<:Transformer,
                             Ty<:Transformer} <: Supervised{LearningNode}
    learner::L
    transformer_X::TX
    transformer_y::Ty
end

import DecisionTree

tree_ = DecisionTreeClassifier(target_type=Int)
selector_ = FeatureSelector()
encoder_ = ToIntTransformer()

composite = WetSupervised(tree_, selector_, encoder_)

mutable struct WetSupervisedCache{L,TX,Ty} <: MLJType
    t_X::TrainableModel{TX}   
    t_y::TrainableModel{Ty}
    l::TrainableModel{L}
    transformer_X::TX      
    transformer_y::Ty
    learner::L
end

Xin, yin = X_and_y(load_iris());
train, test = partition(eachindex(yin), 0.7);
Xtrain = Xin[train,:];
ytrain = yin[train];

import MLJ: fit, predict, update
function fit(composite::WetSupervised, verbosity, Xtrain, ytrain)

    X = node(Xtrain) # instantiates a source node
    y = node(ytrain)
    
    t_X = trainable(composite.transformer_X, X)
    t_y = trainable(composite.transformer_y, y)

    Xt = array(transform(t_X, X))
    yt = transform(t_y, y)

    l = trainable(composite.learner, Xt, yt)
    zhat = predict(l, Xt)

    yhat = inverse_transform(t_y, zhat)
    fit!(yhat, verbosity-1)

    fitresult = yhat
    report = l.report
    cache = l
    
    return fitresult, cache, report

end

function update(composite::WetSupervised, verbosity, fitresult, cache, X, y; kwargs...)
    fit!(fitresult)
    return fitresult, cache, cache.report
end

predict(composite::WetSupervised, fitresult, Xnew) = fitresult(Xnew)

# let's train the composite:
fitresult, cache, report = fit(composite, 2, Xtrain, ytrain)

# to check internals:
encoder = fitresult.trainable
tree = fitresult.args[1].trainable
selector = fitresult.args[1].args[1].args[1].trainable

# this should trigger no retraining:
fitresult, cache, report = update(composite, 2, fitresult, cache, Xtrain, ytrain)
@test encoder.frozen && tree.frozen && selector.frozen

# this should trigger retraining of encoder and tree
encoder_.initial_label = 13
fitresult, cache, report = update(composite, 2, fitresult, cache, Xtrain, ytrain)
@test !encoder.frozen && !tree.frozen && selector.frozen

# this should trigger retraining of selector and tree:
selector_.features = [:petal_length,] 
fitresult, cache, report = update(composite, 2, fitresult, cache, Xtrain, ytrain)
@test encoder.frozen && !tree.frozen && !selector.frozen

# this should trigger retraining of tree only:
tree_.max_depth = 1
fitresult, cache, report = update(composite, 2, fitresult, cache, Xtrain, ytrain)
@test encoder.frozen && !tree.frozen && selector.frozen

# this should trigger retraining of all parts:
encoder_.initial_label = 42
selector_.features = []
fitresult, cache, report = update(composite, 2, fitresult, cache, Xtrain, ytrain)
@test !encoder.frozen && !tree.frozen && !selector.frozen

predict(composite, fitresult, Xin[test,:]);

end
