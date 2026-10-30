%% Predicting Building Energy Use and Prioritising Retrofits
% Learn To Hack: MATLAB Edition 2026 (NTU)
%
% GOAL
%   1. Predict a building's Site Energy Use Intensity (site EUI, in
%      kBtu per square foot per year) from its characteristics and the
%      weather it experienced that year.
%   2. Build a "fair benchmark" model that predicts how much energy a
%      building SHOULD use given only its type, size, age, location and
%      weather. Buildings that use far more than their benchmark are the
%      retrofit candidates, ranked by wasted energy and CO2.
%
% DATA
%   WiDS Datathon 2022: train.csv (labelled, Years 1-6) and test.csv
%   (unlabelled, Year 7). One row = one building in one year.
%
% HOW TO RUN
%   Put train.csv and test.csv next to this file (or in ./data), then Run.
%   Set cfg.fastMode = true for a quick (~2 min) error check.
%
% OUTPUTS
%   figures/  PNG plots used in the presentation
%   results/  model_comparison.csv, retrofit_priority_list.csv,
%             year7_predictions.csv, summary.txt, models.mat

clear; clc; close all;
rng(42);                                   % reproducible results
set(groot, 'defaultAxesFontSize', 12);

%% 1. Configuration
cfg.fastMode   = false;          % true = fewer trees, for a quick (~3 min) error check
cfg.flagRatio  = 1.5;            % retrofit candidate if actual EUI >= 1.5 x expected
cfg.errorRatio = 5;              % >= 5 x expected is more likely a meter/data error
cfg.kBtuToMWh  = 0.29307107e-3;  % 1 kBtu = 0.293 kWh = 0.000293 MWh
cfg.tCO2perMWh = 0.38;           % ASSUMED emission factor (approx. US grid average)
cfg.numBins    = 50;             % bin numeric predictors -> much faster tree training

if cfg.fastMode
    cfg.nBag = 30;  cfg.nBoost = 100; cfg.tuneCycles = 200; cfg.netIter = 100;
    cfg.tuneSplits = [15 30]; cfg.tuneRates = 0.1;
else
    cfg.nBag = 100; cfg.nBoost = 300; cfg.tuneCycles = 600; cfg.netIter = 500;
    cfg.tuneSplits = [15 30 60]; cfg.tuneRates = [0.05 0.1];
end

% Locate the data (next to this script, in ./data, or in the current folder)
scriptDir = fileparts(mfilename('fullpath'));
candidates = {scriptDir, fullfile(scriptDir, 'data'), pwd, fullfile(pwd, 'data')};
dataDir = '';
for c = 1:numel(candidates)
    if ~isempty(candidates{c}) && isfile(fullfile(candidates{c}, 'train.csv'))
        dataDir = candidates{c};
        break
    end
end
assert(~isempty(dataDir), ...
    'train.csv not found. Put train.csv and test.csv next to this script or in ./data');
[parentDir, lastFolder] = fileparts(dataDir);
if strcmp(lastFolder, 'data')
    projectDir = parentDir;
else
    projectDir = dataDir;
end
figDir = fullfile(projectDir, 'figures');
resDir = fullfile(projectDir, 'results');
if ~isfolder(figDir), mkdir(figDir); end
if ~isfolder(resDir), mkdir(resDir); end

%% 2. Load data
% State, building class and facility type are labels, not numbers, so
% they are imported as categorical. Tree models split on them natively.
catVars = {'State_Factor', 'building_class', 'facility_type'};

opts = detectImportOptions(fullfile(dataDir, 'train.csv'));
opts = setvartype(opts, catVars, 'categorical');
Data = readtable(fullfile(dataDir, 'train.csv'), opts);     % labelled, Years 1-6

opts = detectImportOptions(fullfile(dataDir, 'test.csv'));
opts = setvartype(opts, catVars, 'categorical');
Year7 = readtable(fullfile(dataDir, 'test.csv'), opts);     % unlabelled, Year 7

for v = catVars          % give Year 7 exactly the same category lists as training
    Year7.(v{1}) = setcats(Year7.(v{1}), categories(Data.(v{1})));
end
fprintf('Labelled data: %d rows x %d columns | Year 7 (unlabelled): %d rows\n', ...
    height(Data), width(Data), height(Year7));

%% 3. Explore and clean
% 3a. The target is heavily right-skewed: most buildings are 50-100 but a
% few exceed 900. Squared-error models chase those outliers, so we also
% try modelling log(site EUI).
fig = figure('Name', 'Target distribution');
tiledlayout(1, 2, 'Padding', 'compact');
nexttile
histogram(Data.site_eui, 100);
xlabel('Site EUI (kBtu/ft^2/yr)'); ylabel('Building-years');
title('Raw: long right tail');
nexttile
histogram(log(Data.site_eui), 100);
xlabel('log(Site EUI)');
title('Log scale: close to symmetric');
saveFig(fig, figDir, 'fig01_target_distribution');

% 3b. Missing values: compare train and test
commonVars = intersect(Data.Properties.VariableNames, Year7.Properties.VariableNames, 'stable');
missTrain = varfun(@(x) mean(ismissing(x)), Data(:, commonVars),  'OutputFormat', 'uniform');
missTest  = varfun(@(x) mean(ismissing(x)), Year7(:, commonVars), 'OutputFormat', 'uniform');
hasMiss = missTrain > 0 | missTest > 0;

