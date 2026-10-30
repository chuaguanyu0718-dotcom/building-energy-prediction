%% Predicting Building Energy Consumption
% Learn to Hack: MATLAB Edition 2026 (NTU)
%
% Run this script top to bottom (Run button, or F5).
% Each %% section is one stage of the pipeline, so it can also be opened
% as a Live Script: right-click main.m > Open as Live Script.
%
% Before the first run, fill in the three TODO lines in Section 1.

clear; clc; close all;
rng(42);   % fixed seed so splits and models are reproducible

%% 1. Configuration
cfg.dataFile = fullfile("data", "dataset.csv");  % TODO: real dataset file name
cfg.target   = "EnergyConsumption";              % TODO: real target column name
cfg.timeVar  = "";                               % TODO: timestamp column name, or "" if none
cfg.testFrac = 0.2;                              % fraction of rows held out for testing
cfg.tune     = false;                            % true = run Bayesian hyperparameter tuning (slow)
cfg.figDir   = fullfile("results", "figures");

if ~isfolder(cfg.figDir), mkdir(cfg.figDir); end

%% 2. Load data
T = readtable(cfg.dataFile, "TextType", "string");
fprintf("Loaded %d rows x %d columns\n", height(T), width(T));
summary(T)

%% 3. Explore
% Missing values per column
missingCount = sum(ismissing(T), 1)';
disp(table(string(T.Properties.VariableNames)', missingCount, ...
    'VariableNames', ["Variable", "Missing"]))

% Distribution of the target
figure;
histogram(T.(cfg.target));
title("Distribution of " + cfg.target); xlabel(cfg.target); ylabel("Count");
exportgraphics(gcf, fullfile(cfg.figDir, "01_target_hist.png"));

% Correlation between numeric columns
isNum   = varfun(@isnumeric, T, "OutputFormat", "uniform");
numVars = string(T.Properties.VariableNames(isNum));
figure;
heatmap(numVars, numVars, corr(T{:, numVars}, "Rows", "pairwise"), "Colormap", parula);
title("Correlation matrix (numeric columns)");
exportgraphics(gcf, fullfile(cfg.figDir, "02_correlation.png"));

%% 4. Clean
% 4a. Rows with no target value cannot be used for training
nBefore = height(T);
T = rmmissing(T, "DataVariables", cfg.target);
fprintf("Removed %d rows with missing target\n", nBefore - height(T));

% 4b. Text columns -> categorical (models treat them as groups, not strings)
isText  = varfun(@(x) isstring(x) || iscellstr(x), T, "OutputFormat", "uniform");
txtVars = string(T.Properties.VariableNames(isText));
txtVars(txtVars == cfg.timeVar) = [];
for v = txtVars
    T.(v) = categorical(T.(v));
end

% 4c. Missing numeric features -> column median (robust to outliers)
% TODO: justify this choice after looking at Section 3 output
featNum = setdiff(numVars, cfg.target);
for v = featNum
    col = T.(v);
    col(ismissing(col)) = median(col, "omitnan");
    T.(v) = col;
end

% 4d. Outliers in the target: report first, then decide (cap / remove / keep)
isOut = isoutlier(T.(cfg.target), "quartiles");
fprintf("%d target values flagged as outliers (%.1f%%)\n", sum(isOut), 100*mean(isOut));
% TODO: e.g. T(isOut, :) = [];   only if they are data errors, not real peaks

%% 5. Feature engineering
if cfg.timeVar ~= ""
    t = T.(cfg.timeVar);
    if ~isdatetime(t), t = datetime(t); end
    T.Hour      = hour(t);
    T.Month     = month(t);
    T.DayOfWeek = weekday(t);                 % 1 = Sunday, 7 = Saturday
    T.IsWeekend = ismember(T.DayOfWeek, [1 7]);
    T.(cfg.timeVar) = t;
    T = sortrows(T, cfg.timeVar);             % needed for the time-based split below
end
% TODO: add domain features, e.g. temperature x humidity, energy per floor area

%% 6. Split into training and test sets
n = height(T);
if cfg.timeVar ~= ""
    % Time-ordered data: train on earlier rows, test on later rows.
    % A random split would let the model see neighbouring hours from the
    % test period, which makes the test error look better than it is.
    nTrain = floor((1 - cfg.testFrac) * n);
    isTest = false(n, 1);
    isTest(nTrain+1:end) = true;
else
    cv     = cvpartition(n, "HoldOut", cfg.testFrac);
    isTest = test(cv);
end

predictors = setdiff(string(T.Properties.VariableNames), [cfg.target, cfg.timeVar]);
% Raw datetime/duration columns can't be used directly; their parts were extracted in Section 5
isTimeType = varfun(@(x) isdatetime(x) || isduration(x), T(:, predictors), "OutputFormat", "uniform");
predictors(isTimeType) = [];

