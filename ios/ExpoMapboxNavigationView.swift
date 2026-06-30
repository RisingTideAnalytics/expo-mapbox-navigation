import ExpoModulesCore
import ObjectiveC
import MapboxNavigationCore
import MapboxMaps
import MapboxNavigationUIKit
import MapboxDirections
import Combine


class PointExclusionRouteOptions: NavigationRouteOptions {
    var pointExclusions: [String] = []

    override var urlQueryItems: [URLQueryItem] {
        var items = super.urlQueryItems
        if !pointExclusions.isEmpty {
            let pointValues = pointExclusions.joined(separator: ",")
            if let existingIndex = items.firstIndex(where: { $0.name == "exclude" }) {
                let existingValue = items[existingIndex].value ?? ""
                let combined = existingValue.isEmpty ? pointValues : existingValue + "," + pointValues
                items[existingIndex] = URLQueryItem(name: "exclude", value: combined)
            } else {
                items.append(URLQueryItem(name: "exclude", value: pointValues))
            }
        }
        return items
    }
}

class ExpoMapboxNavigationView: ExpoView {
    private let onRouteProgressChanged = EventDispatcher()
    private let onCancelNavigation = EventDispatcher()
    private let onWaypointArrival = EventDispatcher()
    private let onFinalDestinationArrival = EventDispatcher()
    private let onRouteChanged = EventDispatcher()
    private let onUserOffRoute = EventDispatcher()
    private let onRoutesLoaded = EventDispatcher()
    private let onRouteFailedToLoad = EventDispatcher()
    private let onLocationChange = EventDispatcher()
    private let onMuteChange = EventDispatcher()

    let controller = ExpoMapboxNavigationViewController()

    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        clipsToBounds = true
        addSubview(controller.view)

        controller.onRouteProgressChanged = onRouteProgressChanged
        controller.onCancelNavigation = onCancelNavigation
        controller.onWaypointArrival = onWaypointArrival
        controller.onFinalDestinationArrival = onFinalDestinationArrival
        controller.onRouteChanged = onRouteChanged
        controller.onUserOffRoute = onUserOffRoute
        controller.onRoutesLoaded = onRoutesLoaded
        controller.onRouteFailedToLoad = onRouteFailedToLoad
        controller.onLocationChange = onLocationChange
        controller.onMuteChange = onMuteChange
    }

    override func layoutSubviews() {
        controller.view.frame = bounds
    }
}


class ExpoMapboxNavigationViewController: UIViewController {
    // Use a shared navigation provider but create separate instances for each view
    static let navigationProvider: MapboxNavigationProvider = MapboxNavigationProvider(coreConfig: CoreConfig(routingConfig: RoutingConfig(fasterRouteDetectionConfig: Optional<FasterRouteDetectionConfig>.none),locationSource: .live ))

    // Instance-specific navigation components
    var mapboxNavigation: MapboxNavigation? = nil
    var routingProvider: RoutingProvider? = nil
    var navigation: NavigationController? = nil
    var tripSession: SessionController? = nil
    var navigationViewController: NavigationViewController? = nil

    // Flag to track if this instance is active
    private var isActive: Bool = true
    
    var currentCoordinates: Array<CLLocationCoordinate2D>? = nil
    var initialLocation: CLLocationCoordinate2D? = nil
    var initialLocationZoom: Double? = nil
    var currentWaypointIndices: Array<Int>? = nil
    var currentLocale: Locale = Locale.current
    var currentRouteProfile: String? = nil
    var currentRouteExcludeList: Array<String>? = nil
    var currentMapStyle: String? = nil
    var currentCustomRasterSourceUrl: String? = nil
    var currentPlaceCustomRasterLayerAbove: String? = nil
    var currentDisableAlternativeRoutes: Bool? = nil
    var currentFollowingZoom: Double? = nil
    var isUsingRouteMatchingApi: Bool = false
    var vehicleMaxHeight: Double? = nil
    var vehicleMaxWidth: Double? = nil
    var vehicleMaxWeight: Double? = nil
    var allowsArrivingOnOppositeSide: Bool? = nil
    var showsEndOfRouteFeedback: Bool? = nil
    var hideTripProgress: Bool = false

