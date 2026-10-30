function varargout = RetrofitRadarApp
%RETROFITRADARAPP Explore the model evaluation and the retrofit priority list.
%   Run main.m once first (it writes the files in ./results), then type
%       RetrofitRadarApp
%
%   Model evaluation     Re-scores all 8 models on Year 6 for any building
%                        type, with or without State 6, highlights the best
%                        fit, and lists the best model per building type.
%                        Click a model to see its predicted vs actual plot.
%   Retrofit priorities  The ranked retrofit candidates (or the buildings to
%                        verify meter data for). Click a building to compare
%                        its actual energy use with the benchmark.

    root = fileparts(mfilename('fullpath'));
    resDir = fullfile(root, 'results');
    figDir = fullfile(root, 'figures');
    required = {'year6_model_predictions.csv', 'model_comparison.csv', ...
                'retrofit_priority_list.csv', 'meter_data_checks.csv'};
    for f = required
        assert(isfile(fullfile(resDir, f{1})), 'RetrofitRadarApp:missingResults', ...
            '%s not found in ./results. Run main.m first.', f{1});
    end

    %% Data
    Y6 = readtable(fullfile(resDir, 'year6_model_predictions.csv'), 'TextType', 'string');
    MC = readtable(fullfile(resDir, 'model_comparison.csv'), 'TextType', 'string');
    PL = readtable(fullfile(resDir, 'retrofit_priority_list.csv'), 'TextType', 'string');
    MD = readtable(fullfile(resDir, 'meter_data_checks.csv'), 'TextType', 'string');

    predCols = Y6.Properties.VariableNames(~cellfun(@isempty, ...
        regexp(Y6.Properties.VariableNames, '^m\d+_', 'once')));
    shortNames = regexprep(MC.Model, '^\d+\.\s*', '');
    y = Y6.site_eui;
    Pm = Y6{:, predCols};
    isS6 = Y6.State_Factor == "State_6";

    flagRatio = 1.5;
    errorRatio = 5;
    if isfile(fullfile(resDir, 'models.mat'))
        cfgFile = load(fullfile(resDir, 'models.mat'), 'cfg');
        if isfield(cfgFile, 'cfg')
            flagRatio = cfgFile.cfg.flagRatio;
            errorRatio = cfgFile.cfg.errorRatio;
        end
    end

    % Segments: every building type with at least 200 Year 6 buildings
    [types, ~, gi] = unique(Y6.facility_type);
    counts = accumarray(gi, 1);
    segTypes = types(counts >= 200);
    segCounts = counts(counts >= 200);
    [segCounts, order] = sort(segCounts, 'descend');
    segTypes = segTypes(order);
    segItems = ["All building types (n = " + fmt(height(Y6)) + ")"; ...
                strrep(segTypes, "_", " ") + " (n = " + ...
                string(arrayfun(@fmt, segCounts, 'UniformOutput', false)) + ")"];
    segData = ["All"; segTypes];

    retroTypes = unique([PL.facility_type; MD.facility_type]);
    typeItems = ["All building types"; strrep(retroTypes, "_", " ")];
    typeData = ["All"; retroTypes];

    % Palette: neutral greys, one accent, one warm colour for "actual"
    ink = [0.13 0.15 0.18];
    muted = [0.45 0.48 0.52];
    grey = [0.74 0.76 0.79];
    accent = [0.12 0.36 0.60];
    warm = [0.85 0.45 0.15];
    tint = [0.87 0.92 0.98];

    selModel = numel(predCols);   % start on the final model
    shown = PL;                   % rows currently in the retrofit table

    %% Window
    fig = uifigure('Name', 'Retrofit Radar', 'Position', [60 50 1360 820]);
    try
        theme(fig, 'light');
    catch
        % releases before R2025a have no themes and are light already
    end
    main = uigridlayout(fig, [2 1]);
    main.RowHeight = {40, '1x'};
    main.Padding = [14 8 14 10];
    main.RowSpacing = 4;

    hdr = uigridlayout(main, [1 3]);
    hdr.ColumnWidth = {'fit', '1x', 100};
    hdr.Padding = [2 0 0 0];
    uilabel(hdr, 'Text', 'Retrofit Radar', 'FontSize', 18, 'FontWeight', 'bold', 'FontColor', ink);
    uilabel(hdr, 'FontColor', muted, 'Text', sprintf( ...
        '   WiDS Datathon 2022   |   all scores on Year 6 (%s buildings), never used for tuning', ...
        fmt(height(Y6))));
    uibutton(hdr, 'push', 'Text', 'Export PNG', 'ButtonPushedFcn', @(~, ~) exportTab());

    tabs = uitabgroup(main);
    tabEval = uitab(tabs, 'Title', 'Model evaluation');
    tabRetro = uitab(tabs, 'Title', 'Retrofit priorities');

    %% Tab 1: model evaluation
    g1 = uigridlayout(tabEval, [1 2]);
    g1.ColumnWidth = {580, '1x'};
    g1.Padding = [12 12 12 12];
    g1.ColumnSpacing = 18;

    evalLeft = uigridlayout(g1, [5 1]);
    evalLeft.RowHeight = {28, 250, 24, 22, '1x'};
    evalLeft.Padding = [0 0 0 0];
    evalLeft.RowSpacing = 8;

    ctl = uigridlayout(evalLeft, [1 3]);
    ctl.ColumnWidth = {'fit', '1x', 'fit'};
    ctl.Padding = [0 0 0 0];
    uilabel(ctl, 'Text', 'Segment', 'FontWeight', 'bold');
    ddSeg = uidropdown(ctl, 'Items', segItems', 'ItemsData', segData', 'Value', "All", ...
        'ValueChangedFcn', @(~, ~) refreshEval());
    cbS6 = uicheckbox(ctl, 'Text', 'Exclude State 6', 'Value', false, ...
        'ValueChangedFcn', @(~, ~) refreshEval());

    tblModels = uitable(evalLeft, 'RowName', {}, 'ColumnWidth', {'1x', 70, 70, 70}, ...
        'CellSelectionCallback', @(~, evt) pickModel(evt));
    lblBest = uilabel(evalLeft, 'Text', '', 'FontWeight', 'bold', 'FontColor', accent);
    uilabel(evalLeft, 'Text', 'Best model per building type (200+ buildings)', ...
        'FontWeight', 'bold', 'FontColor', ink);
    tblSeg = uitable(evalLeft, 'RowName', {}, 'ColumnWidth', {'1x', 56, 170, 72, 84});

    evalRight = uigridlayout(g1, [2 1]);
    evalRight.RowHeight = {'1x', '1.35x'};
    evalRight.Padding = [0 0 0 0];
    axBar = uiaxes(evalRight);
    axScat = uiaxes(evalRight);

    %% Tab 2: retrofit priorities
    g2 = uigridlayout(tabRetro, [1 2]);
    g2.ColumnWidth = {'1.9x', '1x'};
    g2.Padding = [12 12 12 12];
    g2.ColumnSpacing = 18;

    retroLeft = uigridlayout(g2, [3 1]);
    retroLeft.RowHeight = {44, 22, '1x'};
    retroLeft.Padding = [0 0 0 0];
    retroLeft.RowSpacing = 8;

    c2 = uigridlayout(retroLeft, [1 6]);
    c2.ColumnWidth = {'fit', 170, 'fit', 240, 'fit', '1x'};
    c2.Padding = [0 0 0 0];
    uilabel(c2, 'Text', 'List', 'FontWeight', 'bold');
    ddList = uidropdown(c2, 'Items', {'Retrofit candidates', 'Verify meter data'}, ...
        'ValueChangedFcn', @(~, ~) refreshRetro());
    uilabel(c2, 'Text', '  Building type', 'FontWeight', 'bold');
    ddType = uidropdown(c2, 'Items', typeItems', 'ItemsData', typeData', 'Value', "All", ...
        'ValueChangedFcn', @(~, ~) refreshRetro());
    uilabel(c2, 'Text', '  Min. actual / expected', 'FontWeight', 'bold');
    sl = uislider(c2, 'Limits', [flagRatio errorRatio], 'Value', flagRatio, ...
        'MajorTicks', unique([flagRatio 2 3 4 errorRatio]), 'MinorTicks', [], ...
        'ValueChangedFcn', @(~, ~) refreshRetro());

    lblSum = uilabel(retroLeft, 'Text', '', 'FontColor', ink);
    tblRetro = uitable(retroLeft, 'RowName', {}, ...
        'ColumnWidth', {44, '1x', 76, 120, 88, 104, 124, 124}, ...
        'CellSelectionCallback', @(~, evt) pickBuilding(evt));
    addStyle(tblRetro, uistyle('HorizontalAlignment', 'right'), 'column', [1 4 5 6 7 8]);

    retroRight = uigridlayout(g2, [3 1]);
    retroRight.RowHeight = {'1x', 236, '0.9x'};
    retroRight.Padding = [0 0 0 0];
    axCmp = uiaxes(retroRight);
    tblFacts = uitable(retroRight, 'RowName', {}, 'ColumnWidth', {140, '1x'});
    axPar = uiaxes(retroRight);

    refreshEval();
    refreshRetro();
    if nargout > 0
        varargout{1} = fig;
    end

    %% Tab 1 callbacks (nested: they share the variables above)
    function refreshEval()
        mask = segmentMask();
        if ~any(mask)
            lblBest.Text = 'No buildings in this segment.';
            return
        end
        [rmse, mae, rsq] = scoreAll(y(mask), Pm(mask, :));
        [~, best] = min(rmse);
        tblModels.Data = table(cellstr(shortNames), strs('%.1f', rmse'), strs('%.1f', mae'), ...
            strs('%.3f', rsq'), 'VariableNames', {'Model', 'RMSE', 'MAE', 'R2'});
        removeStyle(tblModels);
        addStyle(tblModels, uistyle('HorizontalAlignment', 'right'), 'column', 2:4);
        addStyle(tblModels, uistyle('BackgroundColor', tint, 'FontWeight', 'bold'), 'row', best);
        lblBest.Text = sprintf('Best fit here: %s  (RMSE %.1f, R2 %.2f, %s buildings)', ...
            shortNames(best), rmse(best), rsq(best), fmt(nnz(mask)));
        drawBars(rmse, best);
        drawScatter(mask);
        refreshSegmentTable();
    end

    function mask = segmentMask()
        mask = true(height(Y6), 1);
        if string(ddSeg.Value) ~= "All"
            mask = mask & Y6.facility_type == string(ddSeg.Value);
        end
        if cbS6.Value
            mask = mask & ~isS6;
        end
    end

    function pickModel(evt)
        if ~isempty(evt.Indices)
            selModel = evt.Indices(1, 1);
            drawScatter(segmentMask());
        end
    end

    function drawBars(rmse, best)
        cla(axBar);
        nModels = numel(rmse);
        hb = barh(axBar, 1:nModels, rmse, 0.62, 'FaceColor', 'flat', 'EdgeColor', 'none');
        hb.CData = repmat(grey, nModels, 1);
        hb.CData(best, :) = accent;
        text(axBar, rmse + max(rmse) * 0.01, 1:nModels, compose(' %.1f', rmse), ...
            'VerticalAlignment', 'middle', 'FontSize', 11, 'Color', ink);
        axBar.YTick = 1:nModels;
        axBar.YTickLabel = cellstr(shortNames);
        axBar.YDir = 'reverse';
        axBar.XLim = [0 max(rmse) * 1.12];
        axBar.XGrid = 'on';
        axBar.Box = 'off';
        xlabel(axBar, 'RMSE on Year 6 (kBtu/ft^2/yr), lower is better');
        title(axBar, 'Every model, scored on the selected segment', 'FontWeight', 'normal');
    end

    function drawScatter(mask)
        cla(axScat);
        yAct = y(mask);
        yHat = max(Pm(mask, selModel), 1);     % log axes: clip the rare non-positive prediction
        alpha = min(0.7, max(0.1, 2000 / numel(yAct)));   % small segments: more opaque
        scatter(axScat, yAct, yHat, 8, accent, 'filled', 'MarkerFaceAlpha', alpha, ...
            'MarkerEdgeColor', 'none');
        hold(axScat, 'on');
        plot(axScat, [1 1000], [1 1000], '--', 'Color', ink, 'LineWidth', 1);
        hold(axScat, 'off');
        axScat.XScale = 'log';
        axScat.YScale = 'log';
        axScat.XLim = [1 1000];
        axScat.YLim = [1 1000];
        axScat.Box = 'off';
        grid(axScat, 'on');
        xlabel(axScat, 'Actual site EUI (kBtu/ft^2/yr)');
        ylabel(axScat, 'Predicted site EUI');
        [r, ~, q] = scoreAll(yAct, Pm(mask, selModel));
        title(axScat, sprintf('%s: predicted vs actual   (RMSE %.1f, R^2 %.2f)', ...
            shortNames(selModel), r, q), 'FontWeight', 'normal');
    end

    function refreshSegmentTable()
        nSeg = numel(segTypes);
        cells = cell(nSeg, 5);
        use = true(nSeg, 1);
        for s = 1:nSeg
            m = Y6.facility_type == segTypes(s);
            if cbS6.Value
                m = m & ~isS6;
            end
            if nnz(m) < 50
                use(s) = false;
                continue
            end
            segRmse = scoreAll(y(m), Pm(m, :));
            [bestRmse, bestIdx] = min(segRmse);
            cells(s, :) = {char(strrep(segTypes(s), "_", " ")), fmt(nnz(m)), ...
                char(shortNames(bestIdx)), sprintf('%.1f', bestRmse), sprintf('%.1f', segRmse(end))};
        end
        tblSeg.Data = cell2table(cells(use, :), 'VariableNames', ...
            {'Building type', 'n', 'Best model', 'Best RMSE', 'Final model'});
        removeStyle(tblSeg);
        addStyle(tblSeg, uistyle('HorizontalAlignment', 'right'), 'column', [2 4 5]);
    end

    %% Tab 2 callbacks
    function refreshRetro()
        isMeter = strcmp(ddList.Value, 'Verify meter data');
        if isMeter
            T = MD;
            sl.Enable = 'off';
        else
            T = PL;
            sl.Enable = 'on';
        end
        if string(ddType.Value) ~= "All"
            T = T(T.facility_type == string(ddType.Value), :);
        end
        if ~isMeter
            T = T(T.ratio >= sl.Value, :);
        end
        shown = T;
        tblRetro.Data = retroTable(T);
        if isempty(T)
            lblSum.Text = 'No buildings match these filters.';
        elseif isMeter
            lblSum.Text = sprintf(['%s buildings use %.0fx or more of their expected energy, ' ...
                'more likely a meter or data error than a real building. Verify before acting.'], ...
                fmt(height(T)), errorRatio);
        else
            lblSum.Text = sprintf(['%s buildings   |   %s GWh/yr excess   |   %s kt CO2/yr ' ...
                '(assumed 0.38 t/MWh)   |   median Energy Star %s'], fmt(height(T)), ...
                fmt(sum(T.excess_MWh) / 1000), fmt(sum(T.excess_tCO2) / 1000), ...
                starText(median(T.energy_star_rating, 'omitnan')));
        end
        drawPareto(T, isMeter);
        showBuilding(1);
    end

    function pickBuilding(evt)
        if ~isempty(evt.Indices)
            showBuilding(evt.Indices(1, 1));
        end
    end

    function showBuilding(row)
        cla(axCmp);
        if isempty(shown) || row > height(shown)
            tblFacts.Data = cell2table(cell(0, 2), 'VariableNames', {'Field', 'Value'});
            title(axCmp, '');
            return
        end
        bld = shown(row, :);
        vals = [bld.expected_eui, bld.site_eui];
        hb = bar(axCmp, vals, 0.5, 'FaceColor', 'flat', 'EdgeColor', 'none');
        hb.CData = [grey; warm];
        text(axCmp, 1:2, vals, compose('%.0f', vals), 'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'bottom', 'Color', ink, 'FontSize', 12);
        axCmp.XTick = 1:2;
        axCmp.XTickLabel = {'Expected (benchmark)', 'Actual'};
        axCmp.YLim = [0 max(vals) * 1.18];
        axCmp.YGrid = 'on';
        axCmp.Box = 'off';
        ylabel(axCmp, 'Site EUI (kBtu/ft^2/yr)');
        title(axCmp, sprintf('Uses %.1fx what comparable buildings use', bld.ratio), ...
            'FontWeight', 'normal');
        facts = {'Building type', char(strrep(bld.facility_type, "_", " ")); ...
                 'State', char(strrep(bld.State_Factor, "_", " ")); ...
                 'Floor area', [fmt(bld.floor_area) ' ft2']; ...
                 'Year built', yearText(bld.year_built); ...
                 'Energy Star rating', starText(bld.energy_star_rating); ...
                 'Excess energy', [fmt(bld.excess_MWh) ' MWh/yr']; ...
                 'Excess CO2 (assumed)', [fmt(bld.excess_tCO2) ' t/yr']; ...
                 'Building id', sprintf('%d', bld.id)};
        tblFacts.Data = cell2table(facts, 'VariableNames', {'Field', 'Value'});
    end

    function drawPareto(T, isMeter)
        cla(axPar);
        excess = sort(T.excess_MWh(T.excess_MWh > 0), 'descend');
        if isMeter || isempty(excess)
            title(axPar, 'Concentration curve shown for retrofit candidates', 'FontWeight', 'normal');
            return
        end
        xs = 100 * (1:numel(excess))' / numel(excess);
        ys = 100 * cumsum(excess) / sum(excess);
        k10 = max(1, round(0.1 * numel(excess)));
        plot(axPar, [0; xs], [0; ys], 'Color', accent, 'LineWidth', 2);
        hold(axPar, 'on');
        plot(axPar, [xs(k10) xs(k10) 0], [0 ys(k10) ys(k10)], ':', 'Color', muted, 'LineWidth', 1.2);
        hold(axPar, 'off');
        axPar.XLim = [0 100];
        axPar.YLim = [0 100];
        axPar.Box = 'off';
        grid(axPar, 'on');
        xlabel(axPar, '% of buildings in this list');
        ylabel(axPar, '% of excess energy');
        title(axPar, sprintf('Top 10%% of this list holds %.0f%% of its excess energy', ys(k10)), ...
            'FontWeight', 'normal');
    end

    function exportTab()
        if ~isfolder(figDir)
            mkdir(figDir);
        end
        name = lower(regexprep(tabs.SelectedTab.Title, '\W+', '_'));
        file = fullfile(figDir, ['app_' name '.png']);
        exportapp(fig, file);
        uialert(fig, sprintf('Saved %s', file), 'Exported', 'Icon', 'success');
    end
end

%% Local helper functions
function [rmse, mae, rsq] = scoreAll(yTrue, P)
% RMSE, MAE and R^2 for each column of predictions P.
    err = P - yTrue;
    rmse = sqrt(mean(err .^ 2, 1));
    mae = mean(abs(err), 1);
    rsq = 1 - sum(err .^ 2, 1) ./ sum((yTrue - mean(yTrue)) .^ 2);
end

function out = retroTable(T)
    out = table((1:height(T))', cellstr(strrep(T.facility_type, "_", " ")), ...
        cellstr(strrep(T.State_Factor, "_", " ")), ...
        arrayfun(@fmt, T.floor_area, 'UniformOutput', false), strs('%.1f', T.site_eui), ...
        strs('%.1f', T.expected_eui), strs('%.2f', T.ratio), ...
        arrayfun(@fmt, T.excess_MWh, 'UniformOutput', false), ...
        'VariableNames', {'#', 'Building type', 'State', 'Floor area (ft2)', 'Actual EUI', ...
                          'Expected EUI', 'Actual / expected', 'Excess (MWh/yr)'});
end

function c = strs(spec, x)
% Column of numbers -> cell column of formatted text (tables show it as-is).
    c = cellstr(compose(spec, x(:)));
end

function s = fmt(x)
% Whole number with thousands separators, e.g. 8215.3 -> '8,215'.
    s = regexprep(sprintf('%.0f', x), '(\d)(?=(\d{3})+$)', '$1,');
end

function s = starText(x)
    if isnan(x)
        s = 'not rated';
    else
        s = sprintf('%.0f', x);
    end
end

function s = yearText(x)
    if isnan(x)
        s = 'unknown';
    else
        s = sprintf('%d', round(x));
    end
end
