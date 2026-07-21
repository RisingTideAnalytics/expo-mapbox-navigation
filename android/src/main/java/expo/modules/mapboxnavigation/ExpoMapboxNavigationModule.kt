package expo.modules.mapboxnavigation

import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.mapbox.common.TileStore
import com.mapbox.geojson.Point
import com.mapbox.navigation.base.options.NavigationOptions
import com.mapbox.navigation.base.options.RoutingTilesOptions
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class ExpoMapboxNavigationModule : Module() {
  private val activity
    get() = requireNotNull(appContext.activityProvider?.currentActivity)

  // A single shared TileStore backs both the Nav SDK's routing tiles (via RoutingTilesOptions
  // below) and the Maps SDK display tiles / offline downloads, so offline routing and the base map
  // read from the same on-device store (MOB-383).
  private val sharedTileStore: TileStore by lazy { TileStore.create() }
  private val offlineTileManager by lazy { OfflineTileManager(sharedTileStore) }

  @com.mapbox.navigation.base.ExperimentalPreviewMapboxNavigationAPI
  override fun definition() = ModuleDefinition {
    Name("ExpoMapboxNavigation")

    OnActivityEntersForeground {
      (activity as LifecycleOwner).lifecycleScope.launch(Dispatchers.Main) {
        if (!MapboxNavigationApp.isSetup()) {
          MapboxNavigationApp.setup {
            NavigationOptions.Builder(activity.applicationContext)
              .routingTilesOptions(
                RoutingTilesOptions.Builder().tileStore(sharedTileStore).build()
              )
              .build()
          }
        }
        MapboxNavigationApp.attach(activity as LifecycleOwner)
      }
    }

    // Offline tile pre-download API (MOB-383). Module-level (not view) because downloads run on the
    // prep screen before any ExpoMapboxNavigationView is mounted.
    Events("onOfflineProgress", "onOfflineComplete", "onOfflineError")

    AsyncFunction("downloadOfflineRegion") { options: Map<String, Any?>, promise: Promise ->
      val regionId = options["regionId"] as? String
      val geometry = options["geometry"] as? Map<*, *>
      @Suppress("UNCHECKED_CAST")
      val coordinates = geometry?.get("coordinates") as? List<List<List<Double>>>
      val styleURL = options["styleURL"] as? String
      if (regionId == null || coordinates == null || styleURL == null) {
        promise.reject("ERR_OFFLINE_ARGS", "Missing or invalid offline region options", null)
        return@AsyncFunction
      }
      val minZoom = (options["minZoom"] as? Number)?.toInt() ?: 7
      val maxZoom = (options["maxZoom"] as? Number)?.toInt() ?: 15

      (activity as LifecycleOwner).lifecycleScope.launch(Dispatchers.Main) {
        offlineTileManager.downloadRegion(
          regionId,
          coordinates,
          styleURL,
          minZoom,
          maxZoom,
          { rid, stage, completed, required ->
            sendEvent(
              "onOfflineProgress",
              mapOf(
                "regionId" to rid,
                "stage" to stage,
                "completedResourceCount" to completed,
                "requiredResourceCount" to required
              )
            )
          },
          { error ->
            if (error != null) {
              sendEvent("onOfflineError", mapOf("regionId" to regionId, "message" to error))
              promise.reject("ERR_OFFLINE_DOWNLOAD", error, null)
            } else {
              sendEvent("onOfflineComplete", mapOf("regionId" to regionId))
              promise.resolve(mapOf("regionId" to regionId))
            }
          }
        )
      }
    }

    AsyncFunction("removeOfflineRegion") { regionId: String, styleURL: String?, promise: Promise ->
      offlineTileManager.removeRegion(regionId, styleURL) { promise.resolve(null) }
    }

    AsyncFunction("getOfflineRegions") { promise: Promise ->
      offlineTileManager.listRegions { regions -> promise.resolve(regions) }
    }

    View(ExpoMapboxNavigationView::class) {
      Events(
              "onRouteProgressChanged",
              "onCancelNavigation",
              "onWaypointArrival",
              "onFinalDestinationArrival",
              "onRouteChanged",
              "onUserOffRoute",
              "onRoutesLoaded",
              "onRouteFailedToLoad",
              "onLocationChange",
              "onMuteChange"
      )

      Prop("coordinates") { view: ExpoMapboxNavigationView, coordinates: List<Map<String, Any>> ->
        val points = mutableListOf<Point>()
        for (coordinate in coordinates) {
          val longValue = coordinate.get("longitude")
          val latValue = coordinate.get("latitude")
          if (longValue is Double && latValue is Double) {
            points.add(Point.fromLngLat(longValue, latValue))
          }
        }
        view.setCoordinates(points)
      }

      Prop("vehicleMaxHeight") { view: ExpoMapboxNavigationView, maxHeight: Double? ->
        view.setVehicleMaxHeight(maxHeight)
      }

      Prop("vehicleMaxWidth") { view: ExpoMapboxNavigationView, maxWidth: Double? ->
        view.setVehicleMaxWidth(maxWidth)
      }

      Prop("vehicleMaxWeight") { view: ExpoMapboxNavigationView, maxWeight: Double? ->
        view.setVehicleMaxWeight(maxWeight)
      }

      Prop("allowsArrivingOnOppositeSide") { view: ExpoMapboxNavigationView, allows: Boolean? ->
        view.setAllowsArrivingOnOppositeSide(allows)
      }

      Prop("showsEndOfRouteFeedback") { view: ExpoMapboxNavigationView, shows: Boolean? ->
        view.setShowsEndOfRouteFeedback(shows)
      }

      Prop("hideTripProgress") { view: ExpoMapboxNavigationView, hide: Boolean? ->
        view.setHideTripProgress(hide)
      }

      Prop("waypointIndices") { view: ExpoMapboxNavigationView, indices: List<Int>? ->
        view.setWaypointIndices(indices)
      }

      Prop("locale") { view: ExpoMapboxNavigationView, localeStr: String? ->
        view.setLocale(localeStr)
      }

      Prop("useRouteMatchingApi") { view: ExpoMapboxNavigationView, useRouteMatchingApi: Boolean? ->
        view.setIsUsingRouteMatchingApi(useRouteMatchingApi)
      }

      Prop("routeProfile") { view: ExpoMapboxNavigationView, profile: String? ->
        view.setRouteProfile(profile)
      }

      Prop("routeExcludeList") { view: ExpoMapboxNavigationView, excludeList: List<String>? ->
        view.setRouteExcludeList(excludeList)
      }

      Prop("mapStyle") { view: ExpoMapboxNavigationView, style: String? -> view.setMapStyle(style) }

      Prop("mute") { view: ExpoMapboxNavigationView, isMuted: Boolean? -> view.setIsMuted(isMuted) }

      Prop("initialLocation") { view: ExpoMapboxNavigationView, initialLocation: Map<String, Any>?
        ->
        val longValue = initialLocation?.get("longitude")
        val latValue = initialLocation?.get("latitude")
        val zoomValue = initialLocation?.get("zoom")

        if (longValue is Double && latValue is Double && zoomValue is Double?) {
          view.setInitialLocation(Point.fromLngLat(longValue, latValue), zoomValue)
        }
      }

      Prop("customRasterSourceUrl") { view: ExpoMapboxNavigationView, url: String? ->
        view.setCustomRasterSourceUrl(url)
      }

      Prop("placeCustomRasterLayerAbove") { view: ExpoMapboxNavigationView, layerId: String? ->
        view.setPlaceCustomRasterLayerAbove(layerId)
      }

      Prop("disableAlternativeRoutes") {
              view: ExpoMapboxNavigationView,
              disableAlternativeRoutes: Boolean? ->
        view.setDisableAlternativeRoutes(disableAlternativeRoutes)
      }

      Prop("followingZoom") { view: ExpoMapboxNavigationView, followingZoom: Double? ->
        view.setFollowingZoom(followingZoom)
      }

      AsyncFunction("recenterMap") { view: ExpoMapboxNavigationView -> view.recenterMap() }
    }
  }
}