    var onRouteProgressChanged: EventDispatcher? = nil
    var onCancelNavigation: EventDispatcher? = nil
    var onWaypointArrival: EventDispatcher? = nil
    var onFinalDestinationArrival: EventDispatcher? = nil
    var onRouteChanged: EventDispatcher? = nil
    var onUserOffRoute: EventDispatcher? = nil
    var onRoutesLoaded: EventDispatcher? = nil
    var onRouteFailedToLoad: EventDispatcher? = nil
    var onLocationChange: EventDispatcher? = nil
    var onMuteChange: EventDispatcher? = nil

    var calculateRoutesTask: Task<Void, Error>? = nil
    // Coalesces the burst of per-prop update() calls React applies each render into one
    // route request, and tags each request so superseded ones are ignored rather than
    // cancelled (see update()/calculateRoutes()).
    private var updateScheduled: Bool = false
    private var routeRequestGeneration: Int = 0
    private var routeProgressCancellable: AnyCancellable? = nil
    private var waypointArrivalCancellable: AnyCancellable? = nil
    private var reroutingCancellable: AnyCancellable? = nil
    private var sessionCancellable: AnyCancellable? = nil
    private var locationCancellable: AnyCancellable? = nil

    var currentUIStyle: String? = nil

    init() {
        super.init(nibName: nil, bundle: nil)
        mapboxNavigation = ExpoMapboxNavigationViewController.navigationProvider.mapboxNavigation
        routingProvider = mapboxNavigation!.routingProvider()
        navigation = mapboxNavigation!.navigation()
        tripSession = mapboxNavigation!.tripSession()

        routeProgressCancellable = navigation!.routeProgress.sink {[weak self] progressState in
            guard let self = self, self.isActive, self.view.window != nil else { return }
            if(progressState != nil){


                // For some reason the maneuver arrows sometimes (not consistently) show up the same color as the route line making them invisible.
                // This is a hack to always ensure the arrows are visible.
                try? self.navigationViewController?.navigationMapView?.mapView.mapboxMap.setLayerProperty(
                    for: "com.mapbox.navigation.arrow.next",
                    property: "line-color",
                    value: "#FFFFFF"
                )
                try? self.navigationViewController?.navigationMapView?.mapView.mapboxMap.setLayerProperty(
                    for: "com.mapbox.navigation.arrow.next.stroke",
                    property: "line-color",
                    value: "#FFFFFF"
                )
                try? self.navigationViewController?.navigationMapView?.mapView.mapboxMap.setLayerProperty(
                    for: "com.mapbox.navigation.arrow.next.symbol",
                    property: "icon-color",
                    value: "#FFFFFF"
                )
                try? self.navigationViewController?.navigationMapView?.mapView.mapboxMap.setLayerProperty(
                    for: "com.mapbox.navigation.arrow.next.symbol.casing",
                    property: "icon-color",
                    value: "#FFFFFF"
                )

               self.onRouteProgressChanged?([
                    "distanceRemaining": progressState!.routeProgress.distanceRemaining,
                    "distanceTraveled": progressState!.routeProgress.distanceTraveled,
                    "durationRemaining": progressState!.routeProgress.durationRemaining,
                    "fractionTraveled": progressState!.routeProgress.fractionTraveled,
                    "isMuted": ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController.speechSynthesizer.muted,
                ])
            }
        }

        waypointArrivalCancellable = navigation!.waypointsArrival.sink { [weak self] arrivalStatus in
            guard let self = self, self.isActive, self.view.window != nil else { return }
            let event = arrivalStatus.event
            if event is WaypointArrivalStatus.Events.ToFinalDestination {
                self.onFinalDestinationArrival?()
            } else if event is WaypointArrivalStatus.Events.ToWaypoint {
                self.onWaypointArrival?()
            }
        }

        reroutingCancellable = navigation!.rerouting.sink { [weak self] rerouteStatus in
            guard let self = self, self.isActive, self.view.window != nil else { return }
            self.onRouteChanged?()
        }

        sessionCancellable = tripSession!.session.sink { [weak self] session in
            guard let self = self, self.isActive, self.view.window != nil else { return }
            let state = session.state
            switch state {
                case .activeGuidance(let activeGuidanceState):
                    switch(activeGuidanceState){
                        case .offRoute:
                            self.onUserOffRoute?()
                        default: break
                    }
                default: break
            }
        }

        // Subscribe to location updates
        locationCancellable = navigation!.locationMatching.sink { [weak self] locationMatchingState in
            guard let self = self, self.isActive, self.view.window != nil else { return }
            let location = locationMatchingState.enhancedLocation
            self.onLocationChange?([
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "heading": location.course,
                "speed": location.speed
            ])
        }

    }