fig = figure('Name', 'Missing values');
bar(100 * [missTrain(hasMiss); missTest(hasMiss)]');
xticks(1:sum(hasMiss));
xticklabels(strrep(commonVars(hasMiss), '_', ' ')); xtickangle(30);
ylabel('% missing'); yline(50, '--', '50% drop threshold');
legend('Train (Years 1-6)', 'Test (Year 7)', 'Location', 'northwest');
title('Wind and fog columns are mostly empty, and emptier still in test');
saveFig(fig, figDir, 'fig02_missing_values');

% Decision: drop columns that are more than half empty (imputing them would
% mostly invent data). Energy Star (35% missing) and year built (2%) are
% kept and imputed later, using training data only.
sparseVars = commonVars(missTrain > 0.5);
Data  = removevars(Data, sparseVars);
Year7 = removevars(Year7, sparseVars);
fprintf('Dropped %d sparse columns (>50%% missing): %s\n', numel(sparseVars), strjoin(sparseVars, ', '));

% 3c. Distribution shift: which states appear in train vs test?
stateNames = categories(Data.State_Factor);
pctTrain = 100 * countcats(Data.State_Factor)  / height(Data);
pctTest  = 100 * countcats(Year7.State_Factor) / height(Year7);
isS6 = strcmp(stateNames, 'State_6');

fig = figure('Name', 'State distribution shift');
bar([pctTrain, pctTest]);
xticks(1:numel(stateNames)); xticklabels(strrep(stateNames, '_', ' '));
ylabel('% of rows'); legend('Train (Years 1-6)', 'Test (Year 7)');
title(sprintf('State 6 is %.0f%% of training rows but %.0f%% of test rows', ...
    pctTrain(isS6), pctTest(isS6)));
saveFig(fig, figDir, 'fig03_state_shift');
% Consequence: we report accuracy both overall and EXCLUDING State 6,
% because the excluding-State-6 number is closer to what Year 7 looks like.

% 3d. Exact duplicates and impossible values
dupVars = setdiff(Data.Properties.VariableNames, {'id'}, 'stable');
[~, keepIdx] = unique(Data(:, dupVars), 'stable');
fprintf('Removed %d exact duplicate rows\n', height(Data) - numel(keepIdx));
Data = Data(keepIdx, :);
fprintf('year_built < 1800 (impossible, e.g. 0): %d rows -> treated as missing\n', ...
    sum(Data.year_built < 1800));

%% 4. Feature engineering
Data  = prepareFeatures(Data);
Year7 = prepareFeatures(Year7);

% The 36 monthly temperature columns are near-duplicates of each other and
% of the degree-day columns (see heatmap). We replace them with two
% seasonal summaries: winter minimum and summer maximum temperature.
months = {'january', 'february', 'march', 'april', 'may', 'june', 'july', ...
          'august', 'september', 'october', 'november', 'december'};
corrVars = [strcat(months, '_avg_temp'), {'avg_temp', 'heating_degree_days', 'cooling_degree_days'}];
R = corrcoef(Data{:, corrVars});

fig = figure('Name', 'Weather correlation', 'Position', [100 100 850 700]);
h = heatmap(strrep(corrVars, '_', ' '), strrep(corrVars, '_', ' '), round(R, 1));
h.Title = 'Monthly temperatures are highly correlated -> summarise them';
h.FontSize = 9;
saveFig(fig, figDir, 'fig04_weather_correlation');

weatherVars  = {'ELEVATION', 'cooling_degree_days', 'heating_degree_days', ...
    'precipitation_inches', 'snowfall_inches', 'snowdepth_inches', 'avg_temp', ...
    'days_below_30F', 'days_below_20F', 'days_below_10F', 'days_below_0F', ...
    'days_above_80F', 'days_above_90F', 'days_above_100F', 'days_above_110F', ...
    'winter_min_temp', 'summer_max_temp'};
buildingVars = {'State_Factor', 'building_class', 'facility_type', 'log_floor_area', 'year_built'};
starVars     = {'energy_star_rating', 'star_missing'};

predFull   = [buildingVars, starVars, weatherVars];          % accuracy model
predBench  = [buildingVars, weatherVars];                    % fair benchmark: NO Energy Star
predLinear = setdiff(predFull, {'building_class'}, 'stable'); % class is implied by facility type
% Year_Factor is NOT a predictor: it is an anonymised index, and Year 7
% lies outside the training range, so the model cannot learn anything
% useful from it.

% Pseudo building ID: there is no building ID column, but the same building
% re-appears across years with identical state, type, floor area, year built
% and elevation. We need this to stop the retrofit benchmark "remembering"
% the building it is judging.
yb = Data.year_built;  yb(isnan(yb)) = -1;
Data.building_id = findgroups(Data.State_Factor, Data.facility_type, ...
    Data.floor_area, yb, Data.ELEVATION);
fprintf('%d rows come from %d distinct buildings\n', height(Data), max(Data.building_id));

%% 5. Split by YEAR, not randomly
% Year 7 (the real test set) is a FUTURE year, so we validate the same way:
%   Tuning  : only Years 1-5 (tree: train 1-4 / check 5; boosting:
%             time-series CV, train 1-3 / check 4 and train 1-4 / check 5)
%   Testing : train on Years 1-5, report final accuracy on Year 6
%             (Year 6 is never used for any modelling decision)
idxTuneFit = Data.Year_Factor <= 4;
idxTune    = Data.Year_Factor == 5;
idxDev     = Data.Year_Factor <= 5;
idxTest    = Data.Year_Factor == 6;
nonS6Test  = Data.State_Factor(idxTest) ~= 'State_6';
fprintf('Tune-fit %d | Tune %d | Dev (Years 1-5) %d | Test (Year 6) %d rows\n', ...
    sum(idxTuneFit), sum(idxTune), sum(idxDev), sum(idxTest));

% Missing Energy Star / year built are filled with the median for that
% facility type, computed from the TRAINING rows only (see buildXY).
[Xdev, Xtest]      = buildXY(Data(idxDev, :),     Data(idxTest, :), predFull);
[XtuneFit, Xtune]  = buildXY(Data(idxTuneFit, :), Data(idxTune, :), predFull);
yDev     = Data.site_eui(idxDev);      yTest = Data.site_eui(idxTest);
yTuneFit = Data.site_eui(idxTuneFit);  yTune = Data.site_eui(idxTune);

results = table('Size', [0 5], ...
    'VariableTypes', {'string', 'double', 'double', 'double', 'double'}, ...
    'VariableNames', {'Model', 'RMSE', 'MAE', 'R2', 'RMSE_excl_State6'});
predAll = zeros(sum(idxTest), 8);     % every model's Year 6 predictions (for the app)

%% 6. Model iteration (each step must beat the previous one)
fprintf('\n--- Year 6 hold-out results ---\n');

% M0. Baseline: predict the median EUI of the building's facility type
[g, typeList] = findgroups(Data.facility_type(idxDev));
typeMedian = splitapply(@median, yDev, g);
[found, loc] = ismember(Xtest.facility_type, typeList);
pred = repmat(median(yDev), height(Xtest), 1);
pred(found) = typeMedian(loc(found));
results = [results; scoreModel('0. Facility-type median', yTest, pred, nonS6Test)];
predAll(:, 1) = pred;

% M1. Linear regression: simple and interpretable, but assumes every
% effect is additive and straight-line.
lmData = [Xdev(:, predLinear), table(yDev, 'VariableNames', {'site_eui'})];
lm = fitlm(lmData, 'linear', 'ResponseVar', 'site_eui');
pred = predict(lm, Xtest(:, predLinear));
results = [results; scoreModel('1. Linear regression', yTest, pred, nonS6Test)];
predAll(:, 2) = pred;

% M2. Single regression tree: captures non-linear effects and interactions
% (e.g. hospitals in cold states). Leaf size tuned on Year 5.
leafSizes = [5 10 20 50 100 200];
leafRMSE = zeros(size(leafSizes));
for i = 1:numel(leafSizes)
    t = fitrtree(XtuneFit, yTuneFit, 'MinLeafSize', leafSizes(i));
    leafRMSE(i) = rmseOf(predict(t, Xtune), yTune);
end
[~, iBest] = min(leafRMSE);
bestLeaf = leafSizes(iBest);
tree = fitrtree(Xdev, yDev, 'MinLeafSize', bestLeaf);
pred = predict(tree, Xtest);
results = [results; scoreModel(sprintf('2. Regression tree (leaf=%d)', bestLeaf), yTest, pred, nonS6Test)];
predAll(:, 3) = pred;

fig = figure('Name', 'Tree tuning');
semilogx(leafSizes, leafRMSE, '-o', 'LineWidth', 2, 'MarkerFaceColor', 'auto');
hold on; plot(bestLeaf, leafRMSE(iBest), 'kp', 'MarkerSize', 16, 'MarkerFaceColor', 'y');
xlabel('MinLeafSize'); ylabel('RMSE on Year 5 (tuning set)'); grid on;
title('Single tree: small leaves overfit, large leaves underfit');
saveFig(fig, figDir, 'fig05_tree_tuning');

% M3. Bagged trees (random forest): averages many deep trees, each trained
% on a bootstrap sample with a random third of the predictors -> lower variance.
tic;
bagTemplate = templateTree('MinLeafSize', 5, 'NumVariablesToSample', round(numel(predFull) / 3));
bag = fitrensemble(Xdev, yDev, 'Method', 'Bag', 'NumLearningCycles', cfg.nBag, ...
    'Learners', bagTemplate, 'NumBins', cfg.numBins);
pred = predict(bag, Xtest);
results = [results; scoreModel(sprintf('3. Bagged trees (%d)', cfg.nBag), yTest, pred, nonS6Test)];
predAll(:, 4) = pred;
fprintf('   (bagging took %.0f s)\n', toc);

% M4/M5. Gradient boosting (LSBoost): adds small trees one at a time, each
% correcting the errors of the previous ones. Same settings, raw vs log target.
boostTemplate = templateTree('MaxNumSplits', 30, 'MinLeafSize', 20);
tic;
boostRaw = fitrensemble(Xdev, yDev, 'Method', 'LSBoost', 'NumLearningCycles', cfg.nBoost, ...
    'LearnRate', 0.1, 'Learners', boostTemplate, 'NumBins', cfg.numBins);
pred = predict(boostRaw, Xtest);
results = [results; scoreModel('4. Boosted trees (raw target)', yTest, pred, nonS6Test)];
predAll(:, 5) = pred;

boostLog = fitrensemble(Xdev, log(yDev), 'Method', 'LSBoost', 'NumLearningCycles', cfg.nBoost, ...
    'LearnRate', 0.1, 'Learners', boostTemplate, 'NumBins', cfg.numBins);
predBoostLog = exp(predict(boostLog, Xtest));
results = [results; scoreModel('5. Boosted trees (log target)', yTest, predBoostLog, nonS6Test)];
predAll(:, 6) = predBoostLog;
fprintf('   (two boosting fits took %.0f s)\n', toc);

% M6. Neural network: a different model family for comparison. Two hidden
% layers on standardised inputs (categoricals are dummy-encoded
% automatically). Log-predictions are clipped to the training range so a
% single extreme output cannot explode after exp().
tic;
net = fitrnet(Xdev, log(yDev), 'LayerSizes', [64 32], 'Standardize', true, ...
    'Lambda', 1e-5, 'IterationLimit', cfg.netIter);
logPredNet = min(max(predict(net, Xtest), log(min(yDev))), log(max(yDev)));
results = [results; scoreModel('6. Neural network (log target)', yTest, exp(logPredNet), nonS6Test)];
predAll(:, 7) = exp(logPredNet);
fprintf('   (neural network took %.0f s)\n', toc);

% M7. Tuned boosting with expanding-window (time-series) cross-validation:
%   fold 1: train Years 1-3, validate on Year 4
%   fold 2: train Years 1-4, validate on Year 5
% Tuning on a single year over-fitted to that year's quirks (Year 5 has a
% state never seen before), so we average the error over two future years.
% The grid includes the untuned settings (30 splits, rate 0.1), and one fit
% gives the error after EVERY number of trees ('cumulative' loss), so the
% number of trees is tuned for free.
tic;
foldFit = {Data.Year_Factor <= 3, Data.Year_Factor <= 4};
foldVal = {Data.Year_Factor == 4, Data.Year_Factor == 5};
nFolds = numel(foldFit);
Xf = cell(nFolds, 2);  yf = cell(nFolds, 2);
for f = 1:nFolds
    [Xf{f, 1}, Xf{f, 2}] = buildXY(Data(foldFit{f}, :), Data(foldVal{f}, :), predFull);
    yf{f, 1} = Data.site_eui(foldFit{f});
    yf{f, 2} = Data.site_eui(foldVal{f});
