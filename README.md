# Predicting Building Energy Consumption

**Learn to Hack: MATLAB Edition 2026** · NTU · MathWorks × TechSource × Anata

A machine learning pipeline in MATLAB that predicts a building's energy consumption from weather and building characteristics. The goal is to help organisations find high-use buildings to target for energy-efficiency retrofits.

> **Demo (< 5 min):** _TODO: link to video / slides_

---

## Problem

Buildings are major contributors to global energy use and carbon emissions. An accurate consumption model lets an organisation:

1. Estimate expected consumption for each building under given weather conditions.
2. Flag buildings that use much more energy than the model expects.
3. Prioritise those buildings for retrofitting.

## Approach

| Stage | What we did | Why |
|---|---|---|
| Explore | _TODO_ | _TODO_ |
| Clean | _TODO: missing values, outliers, categorical conversion_ | _TODO_ |
| Features | _TODO: e.g. hour, month, weekend flag_ | _TODO_ |
| Split | _TODO: time-based or random hold-out_ | _TODO_ |
| Models | Linear regression → decision tree → boosted / bagged trees → neural net | Simplest first, to show what extra complexity buys |
| Tuning | _TODO_ | _TODO_ |

## Results

Test-set performance (lower RMSE / MAE is better, higher R² is better):

| Model | RMSE | MAE | R² |
|---|---|---|---|
| _TODO_ | | | |

Full table: [`results/model_comparison.csv`](results/model_comparison.csv)

**Key insight:** _TODO: which factors drive consumption, and what that means for retrofitting_

## Repository structure

```
.
├── main.m                  # Full pipeline: load → explore → clean → split → train → evaluate
├── data/                   # Dataset (from the organisers)
├── starter/                # Original starter code (Building Regression Models.mlx)
├── results/
│   ├── model_comparison.csv
│   ├── best_model.mat
│   └── figures/            # Plots exported by main.m
└── demo/                   # Demo video / slides
```

## How to run

1. Open MATLAB in the repo root folder.
2. Put the dataset in `data/`.
3. In `main.m` Section 1, set `cfg.dataFile`, `cfg.target` and `cfg.timeVar`.
4. Run `main.m`.

**Requirements:** MATLAB R2021a or later, Statistics and Machine Learning Toolbox.

## Team

| Name | Role |
|---|---|
| Chua Guan Yu | Member |
| Chay Ze Huan | Member |
| Li Shou Xiang | Member |
| Liu Xiang Zhe | Member |