    deinit {
        // Mark as inactive to prevent event dispatching
        isActive = false

        // Cancel all subscriptions first
        routeProgressCancellable?.cancel()
        waypointArrivalCancellable?.cancel()
        reroutingCancellable?.cancel()
        sessionCancellable?.cancel()
        locationCancellable?.cancel()

        // Nil out the cancellables
        routeProgressCancellable = nil
        waypointArrivalCancellable = nil
        reroutingCancellable = nil
        sessionCancellable = nil
        locationCancellable = nil

        // Stop navigation session on main thread
        let session = tripSession
        let navVC = navigationViewController
        DispatchQueue.main.async {
            session?.setToIdle()

            // Remove navigation view controller
            if let navVC = navVC {
                navVC.willMove(toParent: nil)
                navVC.view.removeFromSuperview()
                navVC.removeFromParent()
            }
        }
        navigationViewController = nil

        // Nil out event dispatchers to prevent events after deallocation
        onRouteProgressChanged = nil
        onCancelNavigation = nil
        onWaypointArrival = nil
        onFinalDestinationArrival = nil
        onRouteChanged = nil
        onUserOffRoute = nil
        onRoutesLoaded = nil
        onRouteFailedToLoad = nil
        onLocationChange = nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Reactivate when view appears
        isActive = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        // Mark as inactive to prevent event dispatching
        isActive = false

        // Clean up synchronously on main thread if already on it, otherwise async
        if Thread.isMainThread {
            cleanupNavigationSession()
        } else {
            DispatchQueue.main.sync {
                cleanupNavigationSession()
            }
        }
    }

    private func cleanupNavigationSession() {
        // This must be called on main thread
        tripSession?.setToIdle()

        // Clean up navigation view controller
        if let navVC = navigationViewController {
            navVC.willMove(toParent: nil)
            navVC.view.removeFromSuperview()
            navVC.removeFromParent()
        }
        navigationViewController = nil
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        fatalError("This controller should not be loaded through a story board")
    }

    func setUIStyle(style: String?) {
        currentUIStyle = style
        update()
    }

    func addCustomRasterLayer() {
        let navigationMapView = navigationViewController?.navigationMapView
        let sourceId = "raster-source"
        let layerId = "raster-layer"

        if(currentCustomRasterSourceUrl == nil){
            if let mapView = navigationMapView?.mapView.mapboxMap {
                if mapView.layerExists(withId: layerId) {
                    try? mapView.removeLayer(withId: layerId)
                }
                if mapView.sourceExists(withId: sourceId) {
                    try? mapView.removeSource(withId: sourceId)
                }
            }
            return
        }

        let sourceUrl = currentCustomRasterSourceUrl! 

        var rasterSource = RasterSource(id: sourceId)

        rasterSource.tiles = [sourceUrl]
        rasterSource.tileSize = 256

        let rasterLayer = RasterLayer(id: layerId, source: sourceId)


        if let mapView = navigationMapView?.mapView.mapboxMap {
            if mapView.layerExists(withId: layerId) {
                try? mapView.removeLayer(withId: layerId)
            }
            if mapView.sourceExists(withId: sourceId) {
                try? mapView.removeSource(withId: sourceId)
            }

            try? mapView.addSource(rasterSource)
            try? mapView.addLayer(rasterLayer, layerPosition: .above(currentPlaceCustomRasterLayerAbove ?? "water"))    
        }
    }


    func setCoordinates(coordinates: Array<CLLocationCoordinate2D>) {
        currentCoordinates = coordinates
        update()
    }

    func setVehicleMaxHeight(maxHeight: Double?) {
        vehicleMaxHeight = maxHeight
        update()
    }

    func setVehicleMaxWidth(maxWidth: Double?) {
        vehicleMaxWidth = maxWidth
        update()
    }

    func setVehicleMaxWeight(maxWeight: Double?) {
        vehicleMaxWeight = maxWeight
        update()
    }

    func setAllowsArrivingOnOppositeSide(allows: Bool?) {
        allowsArrivingOnOppositeSide = allows
        update()
    }

    func setShowsEndOfRouteFeedback(shows: Bool?) {
        showsEndOfRouteFeedback = shows
        update()
    }

    func setHideTripProgress(hide: Bool?) {
        hideTripProgress = hide ?? false
        update()
    }