end
best = struct('loss', Inf, 'splits', NaN, 'lr', NaN, 'k', NaN);
curves = cell(numel(cfg.tuneSplits), numel(cfg.tuneRates));
for i = 1:numel(cfg.tuneSplits)
    for j = 1:numel(cfg.tuneRates)
        mseSum = [];
        for f = 1:nFolds
            ens = fitrensemble(Xf{f, 1}, log(yf{f, 1}), 'Method', 'LSBoost', ...
                'NumLearningCycles', cfg.tuneCycles, 'LearnRate', cfg.tuneRates(j), ...
                'Learners', templateTree('MaxNumSplits', cfg.tuneSplits(i), 'MinLeafSize', 20), ...
                'NumBins', cfg.numBins);
            L = loss(ens, Xf{f, 2}, log(yf{f, 2}), 'Mode', 'cumulative');
            L = L(:);
            if isempty(mseSum)
                mseSum = L;
            else
                n = min(numel(mseSum), numel(L));
                mseSum = mseSum(1:n) + L(1:n);
            end
        end
        cvRMSE = sqrt(mseSum / nFolds);       % average over the two time folds
        curves{i, j} = cvRMSE;
        [Lmin, k] = min(cvRMSE);
        if Lmin < best.loss
            best = struct('loss', Lmin, 'splits', cfg.tuneSplits(i), 'lr', cfg.tuneRates(j), 'k', k);
        end
    end
