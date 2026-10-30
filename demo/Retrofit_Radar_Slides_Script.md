# Retrofit Radar: 5-minute presentation script

Speaker notes for [Retrofit_Radar_Slides.pdf](Retrofit_Radar_Slides.pdf). About 626 words, roughly 4.5 minutes.

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

## Slide 8: Retrofit engine: flag and rank

The retrofit engine uses a benchmark model without the Energy Star rating, because that rating would excuse inefficient buildings, and it never judges a building it trained on. Between 1.5 and 5 times its expected energy, a building is a retrofit candidate; above 5 times, it is probably a meter error, so we check it instead.

## Slide 9: Checking the flags: two results

Two checks. The benchmark never saw Energy Star ratings, yet flagged buildings have a median rating of 20, against 73 for the rest. And the waste is concentrated: the top five percent of buildings hold 57 percent of the excess, so a small budget aimed at the top of our list captures most of it.

## Slide 10: The MATLAB app: test the models yourself

Our MATLAB app re-scores all eight models for any building type, with or without State 6. It showed that outside State 6, the raw-target model beats our final one, and we report that openly. The second tab lets a facilities manager filter the list and compare any building’s actual and expected energy.

## Slide 11: Impact: a ranked list of buildings to audit

The result is a ranked list of 2,973 buildings to audit. If every candidate matched its benchmark, that is about 8,200 gigawatt-hours and three million tonnes of CO₂ a year. That is an upper bound, but it shows the scale. We also predict all Year 7 buildings.

## Slide 12: Limits, assumptions and next steps

Some honest limits. A flag says which building to audit, not what to fix. The data has no occupancy or equipment information, which caps accuracy. And the CO₂ figure uses one assumed factor. Next, we’d choose models per building type, add retrofit costs, and re-run every year. Thank you.
