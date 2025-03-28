classdef roadMaker < handle
    properties
        % Common properties used by both 'symbolic' and 'map' road types
        roadType % Type of road: 'symbolic' or 'map'
        numberOfLines % Number of lanes on the road
        lineWidth % Width of each lane (m)
        dx % Step size for the x-vector (m)
        plotFlag % Flag to generate plots: 'yes' or 'no'
        functionBasedFlag % Flag for function-based calculations (relevant for 'symbolic' only)

        % Struct for 'symbolic' road type properties
        symbolic % Properties specific to symbolic (functional) roads
            % road_xLength: Length of the road in the x-direction (m)
            % x: Symbolic variable for x-coordinate
            % y: Symbolic function for y-coordinate

        % Struct for 'map' road type properties
        map % Properties specific to map-based roads
            % data: JSON data of route (trajectory)
            % latitude: Latitude coordinates from map data
            % longitude: Longitude coordinates from map data

        % Computed properties common to both road types
        xVec % Vector of x-coordinates of the road
        yVec % Vector of y-coordinates of the road
        sVec % Vector of arc lengths along the road
        kappaVec % Vector of curvatures along the road
        diffVec % Vector of first derivatives along the road
        interpSetup % Interpolation setup for various functions
        waypoint % Waypoint data generated along the road
    end

    methods
        % Constructor to initialize the roadMaker object
        function obj = roadMaker(roadType, numberOfLines, lineWidth, functionBasedFlag, dx, plotFlag, varargin)
            % Inputs:
            %   roadType: 'symbolic' or 'map'
            %   numberOfLines: Number of lanes
            %   lineWidth: Width of each lane (m)
            %   functionBasedFlag: Use function-based calculations (true/false, typically true for 'symbolic')
            %   dx: Step size for x-vector (m)
            %   dt: Sample time (sec)
            %   tf: Final time (sec)
            %   plotFlag: 'yes' to plot, 'no' to skip
            %   varargin: Additional arguments based on roadType
            %       For 'symbolic': road_xLength, x, y
            %       For 'map': route (map data)

            % Set common properties
            obj.roadType = roadType;
            obj.numberOfLines = numberOfLines;
            obj.lineWidth = lineWidth;
            obj.functionBasedFlag = functionBasedFlag;
            obj.dx = dx;
            obj.plotFlag = plotFlag;

            % Initialize based on road type
            switch obj.roadType
                case 'symbolic'
                    % Parse symbolic-specific inputs
                    p = inputParser;
                    addRequired(p, 'road_xLength');
                    addRequired(p, 'x');
                    addRequired(p, 'y');
                    parse(p, varargin{:});
                    obj.symbolic.road_xLength = p.Results.road_xLength;
                    obj.symbolic.x = p.Results.x;
                    obj.symbolic.y = p.Results.y;
                    obj.xVec = 0 : dx : obj.symbolic.road_xLength;
                    % Compute symbolic road properties
                    obj.computeSymbolicRoad();
                case 'map'
                    % Enforce functionBasedFlag = false for map type
                    if obj.functionBasedFlag
                        warning('For map road type, functionBasedFlag should be false. Setting to false.');
                        obj.functionBasedFlag = false;
                    end
                    % Parse map-specific inputs
                    p = inputParser;
                    addRequired(p, 'route');
                    parse(p, varargin{:});
                    obj.map.data = p.Results.route;
                    % Extract latitude and longitude
                    if isfield(obj.map.data, 'geometry') && isfield(obj.map.data.geometry, 'coordinates')
                        obj.map.lattitude_map = obj.map.data.geometry.coordinates(:, 2);
                        obj.map.longitude_map = obj.map.data.geometry.coordinates(:, 1);
                    else
                        error('JSON file does not contain valid latitude and longitude fields.');
                    end
                    % Compute map road properties
                    obj.computeMapRoad();
                otherwise
                    error("roadType must be 'symbolic' or 'map'.");
            end

            % Handle plotting if requested
            if strcmp(obj.plotFlag, 'yes')
                obj.plotCurvature();
            elseif ~strcmp(obj.plotFlag, 'no')
                error("Invalid plotFlag! Use 'yes' or 'no'.");
            end
        end

        % Compute properties for symbolic road type
        function computeSymbolicRoad(obj)
            % Symbolic road computation: Calculate derivatives, curvature, and arc length
            % First derivative
            Diffs = jacobian(obj.symbolic.y, obj.symbolic.x); % Symbolic first derivative
            DifFunctional = eval(subs(Diffs, obj.xVec)); % Evaluate at x points
            if ~isreal(DifFunctional)
                error('Imaginary derivative detected. Check x domain for the function.');
            end

            % Second derivative and curvature
            Hess = hessian(obj.symbolic.y, obj.symbolic.x); % Symbolic second derivative
            Kappas = Hess / (1 + Diffs^2)^1.5; % Symbolic curvature formula
            KappaFunctional = eval(subs(Kappas, obj.xVec)); % Evaluate curvature

            % Compute y-values
            obj.yVec = eval(subs(obj.symbolic.y, obj.xVec)); % Numerical y-values

            % Numerical derivatives and curvature
            DiffNumerical = [diff(obj.yVec) / obj.dx, 0]; % Numerical first derivative
            HessianNumerical = [diff(DiffNumerical) / obj.dx, 0]; % Numerical second derivative
            KappaNumerical = HessianNumerical ./ (1 + DiffNumerical.^2).^1.5; % Numerical curvature

            % Choose between functional and numerical based on flag
            if obj.functionBasedFlag
                obj.kappaVec = KappaFunctional;
                obj.diffVec = DifFunctional;
            else
                obj.kappaVec = KappaNumerical;
                obj.diffVec = DiffNumerical;
            end

            % Compute arc length
            obj.sVec = cumsum(obj.dx * sqrt(1 + obj.diffVec.^2)); % Cumulative arc length
            obj.sVec = obj.sVec - obj.sVec(1); % Normalize to start at zero
        end

        % Compute properties for map road type
        function computeMapRoad(obj)
            % Map road computation: Convert geographic data to Cartesian, compute derivatives and curvature
            % Set up Web Mercator projection
            obj.map.mercatorProj = defaultm('mercator');
            obj.map.mercatorProj.geoid = [6378137 0]; % WGS84 ellipsoid
            obj.map.mercatorProj.units = 'degrees';
            obj.map.mercatorProj.origin = [0 0 0];
            obj.map.mercatorProj.zone = 0;

            % Convert lat/long to x/y
            [x_raw, y_raw] = projfwd(obj.map.mercatorProj, obj.map.lattitude_map, obj.map.longitude_map);
            [x_unique, idx] = unique(x_raw, 'stable'); % Remove duplicates
            y_unique = y_raw(idx);

            % Compute arc length
            sVec_ = zeros(size(x_unique));
            for i = 2:numel(x_unique)
                dx_ = x_unique(i) - x_unique(i-1);
                dy_ = y_unique(i) - y_unique(i-1);
                sVec_(i) = sVec_(i-1) + sqrt(dx_^2 + dy_^2); % Cumulative distance
            end

            % Interpolate to finer resolution
            ds = obj.dx;
            s_fine = 0:ds:max(sVec_);
            obj.xVec = interp1(sVec_, x_unique, s_fine, 'spline');
            obj.yVec = interp1(sVec_, y_unique, s_fine, 'spline');

            % convert the interpolated x, y back to latitude and longitude
            % using projinv | HighRes --> High Resolution
            [obj.map.latitude_HighRes, obj.map.longitude_HighRes] = projinv(obj.map.mercatorProj, obj.xVec, obj.yVec);

            % Normalize x and y vector to start from [0, 0]
            obj.xVec = obj.xVec - obj.xVec(1); % Normalize to start at origin
            obj.yVec = obj.yVec - obj.yVec(1);

            % Compute derivatives and curvature
            dx_ds = [diff(obj.xVec) 0] / ds;
            dy_ds = [diff(obj.yVec) 0] / ds;
            d2x_ds2 = [diff(dx_ds) 0] / ds;
            d2y_ds2 = [diff(dy_ds) 0] / ds;
            numerator = dx_ds .* d2y_ds2 - dy_ds .* d2x_ds2;
            denominator = (dx_ds.^2 + dy_ds.^2).^(3/2);
            obj.kappaVec = numerator ./ denominator; % Parametric curvature
            obj.diffVec = dy_ds ./ dx_ds; % Slope

            obj.sVec = s_fine;
            obj.sVec = obj.sVec - obj.sVec(1); % Normalize arc length
        end
        
        function animateRoute(obj, zoomLevel, stepSize, pauseTime)
            % Description: Animates the route on a geographic map using geoplayer (for 'map' road type only)
            % Inputs:
            %   obj - roadMaker object
            %   stepSize - (Optional) Number of points to skip per frame (default: 100)
            %   pauseTime - (Optional) Delay between frames in seconds (default: 0.1)
            % Outputs: None (displays animation)

            % Validate road type
            if ~strcmp(obj.roadType, 'map')
                error('animateRoute is only supported for ''map'' road type.');
            end

            % Set up input parser for optional arguments
            p = inputParser;
            p.FunctionName = 'animateRoute'; % For better error messages

            % Define default values
            defaultStepSize = round(1 / obj.dx); % Default step size based on dx
            defaultPauseTime = 0.1;              % Default pause time in seconds

            % Add parameters with validation
            addRequired(p, 'zoomLevel', @(x) isnumeric(x) && isscalar(x) && x > 0); % Required, positive scalar
            addOptional(p, 'stepSize', defaultStepSize, @(x) isnumeric(x) && isscalar(x) && x >= 1 && floor(x) == x); % Integer >= 1
            addOptional(p, 'pauseTime', defaultPauseTime, @(x) isnumeric(x) && isscalar(x) && x >= 0); % Non-negative scalar

            % Parse inputs
            parse(p, zoomLevel, stepSize, pauseTime);

            % Extract parsed values
            zoomLevel = p.Results.zoomLevel;
            stepSize = p.Results.stepSize;
            pauseTime = p.Results.pauseTime;

            % Initialize geoplayer with starting position
            player = geoplayer(obj.map.latitude_HighRes(1), obj.map.longitude_HighRes(1), zoomLevel);
            player.Basemap = 'openstreetmap'; % Use OpenStreetMap basemap

            % Plot the entire route
            plotRoute(player, obj.map.latitude_HighRes, obj.map.longitude_HighRes);

            % Animate the route by plotting each position
            for i = 1:stepSize:length(obj.map.latitude_HighRes)
                plotPosition(player, obj.map.latitude_HighRes(i), obj.map.longitude_HighRes(i));
                pause(pauseTime); % Pause for animation effect
            end
        end

        % Plot curvature and arc length (symbolic roads only)
        function plotCurvature(obj)
            if strcmp(obj.roadType, 'symbolic')
                % Recompute KappaNumerical and KappaFunctional for plotting
                DiffNumerical = [diff(obj.yVec) / obj.dx, 0];
                HessianNumerical = [diff(DiffNumerical) / obj.dx, 0];
                KappaNumerical = HessianNumerical ./ (1 + DiffNumerical.^2).^1.5;
                Diffs = jacobian(obj.symbolic.y, obj.symbolic.x);
                Hess = hessian(obj.symbolic.y, obj.symbolic.x);
                Kappas = Hess / (1 + Diffs^2)^1.5;
                KappaFunctional = eval(subs(Kappas, obj.xVec));

                % Plot curvature
                figure('Name', 'Curvature');
                plot(obj.xVec(1:end-2), KappaNumerical(1:end-2), 'DisplayName', '$\kappa(x)$, Numerical', 'Color', 'b', 'LineWidth', 2);
                hold on;
                plot(obj.xVec(1:end-2), KappaFunctional(1:end-2), 'DisplayName', '$\kappa(x)$, Exact', 'Color', 'r', 'LineWidth', 1, 'LineStyle', '--');
                hold off;
                set(gcf, 'Color', 'w');
                set(gca, 'XColor', 'k', 'YColor', 'k', 'FontSize', 20);
                set(findall(gcf, 'Type', 'line'), 'LineWidth', 3, 'MarkerSize', 16);
                title(['Function y = ', string(obj.symbolic.y)], 'FontSize', 16, 'FontName', 'Times New Roman', 'Interpreter', 'latex');
                xlabel('$x$', 'FontSize', 16, 'FontName', 'Times New Roman', 'Interpreter', 'latex');
                ylabel('Curvature', 'FontSize', 16, 'FontName', 'Times New Roman', 'Interpreter', 'latex');
                legend('show', 'Interpreter', 'latex');
                box on; grid on;

                % Plot arc length
                figure('Name', 'Arc Length');
                plot(obj.xVec, obj.sVec, 'DisplayName', '$s(x)$', 'Color', 'b', 'LineWidth', 2);
                set(gcf, 'Color', 'w');
                set(gca, 'XColor', 'k', 'YColor', 'k', 'FontSize', 20);
                set(findall(gcf, 'Type', 'line'), 'LineWidth', 3, 'MarkerSize', 16);
                title(['Function y = ', string(obj.symbolic.y)], 'FontSize', 16, 'FontName', 'Times New Roman', 'Interpreter', 'latex');
                xlabel('$x$', 'FontSize', 16, 'FontName', 'Times New Roman', 'Interpreter', 'latex');
                ylabel('Traveled Distance', 'FontSize', 16, 'FontName', 'Times New Roman', 'Interpreter', 'latex');
                legend('show', 'Interpreter', 'latex');
                box on; grid on;
            else
                disp('Plotting is implemented only for symbolic road type.');
            end
        end

        % Precompute interpolation functions
        function [setup, obj] = precomputeInterpolants(obj)
            % Ensure sVec is monotonic for interpolation
            if ~issorted(obj.sVec)
                error('sVec must be strictly increasing and monotonic.');
            end
            setup.roadType = obj.roadType;
            setup.xInterp = griddedInterpolant(obj.sVec, obj.xVec, 'linear'); % x(s)

            switch obj.roadType
                case 'symbolic'
                    setup.psiInterp = griddedInterpolant(obj.sVec, atan(obj.diffVec), 'linear'); % psi(s)
                    setup.sInterp = griddedInterpolant(obj.xVec, obj.sVec, 'spline'); % s(x)
                    setup.yInterp = matlabFunction(obj.symbolic.y); % y(x)
                case 'map'
                    ds = obj.dx;
                    dx_ds = gradient(obj.xVec, ds);
                    dy_ds = gradient(obj.yVec, ds);
                    ThetaBound = atan2(dy_ds, dx_ds);
                    setup.psiInterp = griddedInterpolant(obj.sVec, ThetaBound, 'linear'); % psi(s)
                    setup.yInterp = griddedInterpolant(obj.sVec, obj.yVec, 'linear'); % y(s)
            end
            obj.interpSetup = setup;
        end

        % Generate waypoints along the road
        function [out, obj] = waypointGenerator(obj, np, starting)
            % Inputs:
            %   np: Number of points for smoothing waypoints (lower np = smoother)
            %   starting: Starting arc length (s) for waypoints
            distances = abs(obj.sVec - starting);
            [~, closestIDX] = min(distances);

            % Initialize waypoint arrays
            obj.waypoint.d = zeros(1, numel(obj.sVec) - closestIDX + 1);
            obj.waypoint.x = zeros(1, numel(obj.sVec) - closestIDX + 1);
            obj.waypoint.y = zeros(1, numel(obj.sVec) - closestIDX + 1);
            obj.waypoint.waypoints = zeros(2, numel(obj.sVec) - closestIDX + 1);

            % Generate smooth random offsets
            points = linspace(0, 1, np);
            lim = obj.numberOfLines * obj.lineWidth / 2 - obj.lineWidth / 2;
            d = 2 * lim * (rand(1, np) - 0.5);
            d_smooth = pchip(points, d, linspace(0, 1, numel(obj.sVec) - closestIDX + 1));
            max_val = max(abs(d_smooth));
            d_smooth = d_smooth * (lim / max_val); % Scale to stay within bounds
            obj.waypoint.d = d_smooth;

            % Compute waypoint coordinates
            for i = closestIDX:numel(obj.sVec)
                psi = obj.interpSetup.psiInterp(obj.sVec(i));
                obj.waypoint.x(i - closestIDX + 1) = obj.xVec(i) + obj.waypoint.d(i - closestIDX + 1) * sin(psi);
                obj.waypoint.y(i - closestIDX + 1) = obj.yVec(i) - obj.waypoint.d(i - closestIDX + 1) * cos(psi);
            end
            obj.waypoint.closestIDX = closestIDX;
            obj.waypoint.waypoints = [obj.waypoint.x; obj.waypoint.y];
            out = obj.waypoint;
        end

        % Check curvature criticality
        function checkCurvature(obj)
            % Ensure curvature is not too tight relative to road width
            CurvatureCriticality = max(abs(obj.kappaVec(2:end-2))) * obj.lineWidth * ceil(obj.numberOfLines / 2);
            if CurvatureCriticality >= 1
                error(['Curvature too tight. Ratio: ', num2str(CurvatureCriticality)]);
            end
        end

        % Plot the road trajectory with lanes
        function plotRoad(obj)
            % Compute lane offsets
            ds = obj.dx;
            dx_ds = gradient(obj.xVec, ds);
            dy_ds = gradient(obj.yVec, ds);
            ThetaBound = atan2(dy_ds, dx_ds);

            if mod(obj.numberOfLines, 2) % Odd number of lines
                CoeffLine = (obj.numberOfLines + 1) / 2;
                dLineVec = (-CoeffLine:CoeffLine - 1) * obj.lineWidth + 0.5 * obj.lineWidth;
            else % Even number of lines
                CoeffLine = obj.numberOfLines / 2;
                dLineVec = (-CoeffLine:CoeffLine) * obj.lineWidth;
            end

            % Compute lane coordinates
            NumberOfLinePlots = numel(dLineVec);
            XBoundLower = zeros(NumberOfLinePlots, numel(obj.xVec));
            YBoundLower = zeros(NumberOfLinePlots, numel(obj.yVec));
            for j = 1:NumberOfLinePlots
                XBoundLower(j, :) = obj.xVec + dLineVec(j) .* sin(ThetaBound);
                YBoundLower(j, :) = obj.yVec - dLineVec(j) .* cos(ThetaBound);
            end

            % Plot road and lanes
            figure;
            fill([XBoundLower(1, :), fliplr(XBoundLower(end, :))], ...
                 [YBoundLower(1, :), fliplr(YBoundLower(end, :))], ...
                 [0.4, 0.4, 0.4], 'EdgeColor', 'none', 'HandleVisibility', 'off'); % Asphalt
            hold on;
            for j = 2:NumberOfLinePlots-1
                plot(XBoundLower(j, :), YBoundLower(j, :), 'Color', [1, 0.84, 0], 'LineWidth', 0.1, 'LineStyle', '--', 'HandleVisibility', 'off'); % Yellow lanes
            end
            plot(XBoundLower(1, :), YBoundLower(1, :), 'k-', 'LineWidth', 2, 'HandleVisibility', 'off'); % Outer bounds
            plot(XBoundLower(end, :), YBoundLower(end, :), 'k-', 'LineWidth', 2, 'HandleVisibility', 'off');

            % Customize plot
            set(gcf, 'Position', [100, 100, 1200, 600]);
            axis equal;
            set(gca, 'LooseInset', max(get(gca, 'TightInset'), 0.02));
            set(gcf, 'Color', 'w');
            set(gca, 'XColor', 'k', 'YColor', 'k', 'FontSize', 20);
            xlabel('$X$', 'FontSize', 16, 'FontName', 'Times New Roman', 'Interpreter', 'latex');
            ylabel('$Y$', 'FontSize', 16, 'FontName', 'Times New Roman', 'Interpreter', 'latex');
            box on; grid off;
        end
    end
end