end
fprintf('   Best (2-fold time CV): MaxNumSplits=%d, LearnRate=%.2f, %d trees (tuning took %.0f s)\n', ...
    best.splits, best.lr, best.k, toc);

fig = figure('Name', 'Boosting tuning');
hold on; legendText = {};
for i = 1:numel(cfg.tuneSplits)
    for j = 1:numel(cfg.tuneRates)
        plot(curves{i, j}, 'LineWidth', 1.8);
        legendText{end + 1} = sprintf('MaxNumSplits = %d, LearnRate = %.2f', ...
            cfg.tuneSplits(i), cfg.tuneRates(j)); %#ok<SAGROW>
    end
end
plot(best.k, best.loss, 'kp', 'MarkerSize', 16, 'MarkerFaceColor', 'y');
legendText{end + 1} = 'Chosen';
legend(legendText, 'Location', 'northeast');
xlabel('Number of trees'); ylabel('RMSE of log(EUI), avg of Years 4 and 5'); grid on;
title('Boosting tuned by time-series cross-validation');
saveFig(fig, figDir, 'fig06_boosting_tuning');

bestTemplate = templateTree('MaxNumSplits', best.splits, 'MinLeafSize', 20);
tuned = fitrensemble(Xdev, log(yDev), 'Method', 'LSBoost', 'NumLearningCycles', best.k, ...
    'LearnRate', best.lr, 'Learners', bestTemplate, 'NumBins', cfg.numBins);
