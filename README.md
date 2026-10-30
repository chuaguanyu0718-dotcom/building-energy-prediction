# Retrofit Radar: Predicting Building Energy Use to Target Retrofits

**Learn To Hack: MATLAB Edition 2026** · NTU · MathWorks × TechSource × Anata

> **Demo (< 5 min):** [video link] · [slides link]

Buildings account for roughly a third of global energy use and energy-related CO₂. Retrofits (insulation, HVAC upgrades, heat pumps, glazing, LEDs) are expensive, so the real question for any organisation is **which buildings to fix first**.

Raw energy use cannot answer that: a hospital will always use more than a warehouse, and a building in a cold state will always heat more. What matters is how much a building uses **compared with what a building like it, in that climate, should use**. Retrofit Radar uses machine learning to provide that "should use" figure, then ranks buildings by how far above it they are.

## What it does

1. **Predicts** each building's Site Energy Use Intensity (site EUI, kBtu/ft²/yr) from building characteristics and weather.
2. **Benchmarks** every building against a fair model that knows only its type, size, age, location and weather, deliberately *not* its Energy Star rating.
3. **Flags and ranks** buildings that use ≥ 1.5× their expected energy by excess energy (MWh) and CO₂, and separates out likely meter or data errors (≥ 5× expected).

## Results

All scores are on **Year 6**, a year never used for any modelling decision.

| Model | RMSE | MAE | R² | RMSE excl. State 6 |
|---|---|---|---|---|
| 0. Facility-type median | 50.7 | 27.2 | 0.21 | 53.6 |
| 1. Linear regression | 44.6 | 23.1 | 0.39 | 49.1 |
| 2. Regression tree (leaf=50) | 42.7 | 21.5 | 0.44 | 46.8 |
| 3. Bagged trees (100) | 42.6 | 22.7 | 0.44 | 44.8 |
| 4. Boosted trees (raw target) | 44.4 | 22.3 | 0.39 | 40.2 |
| 5. Boosted trees (log target) | 40.2 | 18.8 | 0.50 | 42.4 |
| 6. Neural network (log target) | 53.9 | 29.6 | 0.11 | 61.3 |
| **7. Tuned boosted trees (log)** | 40.3 | 18.7 | 0.50 | 43.2 |

The biggest single gain comes from modelling log(EUI) (model 4 → 5). Tuning by time-series cross-validation lands on the same accuracy as the untuned log model (RMSE 40.3 vs 40.2, within noise) with the lowest MAE, which confirms those settings were already near-optimal. The neural network trails the tree models, as is typical on tabular data with categorical inputs and heavy outliers.

**Final model:** LSBoost on log(EUI), 298 trees, up to 60 splits each, learning rate 0.05; RMSE 40.3, MAE 18.7, R² 0.50, **20% lower RMSE than the facility-type baseline**.

**Retrofit engine (Year 6):**
- **2,973 retrofit candidates** (13% of buildings) and 107 buildings to verify meter data.
- **Independent check:** the benchmark never saw Energy Star ratings, yet candidates have a median rating of **20 vs 73** for unflagged buildings.
- The **top 5% of buildings hold 57% of all excess energy**.
- Excess energy of candidates: about **8,215 GWh/yr**, roughly **3,122 kt CO₂/yr** at an assumed 0.38 t/MWh. This is an upper bound, reached only if every candidate performed like its benchmark.

## Key data decisions

| Decision | Why |
|---|---|
| Split by **year**: tune only on Years 1–5, test on Year 6 | The real test set (Year 7) is a future year. |
| **Time-series cross-validation** for boosting (train 1–3 → check 4, train 1–4 → check 5) | Tuning on a single year over-fitted that year's quirks (Year 5 introduces a state never seen before). |
| Report RMSE **excluding State 6** | State 6 is 67% of training rows but 0% of the test year (distribution shift). |
| Pseudo **building ID** (state, type, floor area, year built, elevation) | The same building reappears across years. The model predicts seen buildings with RMSE 30 vs 46 for new ones, so the retrofit benchmark is trained only on buildings it does not judge. |
| Drop wind and fog columns | 54–60% missing in train, 88–94% in test. |
| Fill Energy Star and year built with the **facility-type median, fitted on training rows only**, plus a `star_missing` flag | Avoids test-set leakage. Whether a building has a rating at all is informative. |
| `year_built < 1800` → missing | Values like 0 are data-entry errors. |
| 36 monthly temperatures → winter-min and summer-max summaries | Monthly columns are highly correlated with each other and with degree days. |
| Model **log(site EUI)** | The target is heavily right-skewed, and the log transform stops a few extreme buildings dominating. |
| Benchmark **excludes Energy Star** | The rating already measures efficiency. Including it would excuse inefficient buildings. |

## Model iteration

Facility-type median → linear regression → regression tree (leaf size tuned) → bagged trees → gradient boosting (raw target) → gradient boosting (log target) → neural network (`fitrnet`) → **tuned gradient boosting** (tree size × learning rate grid; the number of trees is chosen from MATLAB's cumulative ensemble loss, averaged over two time folds).

## How to run

1. MATLAB R2023a or later with the **Statistics and Machine Learning Toolbox**.
2. `train.csv` and `test.csv` (WiDS Datathon 2022) are in `data/`.
3. Run `main.m` (or `BuildingEnergyRetrofit.m`). The full run takes about 12 minutes; set `cfg.fastMode = true` for a 3-minute check.

| Output | Contents |
|---|---|
| `figures/` | 15 plots used in the presentation |
| `results/model_comparison.csv` | Year 6 scores for every model |
| `results/retrofit_priority_list.csv` | Ranked retrofit candidates with expected vs actual EUI, excess MWh and CO₂ |
| `results/meter_data_checks.csv` | Buildings whose usage is implausibly high (≥ 5× expected) |
| `results/year7_predictions.csv` | Predictions for the unlabelled Year 7 buildings |
| `results/summary.txt` | Headline numbers |

## Repository structure

```
.
├── main.m                      # entry point (runs the pipeline)
├── BuildingEnergyRetrofit.m    # full pipeline, sectioned (open as Live Script)
├── data/                       # train.csv, test.csv
├── figures/                    # exported plots
├── results/                    # tables, predictions, saved models
└── demo/                       # presentation
```

## Limitations

- R² is about 0.50. Building energy data is noisy, and some buildings report implausible EUIs. Retrofit Radar is a **screening tool**: a flag means "audit this building", not a diagnosis of what to fix.
- The CO₂ figure uses an assumed emission factor of 0.38 t/MWh (approximate US grid average). Real factors depend on fuel mix.
- Excess energy is measured against peers. The savings that are actually achievable depend on retrofit type and cost.

## Data

WiDS Datathon 2022 (Kaggle / Climate Change AI / MIT Climate Lab): about 76k building-year records of building characteristics and weather, with site EUI as the target.

## Team

| Name | Role |
|---|---|
| [name] | [role] |
| [name] | [role] |
