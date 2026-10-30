# Retrofit Radar: 5-minute presentation script

Speaker notes for [Retrofit_Radar_Slides.pdf](Retrofit_Radar_Slides.pdf). 

## Slide 1: Retrofit Radar

We’re Retrofit Radar. We built a MATLAB pipeline that predicts how much energy a building should use, from its characteristics and the weather. Then we use that prediction to answer one practical question: if you can only retrofit a few buildings, which ones should you fix first?

## Slide 2: Which buildings should be fixed first?

Buildings use about a third of the world’s energy. Retrofits cut that, but they cost money, so organisations have to choose. Raw energy use is misleading: a hospital always uses more than a warehouse, and a building in a cold state always heats more. What we actually need is how much a building should use.

## Slide 3: Our approach: actual vs expected energy

Our pipeline has three steps. First, a model predicts site EUI: energy per square foot per year, so big buildings aren’t flagged just for being big. Second, a benchmark model gives each building’s expected energy. Third, buildings using at least one and a half times their expected energy are flagged and ranked by wasted energy and CO₂.

## Slide 4: The data: WiDS Datathon 2022

We used the WiDS Datathon 2022 data: about 76,000 building-years to train on, and 9,700 Year 7 buildings to predict. We dropped mostly empty columns, removed duplicates and impossible build years, and filled missing Energy Star ratings using training rows only, so nothing leaks. We model the log of energy use because a few buildings are extreme.

## Slide 5: How we tested: two traps, one rule

Two traps shaped our testing. State 6 is two thirds of the training data but absent from the test year, so we also score without it. And buildings repeat across years: the model predicts seen buildings far better than new ones. So we tuned on Years 1 to 5, scored once on Year 6, then retrained on everything for Year 7.

## Slide 6: Eight models, all scored on Year 6

We went from simple to complex. Linear regression beats the baseline, trees capture interactions, and boosting on the log of energy use gave the biggest gain. The neural network trailed the trees, as is common on table data. Tuning by time-series cross-validation confirmed our settings.

## Slide 7: Final model: 20% better than baseline

Our final model is tuned gradient boosting: an RMSE of 40.3 and an R-squared of 0.50 on Year 6, twenty percent better than the baseline. Typical buildings sit on the diagonal; the big misses are extreme users, which is where the retrofit engine looks next.

## Slide 8: Retrofit engine: how a building is scored

Here is how a building is scored. The benchmark predicts what it should use, without the Energy Star rating and without having trained on it. We divide actual by expected. Our top building, a large health-care facility, uses 342 against an expected 192: 1.78 times. Over three million square feet, that is about 133,000 megawatt-hours and 50,000 tonnes of CO₂ a year.

## Slide 9: Retrofit engine: three outcomes

That ratio sorts every building into three groups. Below 1.5 times is normal. From 1.5 to 5 times is a retrofit candidate, ranked by excess energy: 2,973 buildings. Above 5 times is too extreme to be real, so those 107 go to a meter check.

## Slide 10: Check 1: do the flags match Energy Star?

How do we know the flags are right? Energy Star is an independent efficiency score the benchmark never saw. If our flags are real, flagged buildings should score low, and they do: a median of 20, against 73 for unflagged buildings.

## Slide 11: Check 2: where is the waste?

Second, where is the waste? Ranking buildings by excess energy, the top five percent hold 57 percent of the total. So a small retrofit budget aimed at the top of our list captures most of the opportunity.

## Slide 12: MATLAB app, tab 1: model evaluation

Our MATLAB app has two tabs. The first re-scores all eight models for any building type, with or without State 6, and highlights the best. It showed us something new: outside State 6, the raw-target model beats our final one, because State 6 is mostly multifamily housing, where the log model is strongest. We report that openly instead of switching models after seeing the test year.

## Slide 13: MATLAB app, tab 2: retrofit priorities

The second tab is for a facilities manager. Choose the candidate list or the meter checks, filter by building type and ratio, and the summary updates. Click any building to see its actual energy against the benchmark, and the curve shows how concentrated the waste is in that list.

## Slide 14: Impact: a ranked list of buildings to audit

The result is a ranked list of 2,973 buildings to audit. If every candidate matched its benchmark, that is about 8,200 gigawatt-hours and three million tonnes of CO₂ a year. That is an upper bound, but it shows the scale. We also predict all Year 7 buildings.

## Slide 15: Limits, assumptions and next steps

Some honest limits. A flag says which building to audit, not what to fix. The data has no occupancy or equipment information, which caps accuracy. And the CO₂ figure uses one assumed factor. Next, we’d choose models per building type, add retrofit costs, and re-run every year. Thank you.
