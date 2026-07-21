import ExpoModulesCore
import CoreLocation

public class ExpoMapboxNavigationModule: Module {

  private lazy var offlineTileManager = ExpoMapboxNavigationOfflineManager()

  public func definition() -> ModuleDefinition {
    Name("ExpoMapboxNavigation")

    // Offline tile pre-download API (MOB-383). Module-level (not view) because downloads run on the
    // prep screen before any MapboxNavigationView is mounted.
    Events("onOfflineProgress", "onOfflineComplete", "onOfflineError")

    AsyncFunction("downloadOfflineRegion") { (options: [String: Any], promise: Promise) in
      guard
        let regionId = options["regionId"] as? String,
        let geometry = options["geometry"] as? [String: Any],
        let coordinates = geometry["coordinates"] as? [[[Double]]],
        let styleURL = options["styleURL"] as? String
      else {
        promise.reject("ERR_OFFLINE_ARGS", "Missing or invalid offline region options")
        return
      }
      // Clamp to a valid tile zoom range (0...22) before converting — UInt8(...) traps on a
      // negative or >255 value — and normalize order so minZoom <= maxZoom (a reversed range traps).
      let rawMinZoom = min(max((options["minZoom"] as? Int) ?? 7, 0), 22)
      let rawMaxZoom = min(max((options["maxZoom"] as? Int) ?? 15, 0), 22)
      let minZoom = UInt8(min(rawMinZoom, rawMaxZoom))
      let maxZoom = UInt8(max(rawMinZoom, rawMaxZoom))

      // Mapbox offline operations deliver their progress/completion callbacks on the initiating
      // thread's run loop; the Expo AsyncFunction closure runs on a transient background queue that
      // has none, so the callbacks would never fire. Run on the main queue (mirrors the Android side,
      // which dispatches to Dispatchers.Main).
      DispatchQueue.main.async {
        self.offlineTileManager.downloadRegion(
          regionId: regionId,
          geometryCoordinates: coordinates,
          styleURLString: styleURL,
          minZoom: minZoom,
          maxZoom: maxZoom,
          progress: { [weak self] (rid, stage, completed, required) in
            self?.sendEvent("onOfflineProgress", [
              "regionId": rid,
              "stage": stage,
              "completedResourceCount": Int(completed),
              "requiredResourceCount": Int(required),
            ])
          },
          completion: { [weak self] error in
            if let error {
              self?.sendEvent("onOfflineError", ["regionId": regionId, "message": error.localizedDescription])
              promise.reject("ERR_OFFLINE_DOWNLOAD", error.localizedDescription)
            } else {
              self?.sendEvent("onOfflineComplete", ["regionId": regionId])
              promise.resolve(["regionId": regionId])
            }
          }
        )
      }
    }

    AsyncFunction("removeOfflineRegion") { (regionId: String, styleURL: String?, promise: Promise) in
      DispatchQueue.main.async {
        self.offlineTileManager.removeRegion(regionId: regionId, styleURLString: styleURL) {
          promise.resolve(nil)
        }
      }
    }

    AsyncFunction("getOfflineRegions") { (promise: Promise) in
      DispatchQueue.main.async {
        self.offlineTileManager.listRegions { regions in
          promise.resolve(regions)
        }
      }
    }

    View(ExpoMapboxNavigationView.self) {
      Events("onRouteProgressChanged", "onCancelNavigation", "onWaypointArrival", "onFinalDestinationArrival", "onRouteChanged", "onUserOffRoute", "onRoutesLoaded", "onRouteFailedToLoad", "onLocationChange", "onMuteChange")

      Prop("coordinates") { (view: ExpoMapboxNavigationView, coordinates: Array<Dictionary<String, Any>>) in
         var points: Array<CLLocationCoordinate2D> = []
         for coordinate in coordinates {
            let longValue = coordinate["longitude"]
            let latValue = coordinate["latitude"]
            if let long = longValue as? Double, let lat = latValue as? Double {
                points.append(CLLocationCoordinate2D(latitude: lat, longitude: long))
            }
          }
          view.controller.setCoordinates(coordinates: points)
      }

      Prop("vehicleMaxHeight") { (view: ExpoMapboxNavigationView, maxHeight: Double?) in
          view.controller.setVehicleMaxHeight(maxHeight: maxHeight)
      }

      Prop("vehicleMaxWidth") { (view: ExpoMapboxNavigationView, maxWidth: Double?) in
          view.controller.setVehicleMaxWidth(maxWidth: maxWidth)
      }

      Prop("vehicleMaxWeight") { (view: ExpoMapboxNavigationView, maxWeight: Double?) in
          view.controller.setVehicleMaxWeight(maxWeight: maxWeight)
      }

      Prop("allowsArrivingOnOppositeSide") { (view: ExpoMapboxNavigationView, allows: Bool?) in
          view.controller.setAllowsArrivingOnOppositeSide(allows: allows)
      }

      Prop("showsEndOfRouteFeedback") { (view: ExpoMapboxNavigationView, shows: Bool?) in
          view.controller.setShowsEndOfRouteFeedback(shows: shows)
      }

      Prop("hideTripProgress") { (view: ExpoMapboxNavigationView, hide: Bool?) in
          view.controller.setHideTripProgress(hide: hide)
      }

      Prop("locale") { (view: ExpoMapboxNavigationView, locale: String?) in
          view.controller.setLocale(locale: locale)
      }

      Prop("useRouteMatchingApi"){ (view: ExpoMapboxNavigationView, useRouteMatchingApi: Bool?) in
          view.controller.setIsUsingRouteMatchingApi(useRouteMatchingApi: useRouteMatchingApi)
      }

      Prop("waypointIndices"){ (view: ExpoMapboxNavigationView, indices: Array<Int>?) in
          view.controller.setWaypointIndices(waypointIndices: indices)
      }

      Prop("routeProfile"){ (view: ExpoMapboxNavigationView, profile: String?) in
          view.controller.setRouteProfile(profile: profile)
      }

      Prop("routeExcludeList"){ (view: ExpoMapboxNavigationView, excludeList: Array<String>?) in
          view.controller.setRouteExcludeList(excludeList: excludeList)
      }

      Prop("mapStyle"){ (view: ExpoMapboxNavigationView, style: String?) in
          view.controller.setMapStyle(style: style)
      }

      Prop("mute"){ (view: ExpoMapboxNavigationView, isMuted: Bool?) in
          view.controller.setIsMuted(isMuted: isMuted)
      }

      Prop("initialLocation") { (view: ExpoMapboxNavigationView, location: Dictionary<String, Any>?) in
        if(location != nil){
          let longValue = location!["longitude"]
          let latValue = location!["latitude"]
          let zoomValue = location!["zoom"]
          if let long = longValue as? Double, let lat = latValue as? Double, let zoom = zoomValue as? Double? {
              view.controller.setInitialLocation(location: CLLocationCoordinate2D(latitude: lat, longitude: long), zoom: zoom)
          }
        }
      }

      Prop("customRasterSourceUrl") { (view: ExpoMapboxNavigationView, url: String?) in
        view.controller.setCustomRasterSourceUrl(url: url)
      }

      Prop("placeCustomRasterLayerAbove") { (view: ExpoMapboxNavigationView, layerId: String?) in
        view.controller.setPlaceCustomRasterLayerAbove(layerId: layerId)
      }

      Prop("disableAlternativeRoutes") { (view: ExpoMapboxNavigationView, disableAlternativeRoutes: Bool?) in
        view.controller.setDisableAlternativeRoutes(disableAlternativeRoutes: disableAlternativeRoutes)
      }

      Prop("followingZoom") { (view: ExpoMapboxNavigationView, followingZoom: Double?) in
        view.controller.setFollowingZoom(followingZoom: followingZoom)
      }

      Prop("uiStyle") { (view: ExpoMapboxNavigationView, uiStyle: String?) in
        view.controller.setUIStyle(style: uiStyle)
      }

      AsyncFunction("recenterMap") { (view: ExpoMapboxNavigationView) in
        view.controller.recenterMap()
      }
    }
  }
}