predTuned = exp(predict(tuned, Xtest));
results = [results; scoreModel('7. Tuned boosted trees (log)', yTest, predTuned, nonS6Test)];
predAll(:, 8) = predTuned;

writetable(results, fullfile(resDir, 'model_comparison.csv'));

% Save every model's Year 6 predictions so RetrofitRadarApp can re-score
% the models on any segment (e.g. one building type) interactively.
Year6Pred = [Data(idxTest, {'id', 'facility_type', 'State_Factor', 'site_eui'}), ...
    array2table(predAll, 'VariableNames', {'m0_baseline', 'm1_linear', 'm2_tree', 'm3_bagged', ...
    'm4_boost_raw', 'm5_boost_log', 'm6_neural_net', 'm7_tuned_boost'})];
writetable(Year6Pred, fullfile(resDir, 'year6_model_predictions.csv'));

fig = figure('Name', 'Model comparison', 'Position', [100 100 950 550]);
bar(results.RMSE, 'FaceColor', [0.27 0.62 0.75]);
xticks(1:height(results)); xticklabels(results.Model); xtickangle(25);
text(1:height(results), results.RMSE, compose('%.1f', results.RMSE), ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', 'FontWeight', 'bold');
ylabel('RMSE on Year 6 (kBtu/ft^2/yr)  - lower is better'); grid on;
title('Each modelling step, scored on a year the models never saw');
saveFig(fig, figDir, 'fig07_model_comparison');

%% 7. Inspect the final accuracy model
finalTestR2 = results.R2(end);

% 7a. Predicted vs actual on Year 6
fig = figure('Name', 'Predicted vs actual');
scatter(yTest, predTuned, 6, 'filled', 'MarkerFaceAlpha', 0.15);
hold on; lims = [1 1000];
plot(lims, lims, 'k--', 'LineWidth', 1.5);
set(gca, 'XScale', 'log', 'YScale', 'log'); xlim(lims); ylim(lims); axis square; grid on;
xlabel('Actual site EUI'); ylabel('Predicted site EUI');
title(sprintf('Year 6 hold-out (%d buildings): R^2 = %.2f', numel(yTest), finalTestR2));
saveFig(fig, figDir, 'fig08_predicted_vs_actual');

% 7b. Which inputs matter most?
imp = predictorImportance(tuned);
[impSorted, order] = sort(imp, 'descend');
nShow = min(15, numel(imp));
fig = figure('Name', 'Feature importance (accuracy model)', 'Position', [100 100 800 600]);
barh(impSorted(1:nShow), 'FaceColor', [0.85 0.45 0.2]);
yticks(1:nShow); yticklabels(strrep(tuned.PredictorNames(order(1:nShow)), '_', ' '));
set(gca, 'YDir', 'reverse'); xlabel('Predictor importance'); grid on;
title('Accuracy model: what drives the predictions');
saveFig(fig, figDir, 'fig09_importance_accuracy_model');

% 7c. Partial dependence: average predicted EUI as one input changes
pdVars   = {'energy_star_rating', 'year_built', 'heating_degree_days', 'log_floor_area'};
pdLabels = {'Energy Star rating', 'Year built', 'Heating degree days', 'Floor area (ft^2)'};
pdSample = Xdev(randperm(height(Xdev), min(2000, height(Xdev))), :);
fig = figure('Name', 'Partial dependence', 'Position', [100 100 900 650]);
pdLayout = tiledlayout(2, 2, 'Padding', 'compact');
for p = 1:numel(pdVars)
    [gridVals, pdVals] = partialDependence1D(tuned, pdSample, pdVars{p}, 30);
    nexttile
    if strcmp(pdVars{p}, 'log_floor_area')
        semilogx(exp(gridVals), pdVals, 'LineWidth', 2);
    else
        plot(gridVals, pdVals, 'LineWidth', 2);
    end
    xlabel(pdLabels{p}); ylabel('Avg predicted EUI'); grid on;
end
title(pdLayout, 'How each factor changes predicted energy use (others held fixed)');
saveFig(fig, figDir, 'fig10_partial_dependence');

% 7d. Memorisation check. The same building re-appears across years, so
% part of Year 6 consists of buildings the model already saw in Years 1-5.
% If those are predicted far better, the model is partly "remembering"
% buildings: a random split would overstate accuracy, and the retrofit
% benchmark must never be trained on the building it judges.
seenBefore = ismember(Data.building_id(idxTest), Data.building_id(idxDev));
rmseSeen   = rmseOf(predTuned(seenBefore),  yTest(seenBefore));
rmseNew    = rmseOf(predTuned(~seenBefore), yTest(~seenBefore));
fprintf('\nYear 6 RMSE: buildings seen in Years 1-5 %.2f (n=%d) vs new buildings %.2f (n=%d)\n', ...
    rmseSeen, sum(seenBefore), rmseNew, sum(~seenBefore));

fig = figure('Name', 'Seen vs new buildings');
bar([rmseSeen, rmseNew], 0.5, 'FaceColor', [0.5 0.5 0.5]);
xticks(1:2);
xticklabels({sprintf('Seen in Years 1-5 (%d)', sum(seenBefore)), ...
             sprintf('New buildings (%d)', sum(~seenBefore))});
text(1:2, [rmseSeen, rmseNew], compose('%.1f', [rmseSeen, rmseNew]), ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', 'FontWeight', 'bold');
ylabel('RMSE on Year 6 (same model)'); grid on;
title('The model partly remembers buildings it has seen before');
saveFig(fig, figDir, 'fig11_seen_vs_new_buildings');

%% 8. Retrofit engine: which buildings use far more than they should?
% The benchmark model deliberately EXCLUDES Energy Star rating: the rating
% is itself a measure of efficiency, so including it would let the model
% "excuse" inefficient buildings. It is also trained WITHOUT any building
% that appears in Year 6, so it never judges a building it has memorised.
testBuildings = unique(Data.building_id(idxTest));
idxBenchFit = idxDev & ~ismember(Data.building_id, testBuildings);
[XbFit, XbTest] = buildXY(Data(idxBenchFit, :), Data(idxTest, :), predBench);
bench = fitrensemble(XbFit, log(Data.site_eui(idxBenchFit)), 'Method', 'LSBoost', ...
    'NumLearningCycles', best.k, 'LearnRate', best.lr, 'Learners', bestTemplate, ...
    'NumBins', cfg.numBins);
expected = exp(predict(bench, XbTest));
fprintf('\nBenchmark model (no Energy Star, unseen buildings): RMSE %.2f on Year 6\n', ...
    rmseOf(expected, yTest));

Retro = Data(idxTest, {'id', 'facility_type', 'State_Factor', 'floor_area', ...
    'year_built', 'energy_star_rating', 'site_eui'});
Retro.expected_eui = expected;
Retro.ratio        = Retro.site_eui ./ Retro.expected_eui;
Retro.excess_eui   = Retro.site_eui - Retro.expected_eui;
Retro.excess_MWh   = Retro.excess_eui .* Retro.floor_area * cfg.kBtuToMWh;
Retro.excess_tCO2  = Retro.excess_MWh * cfg.tCO2perMWh;
% Three outcomes: normal, retrofit candidate, or "verify meter data".
% Using 5x what comparable buildings use is more often a metering or
% data-entry error than a real building, so those are checked first,
% not counted as savings.
Retro.meterCheck   = Retro.ratio >= cfg.errorRatio;
Retro.flagged      = Retro.ratio >= cfg.flagRatio & ~Retro.meterCheck;

nFlag  = sum(Retro.flagged);
nCheck = sum(Retro.meterCheck);
starFlag  = median(Retro.energy_star_rating(Retro.flagged),  'omitnan');
starOther = median(Retro.energy_star_rating(~Retro.flagged & ~Retro.meterCheck), 'omitnan');
flagGWh = sum(Retro.excess_MWh(Retro.flagged)) / 1000;
flagKtCO2 = sum(Retro.excess_tCO2(Retro.flagged)) / 1000;
fprintf('Retrofit candidates: %d of %d buildings (%.1f%%) using %.1f-%.0fx their expected energy\n', ...
    nFlag, height(Retro), 100 * nFlag / height(Retro), cfg.flagRatio, cfg.errorRatio);
fprintf('Verify meter data: %d buildings using >= %.0fx their expected energy\n', nCheck, cfg.errorRatio);
fprintf('Independent check - median Energy Star: candidates %.0f vs not flagged %.0f\n', starFlag, starOther);

% 8a. Validation: the benchmark never saw Energy Star, yet the buildings it
% flags have far worse Energy Star ratings -> the flags are meaningful.
outcome = repmat("Not flagged", height(Retro), 1);
outcome(Retro.flagged) = "Retrofit candidate";
outcome(Retro.meterCheck) = "Verify meter data";
Retro.outcome = categorical(outcome, ["Not flagged", "Retrofit candidate", "Verify meter data"]);
fig = figure('Name', 'Energy Star check');
boxchart(Retro.outcome, Retro.energy_star_rating);
ylabel('Energy Star rating (1-100, higher = more efficient)'); grid on;
title(sprintf('Benchmark never saw Energy Star, yet candidates'' median = %.0f vs %.0f', starFlag, starOther));
saveFig(fig, figDir, 'fig12_energy_star_check');

% 8b. Pareto: a small share of buildings holds most of the wasted energy
% (likely meter errors excluded)
posExcess = sort(Retro.excess_MWh(Retro.excess_MWh > 0 & ~Retro.meterCheck), 'descend');
cumShare = cumsum(posExcess) / sum(posExcess);
bldShare = (1:numel(posExcess))' / height(Retro);
k5 = min(numel(posExcess), max(1, round(0.05 * height(Retro))));
top5Share = cumShare(k5);
fig = figure('Name', 'Pareto of excess energy');
plot(100 * bldShare, 100 * cumShare, 'LineWidth', 2.5); hold on;
plot(5, 100 * top5Share, 'ro', 'MarkerSize', 10, 'MarkerFaceColor', 'r');
text(6.5, 100 * top5Share, sprintf('Top 5%% of buildings = %.0f%% of excess energy', 100 * top5Share), ...
    'FontWeight', 'bold');
xlabel('% of buildings (ranked by excess energy)'); ylabel('% of total excess energy');
xlim([0 50]); ylim([0 100]); grid on;
title('Retrofit the right 5% and you capture most of the waste');
saveFig(fig, figDir, 'fig13_pareto_excess_energy');

% 8c. Where is the waste? Excess energy of flagged buildings by facility type
F = groupsummary(Retro(Retro.flagged, :), 'facility_type', 'sum', 'excess_MWh');
F = sortrows(F, 'sum_excess_MWh', 'descend');
nShow = min(10, height(F));
fig = figure('Name', 'Excess by facility type', 'Position', [100 100 850 550]);
barh(F.sum_excess_MWh(1:nShow) / 1000, 'FaceColor', [0.8 0.3 0.3]);
yticks(1:nShow); yticklabels(strrep(string(F.facility_type(1:nShow)), '_', ' '));
set(gca, 'YDir', 'reverse'); xlabel('Excess energy of flagged buildings (GWh/yr)'); grid on;
title('Which building types to target first');
saveFig(fig, figDir, 'fig14_excess_by_facility_type');

% 8d. Physical drivers (benchmark model importance)
impB = predictorImportance(bench);
[impBSorted, orderB] = sort(impB, 'descend');
nShow = min(12, numel(impB));
fig = figure('Name', 'Feature importance (benchmark)', 'Position', [100 100 800 550]);
barh(impBSorted(1:nShow), 'FaceColor', [0.3 0.6 0.4]);
yticks(1:nShow); yticklabels(strrep(bench.PredictorNames(orderB(1:nShow)), '_', ' '));
set(gca, 'YDir', 'reverse'); xlabel('Predictor importance'); grid on;
title('Benchmark model: physical and climate drivers of energy use');
saveFig(fig, figDir, 'fig15_importance_benchmark');

% 8e. The priority list
Priority = sortrows(Retro(Retro.flagged, :), 'excess_MWh', 'descend');
Priority.priority_rank = (1:height(Priority))';
Priority = movevars(Priority, 'priority_rank', 'Before', 1);
Priority = removevars(Priority, {'flagged', 'meterCheck', 'outcome'});
writetable(Priority, fullfile(resDir, 'retrofit_priority_list.csv'));

MeterChecks = sortrows(Retro(Retro.meterCheck, :), 'ratio', 'descend');
MeterChecks = removevars(MeterChecks, {'flagged', 'meterCheck', 'outcome'});
writetable(MeterChecks, fullfile(resDir, 'meter_data_checks.csv'));
disp('Top 10 retrofit priorities:');
disp(Priority(1:min(10, height(Priority)), {'priority_rank', 'facility_type', 'floor_area', ...
    'site_eui', 'expected_eui', 'ratio', 'excess_MWh', 'excess_tCO2'}));

%% 9. Retrain on all labelled years and predict Year 7
[Xall, X7] = buildXY(Data, Year7, predFull);
finalModel = fitrensemble(Xall, log(Data.site_eui), 'Method', 'LSBoost', ...
    'NumLearningCycles', best.k, 'LearnRate', best.lr, 'Learners', bestTemplate, ...
    'NumBins', cfg.numBins);
pred7 = exp(predict(finalModel, X7));
writetable(table(Year7.id, pred7, 'VariableNames', {'id', 'site_eui'}), ...
    fullfile(resDir, 'year7_predictions.csv'));
fprintf('\nYear 7 predictions written for %d buildings (median %.1f kBtu/ft^2)\n', ...
    numel(pred7), median(pred7));

finalModel = compact(finalModel);  bench = compact(bench);
save(fullfile(resDir, 'models.mat'), 'finalModel', 'bench', 'best', 'predFull', 'predBench', 'cfg');

%% 10. Summary (numbers for the presentation)
baseRMSE = results.RMSE(1);
fid = fopen(fullfile(resDir, 'summary.txt'), 'w');
for out = [1, fid]          % print to Command Window (1) and to summary.txt
    fprintf(out, '==== SUMMARY ====\n');
    fprintf(out, 'Final model: LSBoost, %d trees, MaxNumSplits=%d, LearnRate=%.2f, log target\n', ...
        best.k, best.splits, best.lr);
    fprintf(out, 'Year 6 hold-out: RMSE %.2f | MAE %.2f | R^2 %.3f | RMSE excl. State 6 %.2f\n', ...
        results.RMSE(end), results.MAE(end), results.R2(end), results.RMSE_excl_State6(end));
    fprintf(out, 'RMSE improvement over facility-type baseline: %.0f%%\n', ...
        100 * (baseRMSE - results.RMSE(end)) / baseRMSE);
    fprintf(out, 'Year 6 RMSE seen-before buildings %.2f (n=%d) vs new buildings %.2f (n=%d)\n', ...
        rmseSeen, sum(seenBefore), rmseNew, sum(~seenBefore));
    fprintf(out, 'Benchmark model (no Energy Star, unseen buildings) RMSE %.2f\n', rmseOf(expected, yTest));
    fprintf(out, 'Retrofit: %d of %d Year-6 buildings flagged (%.1f%%)\n', ...
        nFlag, height(Retro), 100 * nFlag / height(Retro));
    fprintf(out, 'Verify meter data: %d buildings (>= %.0fx expected)\n', nCheck, cfg.errorRatio);
    fprintf(out, 'Median Energy Star: flagged %.0f vs not flagged %.0f\n', starFlag, starOther);
    fprintf(out, 'Top 5%% of buildings hold %.0f%% of excess energy\n', 100 * top5Share);
    fprintf(out, 'Excess energy in flagged buildings: %.0f GWh/yr, approx. %.0f kt CO2/yr (at %.2f t/MWh)\n', ...
        flagGWh, flagKtCO2, cfg.tCO2perMWh);
    fprintf(out, 'Median excess per flagged building: %.0f MWh/yr\n', ...
        median(Retro.excess_MWh(Retro.flagged)));
end
fclose(fid);
disp(results);

%% Local functions
function T = prepareFeatures(T)
% Deterministic cleaning and feature engineering (no statistics learned).
    T.year_built(T.year_built < 1800) = NaN;            % 0 etc. are data-entry errors
    T.star_missing = double(isnan(T.energy_star_rating)); % missingness itself is informative
    T.log_floor_area = log(T.floor_area);                 % floor area spans 3 orders of magnitude
    T.winter_min_temp = mean([T.december_min_temp, T.january_min_temp, T.february_min_temp], 2);
    T.summer_max_temp = mean([T.june_max_temp, T.july_max_temp, T.august_max_temp], 2);
end

function imp = fitImputer(T)
% Learn fill-in values from TRAINING rows only (avoids test-set leakage).
    imp.globalStar = median(T.energy_star_rating, 'omitnan');
    imp.globalYear = median(T.year_built, 'omitnan');
    [g, imp.facility] = findgroups(T.facility_type);
    imp.star = splitapply(@(x) median(x, 'omitnan'), T.energy_star_rating, g);
    imp.year = splitapply(@(x) median(x, 'omitnan'), T.year_built, g);
end

function T = applyImputer(T, imp)
% Fill missing Energy Star / year built with the facility-type median.
    [found, loc] = ismember(T.facility_type, imp.facility);
    starFill = repmat(imp.globalStar, height(T), 1);
    yearFill = repmat(imp.globalYear, height(T), 1);
    starFill(found) = imp.star(loc(found));
    yearFill(found) = imp.year(loc(found));
    starFill(isnan(starFill)) = imp.globalStar;   % facility type with no ratings at all
    yearFill(isnan(yearFill)) = imp.globalYear;
    missStar = isnan(T.energy_star_rating);
    missYear = isnan(T.year_built);
    T.energy_star_rating(missStar) = starFill(missStar);
    T.year_built(missYear) = yearFill(missYear);
end

function [Xa, Xb] = buildXY(Ta, Tb, predictors)
% Fit the imputer on Ta (training rows), apply to both, keep predictors.
    imp = fitImputer(Ta);
    Xa = applyImputer(Ta, imp);  Xa = Xa(:, predictors);
    Xb = applyImputer(Tb, imp);  Xb = Xb(:, predictors);
end

function row = scoreModel(name, yTrue, yPred, nonS6)
% RMSE, MAE and R^2 in original units, plus RMSE excluding State 6.
    err = yPred - yTrue;
    rmse = sqrt(mean(err .^ 2));
    mae = mean(abs(err));
    r2 = 1 - sum(err .^ 2) / sum((yTrue - mean(yTrue)) .^ 2);
    rmseNonS6 = sqrt(mean(err(nonS6) .^ 2));
    fprintf('%-34s RMSE %6.2f | MAE %6.2f | R^2 %6.3f | RMSE excl. State 6 %6.2f\n', ...
        name, rmse, mae, r2, rmseNonS6);
    row = table(string(name), rmse, mae, r2, rmseNonS6, ...
        'VariableNames', {'Model', 'RMSE', 'MAE', 'R2', 'RMSE_excl_State6'});
end

function r = rmseOf(yPred, yTrue)
    r = sqrt(mean((yPred - yTrue) .^ 2));
end

function [gridVals, pdVals] = partialDependence1D(mdl, X, varName, nGrid)
% Average back-transformed prediction while sweeping one variable.
    x = X.(varName);
    gridVals = unique(quantile(x(~isnan(x)), linspace(0.02, 0.98, nGrid)));
    pdVals = zeros(size(gridVals));
    for i = 1:numel(gridVals)
        Xi = X;
        Xi.(varName)(:) = gridVals(i);
        pdVals(i) = mean(exp(predict(mdl, Xi)));
    end
end

function saveFig(fig, figDir, name)
% Export every figure in the light theme so it reads well on slides,
% even when MATLAB itself is in dark mode (older releases have no themes).
    try
        theme(fig, 'light');
    catch
        try
            fig.Theme = 'light';
        catch
        end
    end
    exportgraphics(fig, fullfile(figDir, [name '.png']), 'Resolution', 200);
end
