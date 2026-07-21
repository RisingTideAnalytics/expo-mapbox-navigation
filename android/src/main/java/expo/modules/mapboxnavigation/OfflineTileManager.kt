package expo.modules.mapboxnavigation

import com.mapbox.bindgen.Value
import com.mapbox.common.NetworkRestriction
import com.mapbox.common.TileRegionLoadOptions
import com.mapbox.common.TileStore
import com.mapbox.common.TilesetDescriptor
import com.mapbox.geojson.Point
import com.mapbox.geojson.Polygon
import com.mapbox.maps.GlyphsRasterizationMode
import com.mapbox.maps.OfflineManager
import com.mapbox.maps.StylePackLoadOptions
import com.mapbox.maps.TilesetDescriptorOptions
import com.mapbox.navigation.base.ExperimentalPreviewMapboxNavigationAPI
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp

/**
 * Manages offline tile downloads for turn-by-turn navigation (MOB-383).
 *
 * A single tile region (keyed by `regionId`) carries BOTH the navigation routing tiles (via the Nav
 * SDK's tileset descriptor factory) and the map display tiles (via a Maps SDK tileset descriptor),
 * plus the style pack, into a shared [TileStore]. The same [TileStore] instance backs the Nav SDK's
 * `RoutingTilesOptions` (see [ExpoMapboxNavigationModule]) and the Maps SDK, so downloading into it
 * lets the onboard router compute directions and the base map render offline for the route region.
 *
 * NOTE: This targets the Mapbox Maps SDK v11 / Navigation SDK v3 offline API. Exact symbol
 * signatures must be confirmed against the pinned SDK at native build time.
 */
class OfflineTileManager(private val tileStore: TileStore) {
    private val offlineManager = OfflineManager()

    fun interface ProgressHandler {
        fun onProgress(regionId: String, stage: String, completed: Long, required: Long)
    }

    // Tile downloads authenticate with the global Mapbox access token (set by @rnmapbox/maps and the
    // config plugin at runtime via MapboxOptions.accessToken); the TileStore uses it automatically,
    // so no per-store token option is set here.

    private fun polygonFrom(coordinates: List<List<List<Double>>>): Polygon? {
        val outer = coordinates.firstOrNull() ?: return null
        val ring = outer.mapNotNull { pair ->
            if (pair.size >= 2) Point.fromLngLat(pair[0], pair[1]) else null
        }
        if (ring.size < 4) return null
        return Polygon.fromLngLats(listOf(ring))
    }

    @ExperimentalPreviewMapboxNavigationAPI
    fun downloadRegion(
        regionId: String,
        geometryCoordinates: List<List<List<Double>>>,
        styleUrl: String,
        minZoom: Int,
        maxZoom: Int,
        progress: ProgressHandler,
        onComplete: (error: String?) -> Unit
    ) {
        val geometry = polygonFrom(geometryCoordinates)
        if (geometry == null) {
            onComplete("Invalid geometry")
            return
        }

        // 1) Style pack (fonts/sprites/style JSON needed to render offline).
        val stylePackOptions = StylePackLoadOptions.Builder()
            .glyphsRasterizationMode(GlyphsRasterizationMode.IDEOGRAPHS_RASTERIZED_LOCALLY)
            .metadata(Value(regionId))
            .build()

        offlineManager.loadStylePack(
            styleUrl,
            stylePackOptions,
            { stylePackProgress ->
                progress.onProgress(
                    regionId,
                    "stylePack",
                    stylePackProgress.completedResourceCount,
                    stylePackProgress.requiredResourceCount
                )
            },
            { expected ->
                if (expected.isValue) {
                    loadTileRegion(regionId, geometry, styleUrl, minZoom, maxZoom, progress, onComplete)
                } else {
                    onComplete(expected.error?.message ?: "Style pack download failed")
                }
            }
        )
    }

    @ExperimentalPreviewMapboxNavigationAPI
    private fun loadTileRegion(
        regionId: String,
        geometry: Polygon,
        styleUrl: String,
        minZoom: Int,
        maxZoom: Int,
        progress: ProgressHandler,
        onComplete: (error: String?) -> Unit
    ) {
        val navigationDescriptor: TilesetDescriptor? =
            MapboxNavigationApp.current()?.tilesetDescriptorFactory?.getLatest()

        val mapsDescriptor = offlineManager.createTilesetDescriptor(
            TilesetDescriptorOptions.Builder()
                .styleURI(styleUrl)
                .minZoom(minZoom.toByte())
                .maxZoom(maxZoom.toByte())
                .build()
        )

        val descriptors = listOfNotNull(navigationDescriptor, mapsDescriptor)

        val loadOptions = TileRegionLoadOptions.Builder()
            .geometry(geometry)
            .descriptors(descriptors)
            .acceptExpired(true)
            .networkRestriction(NetworkRestriction.NONE)
            .metadata(Value(regionId))
            .build()

        tileStore.loadTileRegion(
            regionId,
            loadOptions,
            { tileProgress ->
                progress.onProgress(
                    regionId,
                    "routingTiles",
                    tileProgress.completedResourceCount,
                    tileProgress.requiredResourceCount
                )
            },
            { expected ->
                if (expected.isValue) {
                    onComplete(null)
                } else {
                    onComplete(expected.error?.message ?: "Tile region download failed")
                }
            }
        )
    }

    fun removeRegion(regionId: String, styleUrl: String?, onDone: () -> Unit) {
        tileStore.removeTileRegion(regionId)
        if (styleUrl != null) {
            offlineManager.removeStylePack(styleUrl)
        }
        onDone()
    }

    fun listRegions(onResult: (List<Map<String, Any>>) -> Unit) {
        tileStore.getAllTileRegions { expected ->
            if (expected.isValue) {
                val regions = expected.value?.map { region ->
                    mapOf(
                        "regionId" to region.id,
                        "completedResourceCount" to region.completedResourceCount,
                        "requiredResourceCount" to region.requiredResourceCount
                    )
                } ?: emptyList()
                onResult(regions)
            } else {
                onResult(emptyList())
            }
        }
    }
}