    func setLocale(locale: String?) {
        if(locale != nil){
            currentLocale = Locale(identifier: locale!)
        } else {
            currentLocale = Locale.current
        }
        update()
    }

    func setIsUsingRouteMatchingApi(useRouteMatchingApi: Bool?){
        isUsingRouteMatchingApi = useRouteMatchingApi ?? false
        update()
    }

    func setWaypointIndices(waypointIndices: Array<Int>?){
        currentWaypointIndices = waypointIndices
        update()
    }

    func setRouteProfile(profile: String?){
        currentRouteProfile = profile
        update()
    }

    func setRouteExcludeList(excludeList: Array<String>?){
        currentRouteExcludeList = excludeList
        update()
    }

    func setMapStyle(style: String?){
        currentMapStyle = style
        update()
    }

    func setCustomRasterSourceUrl(url: String?){
        currentCustomRasterSourceUrl = url
        update()
    }

    func setPlaceCustomRasterLayerAbove(layerId: String?){
        currentPlaceCustomRasterLayerAbove = layerId
        update()
    }

    func setDisableAlternativeRoutes(disableAlternativeRoutes: Bool?){
        currentDisableAlternativeRoutes = disableAlternativeRoutes
        update()
    }

    func recenterMap(){
        let navigationMapView = navigationViewController?.navigationMapView
        navigationMapView?.navigationCamera.update(cameraState: .following)
    }

    func setIsMuted(isMuted: Bool?){
        if(isMuted != nil){
            ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController.speechSynthesizer.muted = isMuted!
        }
    }

    func setInitialLocation(location: CLLocationCoordinate2D, zoom: Double?){
        initialLocation = location
        // Validate zoom value to prevent NaN errors
        if let zoom = zoom, !zoom.isNaN && !zoom.isInfinite && zoom > 0 {
            initialLocationZoom = zoom
        } else {
            initialLocationZoom = 15 // Default zoom
        }
        let navigationMapView = navigationViewController?.navigationMapView
        if(initialLocation != nil && navigationMapView != nil){
            let validZoom = initialLocationZoom ?? 15
            navigationMapView!.mapView.mapboxMap.setCamera(to: CameraOptions(center: initialLocation!, zoom: validZoom))
        }
    }

    func setFollowingZoom(followingZoom: Double?){
        let navigationMapView = navigationViewController?.navigationMapView
        // Validate zoom value to prevent NaN errors
        if let zoom = followingZoom, !zoom.isNaN && !zoom.isInfinite && zoom > 0 {
            currentFollowingZoom = zoom
            if(navigationMapView != nil){
                let newDataSource = MobileViewportDataSource(navigationMapView!.mapView)
                newDataSource.options.followingCameraOptions.zoomRange = zoom...zoom
                navigationMapView?.navigationCamera.viewportDataSource = newDataSource
            }
        } else {
            currentFollowingZoom = nil
        }
    }

    func update(){
        // React/Expo applies every prop through its own setter, and each setter calls
        // update(). On mount and on every re-render that is ~15 update() calls within a
        // single runloop tick. Recalculating a route on each one previously cancelled the
        // in-flight calculateRoutes Task every time; MapboxNavigationCore's
        // doRequest(options:) does not resume its continuation when its Task is cancelled,
        // so each cancelled request leaked a continuation ("SWIFT TASK CONTINUATION
        // MISUSE") and ultimately crashed the app. Coalesce the burst into a single
        // request by deferring the work to the end of the current runloop tick, by which
        // point every prop in this render has been applied.
        if updateScheduled { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateScheduled = false
            self.performUpdate()
        }
    }

    private func performUpdate(){
        if(currentCoordinates != nil){
            let waypoints = currentCoordinates!.enumerated().map {
                let index = $0
                let coordinate = $1
                var waypoint = Waypoint(coordinate: coordinate)
                waypoint.separatesLegs = currentWaypointIndices == nil ? true : currentWaypointIndices!.contains(index)
                return waypoint
            }

            if(isUsingRouteMatchingApi){
                calculateMapMatchingRoutes(waypoints: waypoints)
            } else {
                calculateRoutes(waypoints: waypoints)
            }
        }
    }

