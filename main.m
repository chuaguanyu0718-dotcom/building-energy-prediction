%% Retrofit Radar: entry point
% Learn To Hack: MATLAB Edition 2026 (NTU)
%
% Runs the full pipeline in BuildingEnergyRetrofit.m:
%   load -> explore -> clean -> feature engineering -> year-based split
%   -> 7 models (baseline to tuned boosting) -> evaluation
%   -> retrofit engine (fair benchmark + priority list) -> Year 7 predictions
%
% Requirements: MATLAB R2023a+ and the Statistics and Machine Learning Toolbox.
% Data: put train.csv and test.csv (WiDS Datathon 2022) in ./data
% Outputs: ./figures (PNG plots) and ./results (CSV tables, summary.txt)
%
% Tip: right-click BuildingEnergyRetrofit.m > Open as Live Script to read
% the code, explanations and figures together.

BuildingEnergyRetrofit
