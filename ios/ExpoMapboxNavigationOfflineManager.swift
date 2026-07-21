import Foundation
import MapboxMaps
import MapboxNavigationCore
import Turf

/// Manages offline tile downloads for turn-by-turn navigation (MOB-383).
///
/// A single tile region (keyed by `regionId`) carries BOTH the navigation routing tiles (via the
/// Nav SDK's latest tileset descriptor) and the map display tiles (via a Maps SDK tileset
/// descriptor), plus the style pack, into the shared default `TileStore`. Because the Nav SDK's
/// onboard router and the navigation `MapView` both read from `TileStore.default`, downloading into
/// it lets the driver compute directions and render the base map offline for the route's region.
///
/// NOTE: This targets the Mapbox Maps SDK v11 / Navigation SDK v3 offline API. Exact symbol
/// signatures must be confirmed against the pinned SDK at native build time.
class ExpoMapboxNavigationOfflineManager {
    typealias ProgressHandler = (_ regionId: String, _ stage: String, _ completed: UInt64, _ required: UInt64) -> Void

    private let tileStore: TileStore
    private let offlineManager: OfflineManager

    // In-flight download cancelables, keyed by regionId, so a superseded/aborted download can stop.
    private var activeDownloads: [String: [Cancelable]] = [:]

    init() {
        self.tileStore = TileStore.default
        self.offlineManager = OfflineManager()
        // Tile downloads authenticate with the global Mapbox access token (set via the Info.plist
        // MBXAccessToken / @rnmapbox/maps at runtime); the TileStore uses it automatically.
    }

    /// Build a Turf polygon geometry from a GeoJSON-style coordinate ring array ([[[lng, lat], …]]).
    private static func polygonGeometry(from coordinates: [[[Double]]]) -> Geometry? {
        guard let outerRing = coordinates.first else { return nil }
        let points = outerRing.compactMap { pair -> LocationCoordinate2D? in
            guard pair.count >= 2 else { return nil }
            return LocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
        guard points.count >= 4 else { return nil }
        return .polygon(Polygon([points]))
    }

    /// Download routing + display tiles + style pack for `regionId`. Calls `progress` as tiles load,
    /// then `completion(nil)` on success or `completion(error)` on failure.
    func downloadRegion(
        regionId: String,
        geometryCoordinates: [[[Double]]],
        styleURLString: String,
        minZoom: UInt8,
        maxZoom: UInt8,
        progress: @escaping ProgressHandler,
        completion: @escaping (Error?) -> Void
    ) {
        guard let geometry = Self.polygonGeometry(from: geometryCoordinates) else {
            completion(OfflineTileError.invalidGeometry)
            return
        }
        let styleURI = StyleURI(rawValue: styleURLString) ?? .streets

        // 1) Style pack (fonts/sprites/style JSON needed to render the map offline).
        guard let stylePackOptions = StylePackLoadOptions(
            glyphsRasterizationMode: .ideographsRasterizedLocally,
            metadata: ["regionId": regionId],
            acceptExpired: true
        ) else {
            completion(OfflineTileError.invalidOptions)
            return
        }

        let stylePackCancelable = offlineManager.loadStylePack(
            for: styleURI,
            loadOptions: stylePackOptions,
            progress: { stylePackProgress in
                progress(regionId, "stylePack", stylePackProgress.completedResourceCount, stylePackProgress.requiredResourceCount)
            },
            completion: { [weak self] result in
                switch result {
                case .success:
                    // 2) Tile region: navigation routing tiles + map display tiles together.
                    self?.loadTileRegion(
                        regionId: regionId,
                        geometry: geometry,
                        styleURI: styleURI,
                        minZoom: minZoom,
                        maxZoom: maxZoom,
                        progress: progress,
                        completion: completion
                    )
                case .failure(let error):
                    self?.activeDownloads[regionId] = nil
                    completion(error)
                }
            }
        )
        activeDownloads[regionId, default: []].append(stylePackCancelable)
    }

    private func loadTileRegion(
        regionId: String,
        geometry: Geometry,
        styleURI: StyleURI,
        minZoom: UInt8,
        maxZoom: UInt8,
        progress: @escaping ProgressHandler,
        completion: @escaping (Error?) -> Void
    ) {
        let navigationDescriptor = ExpoMapboxNavigationViewController.navigationProvider
            .getLatestNavigationTilesetDescriptor()

        let mapsDescriptorOptions = TilesetDescriptorOptions(
            styleURI: styleURI,
            zoomRange: minZoom...maxZoom,
            tilesets: nil
        )
        let mapsDescriptor = offlineManager.createTilesetDescriptor(for: mapsDescriptorOptions)

        guard let loadOptions = TileRegionLoadOptions(
            geometry: geometry,
            descriptors: [navigationDescriptor, mapsDescriptor],
            metadata: ["regionId": regionId],
            acceptExpired: true,
            networkRestriction: .none
        ) else {
            activeDownloads[regionId] = nil
            completion(OfflineTileError.invalidOptions)
            return
        }

        let cancelable = tileStore.loadTileRegion(
            forId: regionId,
            loadOptions: loadOptions,
            progress: { tileProgress in
                progress(regionId, "routingTiles", tileProgress.completedResourceCount, tileProgress.requiredResourceCount)
            },
            completion: { [weak self] result in
                self?.activeDownloads[regionId] = nil
                switch result {
                case .success:
                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            }
        )
        activeDownloads[regionId, default: []].append(cancelable)
    }

    /// Remove a region's tiles (and, when a style URL is given, its style pack). Idempotent.
    func removeRegion(regionId: String, styleURLString: String?, completion: @escaping () -> Void) {
        activeDownloads[regionId]?.forEach { $0.cancel() }
        activeDownloads[regionId] = nil

        tileStore.removeTileRegion(forId: regionId)
        if let styleURLString, let styleURI = StyleURI(rawValue: styleURLString) {
            offlineManager.removeStylePack(for: styleURI)
        }
        completion()
    }

    /// List the region ids currently present, with their resource progress.
    func listRegions(completion: @escaping ([[String: Any]]) -> Void) {
        tileStore.allTileRegions { result in
            switch result {
            case .success(let regions):
                let mapped = regions.map { region -> [String: Any] in
                    [
                        "regionId": region.id,
                        "completedResourceCount": region.completedResourceCount,
                        "requiredResourceCount": region.requiredResourceCount,
                    ]
                }
                completion(mapped)
            case .failure:
                completion([])
            }
        }
    }
}

enum OfflineTileError: Error {
    case invalidGeometry
    case invalidOptions
}