Ttrain = T(~isTest, [predictors, cfg.target]);
Xtest  = T(isTest, predictors);
ytest  = T.(cfg.target)(isTest);
fprintf("Train: %d rows | Test: %d rows | Predictors: %d\n", ...
    height(Ttrain), height(Xtest), numel(predictors));

%% 7. Train and compare models
% Ordered from simplest (most interpretable) to most flexible.
modelNames = ["Linear", "Tree", "BoostedTrees", "BaggedTrees", "NeuralNet"];
trainers = {
    @(tbl) fitlm(tbl, "ResponseVar", cfg.target)
    @(tbl) fitrtree(tbl, cfg.target)
    @(tbl) fitrensemble(tbl, cfg.target, "Method", "LSBoost", "NumLearningCycles", 200)
    @(tbl) fitrensemble(tbl, cfg.target, "Method", "Bag", "NumLearningCycles", 200)
    @(tbl) fitrnet(tbl, cfg.target, "Standardize", true, "LayerSizes", [32 16])
};

results = table('Size', [0 5], ...
    'VariableTypes', ["string", "double", "double", "double", "double"], ...
    'VariableNames', ["Model", "RMSE", "MAE", "R2", "TrainSeconds"]);
trained = struct();

for i = 1:numel(modelNames)
    try
        tic;
        mdl  = trainers{i}(Ttrain);
        secs = toc;
        yhat = predict(mdl, Xtest);
        [rmse, mae, r2] = regressionMetrics(ytest, yhat);
        results(end+1, :) = {modelNames(i), rmse, mae, r2, secs}; %#ok<SAGROW>
        trained.(modelNames(i)) = mdl;
        fprintf("%-13s RMSE = %.3f   R2 = %.3f   (%.1fs)\n", modelNames(i), rmse, r2, secs);
    catch err
        warning("%s failed: %s", modelNames(i), err.message);
    end
end

if isempty(results)
    error("Every model failed to train. Check the warnings above.");
end
results = sortrows(results, "RMSE");
disp(results)
writetable(results, fullfile("results", "model_comparison.csv"));

%% 8. (Optional) Tune the boosted ensemble
if cfg.tune
    opts = struct("MaxObjectiveEvaluations", 30, "ShowPlots", false, "Verbose", 0);
    tic;
    mdl = fitrensemble(Ttrain, cfg.target, "Method", "LSBoost", ...
        "OptimizeHyperparameters", {'NumLearningCycles', 'LearnRate', 'MinLeafSize'}, ...
        "HyperparameterOptimizationOptions", opts);
    secs = toc;
    yhat = predict(mdl, Xtest);
    [rmse, mae, r2] = regressionMetrics(ytest, yhat);
    results(end+1, :) = {"TunedBoosted", rmse, mae, r2, secs};
    trained.TunedBoosted = mdl;
    results = sortrows(results, "RMSE");
    disp(results)
    writetable(results, fullfile("results", "model_comparison.csv"));
end

%% 9. Evaluate the best model
bestName = results.Model(1);
best     = trained.(bestName);
yhat     = predict(best, Xtest);
fprintf("Best model: %s\n", bestName);

% Predicted vs actual
figure;
scatter(ytest, yhat, 10, "filled", "MarkerFaceAlpha", 0.4); hold on;
lims = [min([ytest; yhat]), max([ytest; yhat])];
plot(lims, lims, "k--", "LineWidth", 1); hold off;
xlabel("Actual"); ylabel("Predicted");
title(sprintf("%s: predicted vs actual (R^2 = %.3f)", bestName, results.R2(1)));
exportgraphics(gcf, fullfile(cfg.figDir, "03_pred_vs_actual.png"));

% Residuals: should be centred on 0 with no pattern
figure;
scatter(yhat, ytest - yhat, 10, "filled", "MarkerFaceAlpha", 0.4);
yline(0, "k--");
xlabel("Predicted"); ylabel("Residual (actual - predicted)");
title(bestName + ": residuals");
exportgraphics(gcf, fullfile(cfg.figDir, "04_residuals.png"));

% Which features drive consumption (tree-based models only)
if ismethod(best, "predictorImportance")
    imp = predictorImportance(best);
    [imp, order] = sort(imp, "descend");
    names = string(best.PredictorNames(order));
    figure;
    barh(categorical(names, flip(names)), imp);
    title(bestName + ": feature importance"); xlabel("Importance");
    exportgraphics(gcf, fullfile(cfg.figDir, "05_feature_importance.png"));
end

save(fullfile("results", "best_model.mat"), "best", "bestName", "cfg");

%% Local functions
function [rmse, mae, r2] = regressionMetrics(y, yhat)
% Root-mean-square error, mean absolute error and R^2 on rows with no NaNs.
    ok   = ~isnan(y) & ~isnan(yhat);
    y    = y(ok);
    yhat = yhat(ok);
    err  = y - yhat;
    rmse = sqrt(mean(err.^2));
    mae  = mean(abs(err));
    r2   = 1 - sum(err.^2) / sum((y - mean(y)).^2);
end