    func calculateRoutes(waypoints: Array<Waypoint>){
        // Separate point exclusions from standard road class exclusions
        let pointExclusions = currentRouteExcludeList?.filter { $0.hasPrefix("point(") } ?? []
        let roadClassExclusions = currentRouteExcludeList?.filter { !$0.hasPrefix("point(") } ?? []

        let routeOptions = PointExclusionRouteOptions(
            waypoints: waypoints,
            profileIdentifier: currentRouteProfile != nil ? ProfileIdentifier(rawValue: currentRouteProfile!) : nil,
            queryItems: [
                URLQueryItem(name: "exclude", value: roadClassExclusions.isEmpty ? nil : roadClassExclusions.joined(separator: ",")),
                URLQueryItem(name: "max_height", value: String(format: "%.1f", vehicleMaxHeight ?? 0.0)),
                URLQueryItem(name: "max_width", value: String(format: "%.1f", vehicleMaxWidth ?? 0.0)),
                URLQueryItem(name: "max_weight", value: String(format: "%.1f", vehicleMaxWeight ?? 0.0))
            ],
            locale: currentLocale,
            distanceUnit: currentLocale.usesMetricSystem ? LengthFormatter.Unit.meter : LengthFormatter.Unit.mile
        )
        routeOptions.pointExclusions = pointExclusions

        // Configure waypoints for arrival on opposite side if specified
        if let allows = allowsArrivingOnOppositeSide {
            for i in 0..<routeOptions.waypoints.count {
                routeOptions.waypoints[i].allowsArrivingOnOppositeSide = allows
            }
        }

        routeRequestGeneration += 1
        let generation = routeRequestGeneration
        calculateRoutesTask = Task {
            // Let the request run to completion (never cancelled) so the SDK resumes its
            // continuation; if a newer request has started meanwhile, drop this result.
            let result = await self.routingProvider!.calculateRoutes(options: routeOptions).result
            guard generation == self.routeRequestGeneration else { return }
            switch result {
            case .failure(let error):
                onRouteFailedToLoad?([
                    "errorMessage": error.localizedDescription
                ])
                print(error.localizedDescription)
            case .success(let navigationRoutes):
                onRoutesCalculated(navigationRoutes: navigationRoutes)
            }
        }
    }

    func calculateMapMatchingRoutes(waypoints: Array<Waypoint>){
        let matchOptions = NavigationMatchOptions(
            waypoints: waypoints, 
            profileIdentifier: currentRouteProfile != nil ? ProfileIdentifier(rawValue: currentRouteProfile!) : nil,
            queryItems: [URLQueryItem(name: "exclude", value: currentRouteExcludeList?.joined(separator: ","))],
            distanceUnit: currentLocale.usesMetricSystem ? LengthFormatter.Unit.meter : LengthFormatter.Unit.mile
        )
        matchOptions.locale = currentLocale


        routeRequestGeneration += 1
        let generation = routeRequestGeneration
        calculateRoutesTask = Task {
            // Let the request run to completion (never cancelled) so the SDK resumes its
            // continuation; if a newer request has started meanwhile, drop this result.
            let result = await self.routingProvider!.calculateRoutes(options: matchOptions).result
            guard generation == self.routeRequestGeneration else { return }
            switch result {
            case .failure(let error):
                onRouteFailedToLoad?([
                    "errorMessage": error.localizedDescription
                ])
                print(error.localizedDescription)
            case .success(let navigationRoutes):
                onRoutesCalculated(navigationRoutes: navigationRoutes)
            }
        }
    }

    @objc func cancelButtonClicked(_ sender: AnyObject?) {
        onCancelNavigation?()
    }

