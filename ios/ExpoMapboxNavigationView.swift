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
        // Non-white so the async style load can't flash white; controller repaints per uiStyle later.
        backgroundColor = ExpoMapboxNavigationViewController.nightBackdropColor
        isOpaque = true
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

    // MapboxNavigationProvider.routeVoiceController is COMPUTED, not lazily stored: its getter
    // calls RouteVoiceController.init(routeProgressing:...) and TTSConfig.speechSynthesizer(...),
    // so every access hands back a brand-new controller wrapping a brand-new synthesizer. (Verified
    // against the vendored binary: the getter's callees include those two inits, and there is no
    // $__lazy_storage_$_routeVoiceController symbol.)
    //
    // Every use in this file assumes the opposite — a stable singleton — so reading the provider
    // property directly was wrong four different ways: setIsMuted muted a throwaway that was
    // released moments later (so the `mute` prop never reached the speaking instance), the two
    // `.muted` reads always saw a fresh instance's default of false, and each navigation session
    // handed its NavigationViewController a different synthesizer while the outgoing session's
    // synthesizer stayed alive until its view controller deallocated — two owners of one
    // AVAudioSession, which is the shape of "voice worked on the first leg and went silent on the
    // second" (MOB-414).
    //
    // Access the provider property exactly once and share the result. The publishers it subscribes
    // to are provider-level, not trip-session-level, so one instance keeps working across the
    // setToIdle/startActiveGuidance cycle that each new leg performs.
    @MainActor static let sharedVoiceController: RouteVoiceController =
        ExpoMapboxNavigationViewController.navigationProvider.routeVoiceController

    // The provider and its trip session are shared across instances, so a starting controller must
    // tear down the previous owner or two controllers drive one session. weak to not retain it.
    static weak var activeController: ExpoMapboxNavigationViewController? = nil

    // Painted under the map so the style-load / handoff gap reads dark/light instead of white.
    static let nightBackdropColor = UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
    static let dayBackdropColor = UIColor(red: 0.90, green: 0.90, blue: 0.91, alpha: 1.0)

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

    // Our own recenter control. The drop-in UI already has one — NavigationView.resumeButton — but
    // NavigationViewLayout pins it bottom-leading, ~10pt above bottomBannerContainerView, which is
    // exactly where a host app's bottom sheet sits. In GroundSwell the TBT overlay covers it, so
    // once the driver taps overview there is no visible way back to the following camera (MOB-414).
    // hideTripProgress does not help: it hides the bottom banner without removing the pill's
    // constraint. MapOrnamentPosition offers only .topLeading/.topTrailing, so the pill cannot be
    // relocated — hence a button of our own in the floating stack, mirroring Android's
    // MapboxRecenterButton (android/.../ExpoMapboxNavigationView.kt:244).
    private var recenterButton: FloatingButton? = nil
    private var cameraStateCancellable: AnyCancellable? = nil
    // The camera reports .idle from construction until guidance yields a first fix, so an .idle
    // seen before the first .following is startup, not a user pan. Latching .following is what
    // keeps the button from flashing on every route load and reroute.
    private var hasEnteredFollowingCamera: Bool = false

    // The drop-in UI's own mute button, resolved by findMuteButton at setup. weak because it belongs
    // to the per-leg NavigationViewController; we hold it only to keep isSelected in step with the
    // real muted state and to drop our target on teardown.
    private weak var muteButton: UIButton? = nil
    // The last muted value this controller either applied from the `mute` prop or reported to JS,
    // mirroring Android's `isMuted` field (android/.../ExpoMapboxNavigationView.kt:124). nil until
    // the first observation so the progress watchdog can adopt a baseline without emitting.
    private var lastReportedMuted: Bool? = nil

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
                    "isMuted": ExpoMapboxNavigationViewController.sharedVoiceController.speechSynthesizer.muted,
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
        cameraStateCancellable?.cancel()

        // Nil out the cancellables
        routeProgressCancellable = nil
        waypointArrivalCancellable = nil
        reroutingCancellable = nil
        sessionCancellable = nil
        locationCancellable = nil
        cameraStateCancellable = nil
        hasEnteredFollowingCamera = false

        // Clear ownership synchronously so an incoming controller sees no owner; the UIKit/session
        // teardown must hop to the main actor (deinit is nonisolated), so it's async best-effort —
        // the real single-session guarantee is teardownForHandoff() before startActiveGuidance.
        let session = tripSession
        let navVC = navigationViewController
        // UIControl holds targets unowned, so this must be dropped on the main actor before the
        // button can outlive us. Captured like navVC because deinit is nonisolated.
        let button = recenterButton
        recenterButton = nil
        // Synchronously, unlike recenterButton below: removeTarget needs `self`, which an escaping
        // closure in a deinit cannot capture. It is a cheap UIKit call and every release path here
        // runs on main (the RN view unmounts on main), so doing it inline is both simpler and safe.
        teardownMuteButton()
        if ExpoMapboxNavigationViewController.activeController === self {
            ExpoMapboxNavigationViewController.activeController = nil
        }
        DispatchQueue.main.async {
            // Re-check ownership here rather than a captured flag: a replacement controller can take
            // over the shared session between deinit and this closure, and idling it would stop its
            // just-started guidance. nil owner means nobody's using it, so it's safe to idle.
            if ExpoMapboxNavigationViewController.activeController == nil {
                session?.setToIdle()
            }
            button?.removeTarget(nil, action: nil, for: .allEvents)
            // Per-instance, so always safe to remove (unlike the shared session above).
            if let navVC = navVC {
                navVC.delegate = nil
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
        // If a handoff tore our navigation down while hidden, rebuild it now we're visible again —
        // otherwise the view would show only its backdrop until the next prop change.
        if navigationViewController == nil && currentCoordinates != nil {
            update()
        }
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
        // This must be called on main thread.
        // Only idle the shared session if we still own it, or we kill a newer controller's guidance.
        if ExpoMapboxNavigationViewController.activeController === self {
            tripSession?.setToIdle()
            ExpoMapboxNavigationViewController.activeController = nil
        }

        // Per-instance, always safe.
        teardownRecenterButton()
        if let navVC = navigationViewController {
            navVC.delegate = nil
            navVC.willMove(toParent: nil)
            navVC.view.removeFromSuperview()
            navVC.removeFromParent()
        }
        navigationViewController = nil
    }

    // Lets an incoming controller start without a second session/VC coexisting. Doesn't idle the
    // shared session — the incoming startActiveGuidance resets it.
    func teardownForHandoff() {
        isActive = false
        // Invalidate in-flight route work so a stale result can't retake the shared session when this
        // view later reappears and reactivates. Bump the generation only — do NOT cancel the task: the
        // request must run to completion or MapboxNavigationCore leaks its continuation (crash). The
        // bumped generation makes the awaited result and any queued delayed setup fail their guards.
        routeRequestGeneration += 1
        teardownRecenterButton()
        teardownMuteButton()
        if let navVC = navigationViewController {
            navVC.delegate = nil
            navVC.willMove(toParent: nil)
            navVC.view.removeFromSuperview()
            navVC.removeFromParent()
        }
        navigationViewController = nil
        if ExpoMapboxNavigationViewController.activeController === self {
            ExpoMapboxNavigationViewController.activeController = nil
        }
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        fatalError("This controller should not be loaded through a story board")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // No map surface yet — paint the container so it isn't white.
        view.backgroundColor = backdropColor()
        view.isOpaque = true
    }

    // Never pure white, so the style-load gap is unobtrusive.
    private func backdropColor() -> UIColor {
        return currentUIStyle == "night"
            ? ExpoMapboxNavigationViewController.nightBackdropColor
            : ExpoMapboxNavigationViewController.dayBackdropColor
    }

    // Every layer that can show through before the style loads needs painting, not just one.
    private func applyBackdropColor() {
        let color = backdropColor()
        view.backgroundColor = color
        view.isOpaque = true
        if let navigationMapView = navigationViewController?.navigationMapView {
            navigationMapView.backgroundColor = color
            navigationMapView.mapView.backgroundColor = color
        }
    }

    func setUIStyle(style: String?) {
        currentUIStyle = style
        // Resync so a mid-session day/night switch can't flash.
        applyBackdropColor()
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
        guard let isMuted = isMuted else { return }
        applyMuted(isMuted)
    }

    /// The single entry point for the muted state, like Android's applyMuteState
    /// (android/.../ExpoMapboxNavigationView.kt:1086). Keeps the three things that can drift apart in
    /// step: the shared synthesizer that actually speaks, the SDK button's isSelected (which its own
    /// toggleMute: reads and inverts, and which drives its selectedImage), and the baseline the
    /// progress watchdog compares against. Main-thread by construction: Expo prop setters run there
    /// and sharedVoiceController is @MainActor.
    private func applyMuted(_ muted: Bool) {
        ExpoMapboxNavigationViewController.sharedVoiceController.speechSynthesizer.muted = muted
        muteButton?.isSelected = muted
        lastReportedMuted = muted
    }

    /// Every onMuteChange goes through here, so an emit can never leave lastReportedMuted behind.
    /// Stamped before the dispatch, which is what keeps the watchdog from re-reporting its own event.
    private func emitMuteChange(_ muted: Bool, source: String) {
        lastReportedMuted = muted
        onMuteChange?(["isMuted": muted, "source": source])
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
                onRoutesCalculated(navigationRoutes: navigationRoutes, generation: generation)
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
                onRoutesCalculated(navigationRoutes: navigationRoutes, generation: generation)
            }
        }
    }

    @objc func cancelButtonClicked(_ sender: AnyObject?) {
        onCancelNavigation?()
    }

    @objc func muteButtonTapped(_ sender: AnyObject?) {
        guard let button = sender as? UIButton else { return }
        // OrnamentsController.toggleMute(_:) does `sender.isSelected = !sender.isSelected`
        // SYNCHRONOUSLY — isSelected / setSelected: / isSelected msgSends at the top of the method —
        // and defers only the speechSynthesizer.muted write to a @MainActor Task. So the settled
        // value is already on the button and there is nothing to wait 0.35s for; that delay was
        // guessing at the Task hop, and it reported a stale value on a double tap.
        //
        // One main-queue turn rather than zero because UIKit does not document the order in which it
        // invokes a control's targets, so this reads correctly whether the SDK's registration fires
        // before or after ours.
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self = self, let button = button, self.isActive else { return }
            let muted = button.isSelected
            NSLog("[AudibleDirections] mute tap -> isMuted=\(muted)")
            // Idempotent with the SDK's own deferred write of the same value, but it keeps audio
            // correct if a future SDK stops routing toggleMute: through the voice controller we hand
            // it in NavigationOptions. Also stamps the baseline ahead of the emit.
            self.applyMuted(muted)
            self.emitMuteChange(muted, source: "tap")
        }
    }

    @objc func recenterButtonTapped(_ sender: AnyObject?) {
        recenterMap()
    }

    // Adds a recenter button to the drop-in UI's floating stack, and neutralizes the SDK's own
    // resume pill (which is stranded under the host app's bottom sheet). See recenterButton.
    @MainActor
    private func installRecenterButton(in navVC: NavigationViewController) {
        // rounded() is generic over T: FloatingButton, so the result type has to be annotated.
        // An SF Symbol keeps this free of a resource bundle: the pod declares no resources, and
        // it is a static framework, so reaching the SDK's own `recenter` asset would mean
        // hard-coding an SPM-generated bundle name that can change on any SDK bump.
        let symbol = UIImage(
            systemName: "location.north.line.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        ) ?? UIImage(systemName: "location.fill")
        let button: FloatingButton = FloatingButton.rounded(image: symbol)
        button.accessibilityLabel = NSLocalizedString(
            "RESUME",
            value: "Resume",
            comment: "Return the camera to following the user's location"
        )
        button.accessibilityIdentifier = "expo.mapbox.recenterButton"
        // Start hidden, like Android's initial GONE: the camera is .idle until guidance produces a
        // first fix, and a visible button in that window reads as a flash on every route load.
        button.isHidden = true
        button.addTarget(self, action: #selector(recenterButtonTapped(_:)), for: .touchUpInside)
        // No explicit colors: FloatingButton picks up backgroundColor/tintColor/border from the
        // Day/NightStyle appearance proxy, which is class-level and so covers our instance too.
        recenterButton = button

        // floatingButtons is a *stored* [UIButton]? whose didSet rebuilds floatingStackView, and it
        // is assigned exactly once, in NavigationViewController.loadView(), as
        // [overviewButton, muteButton, reportButton]. A read-modify-write is therefore lossless:
        // the VC holds those three as lazy strong refs, and addTarget state lives on each UIControl
        // instance rather than on the stack view, so the clear-and-re-add preserves them.
        // Index 0 matters: the SDK hides overviewButton in .overview/.idle, so the compass lands in
        // the slot overview vacates. The stack never changes height and nothing shifts.
        if var buttons = navVC.floatingButtons {
            buttons.insert(button, at: 0)
            navVC.floatingButtons = buttons
        } else {
            NSLog("[Recenter] floatingButtons was nil; installing compass alone")
            navVC.floatingButtons = [button]
        }

        // The SDK's resume pill is unreachable under the host's bottom sheet and can tint through
        // its blur. alpha, not isHidden: OrnamentsController rewrites isHidden on every transition
        // to .idle/.overview, but never touches alpha.
        if let resume = navVC.navigationView.findViews(subclassOf: ResumeButton.self).first {
            resume.alpha = 0
            resume.isUserInteractionEnabled = false
        } else {
            NSLog("[Recenter] SDK ResumeButton not found; nothing to suppress")
        }

        observeCameraState(navVC)
    }

    // Wires the drop-in UI's own mute button: syncs its isSelected to the real muted state and
    // observes taps. Kept separate from the emit so the wiring can run synchronously at setup.
    @MainActor
    private func installMuteButton(in navVC: NavigationViewController) {
        guard let button = findMuteButton(in: navVC) else { return }
        muteButton = button
        // toggleMute: inverts the *current* isSelected, and the button carries a distinct
        // selectedImage. So a persisted mute=true against an unselected button showed the unmuted
        // icon and made the driver's first tap an audible no-op. This line is that half of MOB-415.
        button.isSelected = ExpoMapboxNavigationViewController.sharedVoiceController.speechSynthesizer.muted
        button.addTarget(self, action: #selector(muteButtonTapped(_:)), for: .touchUpInside)
    }

    @MainActor
    private func observeCameraState(_ navVC: NavigationViewController) {
        cameraStateCancellable?.cancel()
        hasEnteredFollowingCamera = false
        guard let camera = navVC.navigationMapView?.navigationCamera else {
            NSLog("[Recenter] no navigationCamera to observe")
            return
        }
        // No .receive(on:): NavigationCamera is @MainActor, so emissions already arrive on main —
        // same convention as the other sinks in this file. No view.window check either, unlike
        // those: this is an idempotent UI write that dispatches no event, and skipping updates
        // while offscreen would leave the button stale when the view comes back.
        cameraStateCancellable = camera.cameraStates.sink { [weak self] state in
            guard let self = self, self.isActive, let button = self.recenterButton else { return }
            switch state {
            case .following:
                self.hasEnteredFollowingCamera = true
                button.isHidden = true
            case .overview:
                button.isHidden = false
            case .idle:
                // cameraStates replays on subscribe and we install before startActiveGuidance, so
                // the first value is a construction-time .idle. Only once we have actually followed
                // does .idle mean the driver panned away. (.dropFirst() would break if the
                // publisher ever stopped replaying.)
                button.isHidden = !self.hasEnteredFollowingCamera
            @unknown default:
                // Non-frozen enum across a library-evolution module boundary: a future state we
                // don't know about is safest treated as "not following", i.e. offer the way back.
                button.isHidden = !self.hasEnteredFollowingCamera
            }
        }
    }

    private func teardownRecenterButton() {
        cameraStateCancellable?.cancel()
        cameraStateCancellable = nil
        hasEnteredFollowingCamera = false
        // UIControl holds its targets unowned, so a target left behind would dangle if the button
        // ever outlived this controller. Cheap enough to do unconditionally.
        recenterButton?.removeTarget(nil, action: nil, for: .allEvents)
        recenterButton = nil
    }

    private func teardownMuteButton() {
        // removeTarget(self, ...) — NOT nil. Unlike recenterButton this button is the SDK's and still
        // carries OrnamentsController's toggleMute: registration; nil means "every target" and would
        // rip out the SDK's own mute handling, reproducing MOB-415 from the other direction.
        muteButton?.removeTarget(self, action: nil, for: .allEvents)
        muteButton = nil
    }

    // MARK: - Mute button discovery
    //
    // The drop-in UI's mute button is `NavigationViewController.muteButton`, an *internal*
    // `lazy var muteButton: FloatingButton`. It appears in neither the public nor the private
    // .swiftinterface, and its getter and method descriptor are file-local symbols, so there is no
    // compile-time and no dlsym route to it. Everything below is reflective by necessity.
    //
    // Verified against the vendored MapboxNavigationUIKit 3.8 arm64 binary:
    //  * Field descriptor _$s21MapboxNavigationUIKit0B14ViewControllerCMF lists 28 fields; #8 is
    //    `$__lazy_storage_$_muteButton: Optional<FloatingButton>`, and that name lives in
    //    __swift5_reflstr — i.e. Swift reflection metadata is present and Mirror can see it.
    //    MapboxNavigationUIKit is a *dynamic* framework (s.static_framework applies to our pod, not
    //    to the vendored xcframeworks), so app-link dead-stripping cannot remove those sections.
    //  * The same name exists as an Objective-C ivar, but every ivar on that class points its type
    //    encoding at the empty string: Swift-native (non-@objc) stored properties emit no encoding.
    //    That is why the previous ivar_getTypeEncoding hasPrefix("@") gate could never fire and this
    //    always fell through to "setup-notfound" (MOB-415). Relaxing the gate is not the fix — an
    //    empty encoding says nothing about object-vs-value, so object_getIvar could hand a
    //    bit-packed Bool to a dynamic cast. Mirror reaches the same storage type-safely.
    //  * The buttons carry no accessibilityLabel. The SDK's only MUTE/UNMUTE strings are
    //    CARPLAY_MUTE / CARPLAY_UNMUTE, consumed by CarPlayManager's CPBarButton.
    //  * The tap action is -[OrnamentsController toggleMute:], registered for .touchUpInside
    //    (w4 = 0x40) in OrnamentsController.navigationViewDidLoad(_:) — which is what layer 2 keys
    //    off, and which also proves the button exists from viewDidLoad onward.

    /// Labels the Mirror walk is allowed to descend into. An allow-list, not a blind deep walk:
    /// reflecting the whole view-controller graph would wander into the view hierarchy and every
    /// Combine subscription the SDK holds. OrnamentsController has no button of its own today (its
    /// four fields are navigationViewData/eventsManager/subscriptions/showsSpeedLimits) — this is
    /// purely so a future SDK that moves the button there still resolves.
    private static let muteBridgeLabels = ["ornamentsController", "navigationViewData", "navigationView"]

    private func findMuteButton(in navVC: NavigationViewController) -> UIButton? {
        if let b = muteButtonViaMirror(navVC) {
            NSLog("[AudibleDirections] mute button via mirror class=\(String(describing: type(of: b)))")
            return b
        }
        if let b = muteButtonViaTargetAction(in: navVC) {
            NSLog("[AudibleDirections] mute button via target-action class=\(String(describing: type(of: b)))")
            return b
        }
        if let b = muteButtonViaAccessibilityLabel(in: navVC) {
            NSLog("[AudibleDirections] mute button via accessibilityLabel=\(b.accessibilityLabel ?? "nil")")
            return b
        }
        return nil
    }

    /// Depth-limited Mirror walk for a stored property whose name contains "muteButton".
    /// Mirror.children is lazily computed for classes, so a hit at field #8 never materializes the
    /// remaining 19 fields of NavigationViewController.
    private func muteButtonViaMirror(_ root: Any, depth: Int = 0) -> UIButton? {
        guard depth <= 2 else { return nil }
        var bridges: [Any] = []
        var mirror: Mirror? = Mirror(reflecting: root)
        while let m = mirror {
            for child in m.children {
                guard let label = child.label else { continue }
                if label.contains("muteButton"), let button = unwrapButton(child.value) {
                    return button
                }
                if ExpoMapboxNavigationViewController.muteBridgeLabels.contains(where: { label.contains($0) }) {
                    bridges.append(child.value)
                }
            }
            // NavigationViewController's superclass is UIViewController, which reflects with zero
            // children, so this terminates immediately today. Walked anyway in case the SDK ever
            // inserts a Swift intermediate class.
            mirror = m.superclassMirror
        }
        for bridge in bridges {
            if let button = muteButtonViaMirror(unwrapOptional(bridge), depth: depth + 1) { return button }
        }
        return nil
    }

    /// Mirror hands back the *storage*, so `lazy var muteButton: FloatingButton` arrives as an `Any`
    /// boxing `Optional<FloatingButton>`. A conditional cast out of `Any` already unwraps one level
    /// of Optional, so the first line normally suffices; the Mirror unwrap is insurance for a future
    /// SDK declaring the storage `weak`, which reflects as a further-nested optional.
    /// CarPlayNavigationViewController has a same-named field typed CPBarButton; the cast rejects it.
    private func unwrapButton(_ value: Any) -> UIButton? {
        if let b = value as? UIButton { return b }
        let m = Mirror(reflecting: value)
        guard m.displayStyle == .optional, let inner = m.children.first?.value else { return nil }
        return inner as? UIButton
    }

    /// Unwraps one level of Optional, or returns the value unchanged. Deliberately not `as? AnyObject`:
    /// on Darwin that succeeds for anything by boxing, including Optional.none, which would send the
    /// walk chasing an empty _SwiftValue box.
    private func unwrapOptional(_ value: Any) -> Any {
        let m = Mirror(reflecting: value)
        guard m.displayStyle == .optional else { return value }
        return m.children.first?.value ?? value
    }

    /// Identifies the button by behaviour rather than by storage, which is the more durable of the
    /// two: a selector name survives SDK refactors that rename or relocate a stored property.
    private func muteButtonViaTargetAction(in navVC: NavigationViewController) -> UIButton? {
        for button in floatingCandidates(in: navVC) {
            // Ours has no mute action, but skipping it keeps the failure dump honest.
            if button === recenterButton { continue }
            for target in targets(of: button) {
                for event: UIControl.Event in [.touchUpInside, .primaryActionTriggered] {
                    // NSArray<NSString *> -> [String]?, a plain array bridge with no hashing.
                    // Always an explicit target, never nil: nil-means-all is documented for
                    // removeTarget:, not for actionsForTarget:, which matches only nil-target
                    // registrations.
                    let actions = button.actions(forTarget: target, forControlEvent: event) ?? []
                    if actions.contains(where: { $0.lowercased().contains("mute") }) { return button }
                }
            }
        }
        return nil
    }

    /// `UIControl.allTargets` is typed `Set<AnyHashable>` in Swift; materializing it forces an
    /// AnyHashable box and a Hashable conformance lookup per target, which is what crashed here
    /// before. Invoke the Objective-C selector and stay in NSSet, which enumerates without hashing.
    /// `allTargets` is public API — only the dispatch is dynamic.
    private func targets(of control: UIControl) -> [AnyObject] {
        let sel = Selector(("allTargets"))
        guard control.responds(to: sel), let unmanaged = control.perform(sel) else { return [] }
        // Not an alloc/new/copy/mutableCopy-family selector, so the NSSet comes back autoreleased and
        // takeUnretainedValue is correct; the `as? NSSet` binding retains it for our scope.
        guard let set = unmanaged.takeUnretainedValue() as? NSSet else { return [] }
        var out: [AnyObject] = []
        for element in set {
            // allTargets can hold NSNull standing in for a nil target.
            if element is NSNull { continue }
            out.append(element as AnyObject)
        }
        return out
    }

    /// Third layer. Dead for the phone skin on SDK 3.8 (see the note above), but it costs nothing and
    /// would start working the day Mapbox labels these buttons.
    private func muteButtonViaAccessibilityLabel(in navVC: NavigationViewController) -> UIButton? {
        let muteLabels: Set<String> = ["mute", "unmute"]
        return floatingCandidates(in: navVC).first {
            guard let label = $0.accessibilityLabel?.lowercased() else { return false }
            return muteLabels.contains(label)
        }
    }

    private func floatingCandidates(in navVC: NavigationViewController) -> [UIButton] {
        var candidates: [UIButton] = navVC.navigationView.floatingStackView.arrangedSubviews
            .compactMap { $0 as? UIButton }
        if let fb = navVC.navigationView.floatingButtons {
            for b in fb where !candidates.contains(where: { $0 === b }) { candidates.append(b) }
        }
        return candidates
    }

    /// Emitted once per leg, and only when every layer missed. This is what makes the next SDK bump
    /// diagnosable from a device log instead of from otool on the vendored binary: the child labels
    /// name the new storage, and the action lists name the new selector.
    private func logMuteButtonLookupFailure(_ navVC: NavigationViewController) {
        NSLog("[AudibleDirections] mute button NOT found — SDK layout changed?")
        var labels: [String] = []
        var mirror: Mirror? = Mirror(reflecting: navVC)
        while let m = mirror {
            labels.append(contentsOf: m.children.compactMap { $0.label })
            mirror = m.superclassMirror
        }
        NSLog("[AudibleDirections] navVC mirror children (\(labels.count)): \(labels.joined(separator: ","))")
        for (i, b) in floatingCandidates(in: navVC).enumerated() {
            let actions = targets(of: b)
                .flatMap { b.actions(forTarget: $0, forControlEvent: .touchUpInside) ?? [] }
                .joined(separator: "|")
            NSLog("[AudibleDirections] btn[\(i)] class=\(String(describing: type(of: b))) a11y=\(b.accessibilityLabel ?? "nil") actions=[\(actions)]")
        }
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

    func onRoutesCalculated(navigationRoutes: NavigationRoutes, generation: Int){
        // Guard every hop on the REQUEST's generation (passed in), never a re-read of the current
        // value: a handoff or newer request bumps it, so a result that started earlier is dropped
        // instead of adopting the new generation and reclaiming the session with stale routes.
        // Ensure we're on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isActive, generation == self.routeRequestGeneration else { return }

            // Don't idle the shared session if another controller owns it — that kills its guidance.
            if ExpoMapboxNavigationViewController.activeController == nil
                || ExpoMapboxNavigationViewController.activeController === self {
                self.tripSession?.setToIdle()
            }

            // Clean up existing navigation view controller if any
            self.teardownRecenterButton()
            if let existingNavVC = self.navigationViewController {
                existingNavVC.delegate = nil
                existingNavVC.willMove(toParent: nil)
                existingNavVC.view.removeFromSuperview()
                existingNavVC.removeFromParent()
                self.navigationViewController = nil
            }

            // Small delay to ensure previous session is fully cleaned up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, self.isActive, generation == self.routeRequestGeneration else { return }
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
            voiceController: ExpoMapboxNavigationViewController.sharedVoiceController,
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
        // Paint before the async loadStyle below, or the map is white until it resolves.
        applyBackdropColor()

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

        // Synchronous, not deferred: navigationView was touched above so loadView() has run (and
        // the floatingButtons accessor calls loadViewIfNeeded() itself), and doing it here avoids
        // the deferred-block hazard where a teardownForHandoff() lands first.
        installRecenterButton(in: navigationViewController)
        // Same reasoning, plus: the mute button and its toggleMute: target are created in
        // OrnamentsController.navigationViewDidLoad(_:), i.e. during the loadViewIfNeeded() the line
        // above already forced, so the lazy storage Mirror reads is populated by now and the lookup
        // does not need deferring. The deferred block below retries once in case a future SDK builds
        // it later (viewWillAppear, say).
        installMuteButton(in: navigationViewController)

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
            // Tear down the previous owner before starting, or two sessions coexist on the shared provider.
            if let previous = ExpoMapboxNavigationViewController.activeController, previous !== self {
                previous.teardownForHandoff()
            }
            ExpoMapboxNavigationViewController.activeController = self
            mapboxNavigation!.tripSession().startActiveGuidance(with: navigationRoutes, startLegIndex: 0)
        }

        // Deferred only for the two things that need it: the event, so JS has its handlers attached
        // by the time it lands, and a one-shot retry of the lookup. The wiring itself already ran
        // synchronously above.
        DispatchQueue.main.async { [weak self, weak navigationViewController] in
            guard let self = self, let navVC = navigationViewController, self.isActive else { return }
            if self.muteButton == nil { self.installMuteButton(in: navVC) }
            let muted = ExpoMapboxNavigationViewController.sharedVoiceController.speechSynthesizer.muted
            guard self.muteButton != nil else {
                self.logMuteButtonLookupFailure(navVC)
                self.emitMuteChange(muted, source: "setup-notfound")
                return
            }
            self.emitMuteChange(muted, source: "setup")
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