    @objc func muteButtonTapped(_ sender: AnyObject?) {
        // toggleMute: is async; read the settled selected state shortly after and report it.
        guard let button = sender as? UIButton else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak button] in
            guard let self = self, let button = button, self.isActive else { return }
            self.onMuteChange?(["isMuted": button.isSelected, "source": "tap"])
        }
    }

    private func findMuteButton(in navVC: NavigationViewController) -> UIButton? {
        // Primary: reflection. The mute button is a private lazy `muteButton: FloatingButton` on the
        // nav VC (or its OrnamentsController). object_getIvar is only called on name-matched ivars
        // (object types), so it is safe and avoids the `allTargets` Set-bridge crash.
        if let b = findMuteButtonReflectively(navVC) {
            NSLog("[AudibleDirections] mute button via reflection")
            return b
        }
        // Fallback: accessibilityLabel among the floating buttons.
        var candidates: [UIButton] = navVC.navigationView.floatingStackView.arrangedSubviews
            .compactMap { $0 as? UIButton }
        if let fb = navVC.navigationView.floatingButtons {
            for b in fb where !candidates.contains(where: { $0 === b }) { candidates.append(b) }
        }
        NSLog("[AudibleDirections] reflection miss; candidates=\(candidates.count)")
        let muteLabels: Set<String> = ["mute", "unmute"]
        for b in candidates {
            if let label = b.accessibilityLabel?.lowercased(), muteLabels.contains(label) {
                NSLog("[AudibleDirections] mute button via label=\(label)")
                return b
            }
        }
        for (i, b) in candidates.enumerated() {
            NSLog("[AudibleDirections] btn[\(i)] class=\(String(describing: type(of: b))) label=\(b.accessibilityLabel ?? "nil")")
        }
        return nil
    }

    private func findMuteButtonReflectively(_ obj: AnyObject) -> UIButton? {
        if let b = ivarValue(of: obj, nameContains: "muteButton") as? UIButton { return b }
        if let ornaments = ivarValue(of: obj, nameContains: "rnament") {
            if let b = ivarValue(of: ornaments, nameContains: "muteButton") as? UIButton { return b }
        }
        return nil
    }

    private func ivarValue(of obj: AnyObject, nameContains needle: String) -> AnyObject? {
        var cls: AnyClass? = object_getClass(obj)
        while let c = cls {
            var count: UInt32 = 0
            if let list = class_copyIvarList(c, &count) {
                defer { free(list) }
                for i in 0..<Int(count) {
                    guard let cName = ivar_getName(list[i]),
                          let name = String(validatingUTF8: cName) else { continue }
                    // Only read object-typed ivars (encoding "@...") so object_getIvar never
                    // misinterprets a value-type ivar (which could crash).
                    if name.contains(needle),
                       let encC = ivar_getTypeEncoding(list[i]),
                       let enc = String(validatingUTF8: encC), enc.hasPrefix("@") {
                        return object_getIvar(obj, list[i]) as AnyObject?
                    }
                }
            }
            cls = class_getSuperclass(c)
        }
        return nil
    }

    func convertRoute(route: Route) -> Any {
        return [
            "distance": route.distance,
            "expectedTravelTime": route.expectedTravelTime,
            "legs": route.legs.map { leg in
                return [
                    "source": leg.source != nil ? [
                        "latitude": leg.source!.coordinate.latitude,
                        "longitude": leg.source!.coordinate.longitude
                    ] : nil,
                    "destination": leg.destination != nil ? [
                        "latitude": leg.destination!.coordinate.latitude,
                        "longitude": leg.destination!.coordinate.longitude
                    ] : nil,
                    "steps": leg.steps.map { step in
                        return [
                            "shape": step.shape != nil ? [
                                "coordinates": step.shape!.coordinates.map { coordinate in
                                    return [
                                        "latitude": coordinate.latitude,
                                        "longitude": coordinate.longitude,
                                    ]
                                }
                            ] : nil
                        ]
                    }
                ]
            }
        ]
    }

    func onRoutesCalculated(navigationRoutes: NavigationRoutes){
        // Ensure we're on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isActive else { return }

            // Stop any existing navigation session before starting a new one
            self.tripSession?.setToIdle()

            // Clean up existing navigation view controller if any
            if let existingNavVC = self.navigationViewController {
                existingNavVC.delegate = nil
                existingNavVC.willMove(toParent: nil)
                existingNavVC.view.removeFromSuperview()
                existingNavVC.removeFromParent()
                self.navigationViewController = nil
            }

            // Small delay to ensure previous session is fully cleaned up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, self.isActive else { return }
                self.setupNavigationViewController(with: navigationRoutes)
            }
        }
    }

    @MainActor
    private func setupNavigationViewController(with navigationRoutes: NavigationRoutes) {
        onRoutesLoaded?([
            "routes": [
                "mainRoute": convertRoute(route: navigationRoutes.mainRoute.route),
                "alternativeRoutes": navigationRoutes.alternativeRoutes.map { convertRoute(route: $0.route) }
            ]
        ])

        let topBanner = TopBannerViewController()
        topBanner.instructionsBannerView.distanceFormatter.locale = currentLocale
        let bottomBanner = BottomBannerViewController()
        bottomBanner.distanceFormatter.locale = currentLocale
        bottomBanner.dateFormatter.locale = currentLocale

        let uiStyles: [Style] = currentUIStyle == "night" ? [NightStyle()] : [DayStyle()]    

        let navigationOptions = NavigationOptions(
            mapboxNavigation: self.mapboxNavigation!,
            voiceController: ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController,
            eventsManager: ExpoMapboxNavigationViewController.navigationProvider.eventsManager(),
            styles: uiStyles,
            topBanner: topBanner,
            bottomBanner: bottomBanner
        )

        // Always create a new NavigationViewController to avoid session conflicts
        let newNavigationViewController = NavigationViewController(
            navigationRoutes: navigationRoutes,
            navigationOptions: navigationOptions
        )

        self.navigationViewController = newNavigationViewController
        let navigationViewController = newNavigationViewController

        navigationViewController.showsContinuousAlternatives = currentDisableAlternativeRoutes != true
        navigationViewController.usesNightStyleWhileInTunnel = false
        navigationViewController.automaticallyAdjustsStyleForTimeOfDay = false
        navigationViewController.showsEndOfRouteFeedback = showsEndOfRouteFeedback ?? true

        let navigationMapView = navigationViewController.navigationMapView
        navigationMapView!.puckType = .puck2D(.navigationDefault)

        if(initialLocation != nil){
            // Validate zoom to prevent NaN errors
            let validZoom: Double
            if let zoom = initialLocationZoom, !zoom.isNaN && !zoom.isInfinite && zoom > 0 {
                validZoom = zoom
            } else {
                validZoom = 15
            }
            navigationMapView!.mapView.mapboxMap.setCamera(to: CameraOptions(center: initialLocation!, zoom: validZoom))
        }

        let style = currentMapStyle != nil ? StyleURI(rawValue: currentMapStyle!) : StyleURI.streets
        navigationMapView!.mapView.mapboxMap.loadStyle(style!, completion: { _ in
            navigationMapView!.localizeLabels(locale: self.currentLocale)
            do{
                try navigationMapView!.mapView.mapboxMap.localizeLabels(into: self.currentLocale)
            } catch {}
            self.addCustomRasterLayer()
        })
        

        if let cancelButton = navigationViewController.navigationView.bottomBannerContainerView.findViews(subclassOf: CancelButton.self).first {
            cancelButton.addTarget(self, action: #selector(cancelButtonClicked), for: .touchUpInside)
        }

        if hideTripProgress {
            navigationViewController.navigationView.bottomBannerContainerView.isHidden = true
        }

        navigationViewController.delegate = self
        addChild(navigationViewController)
        view.addSubview(navigationViewController.view)
        navigationViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigationViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            navigationViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            navigationViewController.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            navigationViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0),
        ])
        navigationViewController.didMove(toParent: self)

        // Only start active guidance if this instance is still active
        if isActive {
            mapboxNavigation!.tripSession().startActiveGuidance(with: navigationRoutes, startLegIndex: 0)
        }

        // After layout, sync the native mute button to the current mute state (its toggleMute:
        // action keys off isSelected) and observe taps to persist the value back to RN.
        DispatchQueue.main.async { [weak self, weak navigationViewController] in
            guard let self = self, let navVC = navigationViewController, self.isActive else { return }
            let muted = ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController.speechSynthesizer.muted
            guard let muteButton = self.findMuteButton(in: navVC) else {
                NSLog("[AudibleDirections] mute button NOT found")
                self.onMuteChange?(["isMuted": muted, "source": "setup-notfound"])
                return
            }
            muteButton.isSelected = muted
            muteButton.addTarget(self, action: #selector(self.muteButtonTapped(_:)), for: .touchUpInside)
            self.onMuteChange?(["isMuted": muted, "source": "setup"])
        }
    }
}
extension ExpoMapboxNavigationViewController: NavigationViewControllerDelegate {
    func navigationViewController(_ navigationViewController: NavigationViewController, didRerouteAlong route: Route) {
        // Only dispatch events if this instance is still active
        guard isActive else { return }

        onRoutesLoaded?([
            "routes": [
                "mainRoute": convertRoute(route: route),
                "alternativeRoutes": []
            ]
        ])
    }

    func navigationViewControllerDidDismiss(
        _ navigationViewController: NavigationViewController,
        byCanceling canceled: Bool
    ) { }
}

extension UIView {
    func findViews<T: UIView>(subclassOf: T.Type) -> [T] {
        return recursiveSubviews.compactMap { $0 as? T }
    }

    var recursiveSubviews: [UIView] {
        return subviews + subviews.flatMap { $0.recursiveSubviews }
    }
}
