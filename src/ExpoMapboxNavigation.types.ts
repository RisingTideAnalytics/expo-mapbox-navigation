//@ts-ignore
import { ViewStyle, StyleProp } from "react-native/types";
import { Ref } from "react";

type ProgressEvent = {
  distanceRemaining: number;
  distanceTraveled: number;
  durationRemaining: number;
  fractionTraveled: number;
  isMuted?: boolean;
};

type Route = {
  distance: number;
  expectedTravelTime: number;
  legs: Array<{
    source?: { latitude: number; longitude: number };
    destination?: { latitude: number; longitude: number };
    steps: Array<{
      shape?: {
        coordinates: Array<{ latitude: number; longitude: number }>;
      };
    }>;
  }>;
};

type Routes = {
  mainRoute: Route;
  alternativeRoutes: Route[];
};

type LocationChangeEvent = {
  latitude: number;
  longitude: number;
  heading?: number;
  speed?: number;
};

export type ExpoMapboxNavigationViewRef = {
  recenterMap: () => void;
};

/**
 * A GeoJSON geometry (Polygon or MultiPolygon) describing the region to download offline tiles for.
 * Coordinates are [longitude, latitude] and rings are closed, per the GeoJSON spec.
 */
export type OfflineTileGeometry = {
  type: "Polygon" | "MultiPolygon";
  coordinates: number[][][] | number[][][][];
};

/**
 * Options for pre-downloading a region of Mapbox tiles for offline turn-by-turn navigation.
 * A single tile region (keyed by `regionId`) carries BOTH the navigation routing tiles and the
 * map display tiles into one shared TileStore, plus the style pack, so they download and evict
 * together.
 */
export type DownloadOfflineRegionOptions = {
  /** Caller-supplied id for the region; reused to query/remove it. */
  regionId: string;
  /** GeoJSON geometry (typically a padded bounding box) to cover. */
  geometry: OfflineTileGeometry;
  /** Style URI whose display tiles + style pack to download (matches the runtime map style). */
  styleURL: string;
  /** Most zoomed-out display level to cache. */
  minZoom: number;
  /** Most zoomed-in display level to cache. */
  maxZoom: number;
  /** Routing profile for the navigation tileset (offline routing supports plain "driving"). */
  routingProfile?: string;
};

export type OfflineRegionInfo = {
  regionId: string;
  completedResourceCount: number;
  requiredResourceCount: number;
};

export type OfflineProgressEvent = {
  regionId: string;
  /** Which sub-download this progress refers to. */
  stage: "routingTiles" | "stylePack" | "displayTiles";
  completedResourceCount: number;
  requiredResourceCount: number;
};

export type OfflineCompleteEvent = {
  regionId: string;
};

export type OfflineErrorEvent = {
  regionId: string;
  message: string;
};

export type ExpoMapboxNavigationViewProps = {
  ref?: Ref<ExpoMapboxNavigationViewRef>;
  coordinates: Array<{ latitude: number; longitude: number }>;
  waypointIndices?: number[];
  useRouteMatchingApi?: boolean;
  locale?: string;
  routeProfile?: string;
  routeExcludeList?: string[];
  mapStyle?: string;
  mute?: boolean;
  /**
   * Maximum height of the vehicle in meters.
   * Used for route calculation to avoid roads with height restrictions (e.g., low bridges, tunnels).
   */
  vehicleMaxHeight?: number;
  /**
   * Maximum width of the vehicle in meters.
   * Used for route calculation to avoid roads with width restrictions.
   */
  vehicleMaxWidth?: number;
  /**
   * Maximum weight of the vehicle in metric tons.
   * Used for route calculation to avoid roads with weight restrictions (e.g., weak bridges).
   */
  vehicleMaxWeight?: number;
  initialLocation?: { latitude: number; longitude: number; zoom?: number };
  /**
   * The URL of the custom raster source to use for the map.
   * Should be a template string with {x}, {y}, {z} placeholders.
   * Example: "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
   */
  customRasterSourceUrl?: string;
  placeCustomRasterLayerAbove?: string;
  disableAlternativeRoutes?: boolean;
  followingZoom?: number;
  /**
   * Whether the navigation allows arriving on the opposite side of the street.
   * When true, the user can complete navigation even if they're on the opposite side of the destination.
   * Useful in urban areas where crossing the street might be difficult or unsafe.
   * @default false
   */
  allowsArrivingOnOppositeSide?: boolean;
  /**
   * Whether to show the end-of-route feedback UI when navigation completes.
   * When true, displays a rating/feedback screen after arriving at the destination.
   * @default true
   */
  showsEndOfRouteFeedback?: boolean;
  /**
   * Whether to hide the native trip progress bar at the bottom of the navigation view.
   * Useful when using a custom overlay to display trip progress.
   * On Android, hides the trip progress bar. On iOS, hides the bottom banner container.
   * @default false
   */
  hideTripProgress?: boolean;
  /**
   * Callback fired when the user's location changes during navigation.
   * Provides real-time updates of latitude, longitude, heading, and speed.
   */
  onLocationChange?: (event: { nativeEvent: LocationChangeEvent }) => void;
  onRouteProgressChanged?: (event: { nativeEvent: ProgressEvent }) => void;
  onCancelNavigation?: () => void;
  onWaypointArrival?: (event: {
    nativeEvent: ProgressEvent | undefined;
  }) => void;
  onFinalDestinationArrival?: () => void;
  onRouteChanged?: () => void;
  onUserOffRoute?: () => void;
  onRoutesLoaded?: (event: { nativeEvent: { routes: Routes } }) => void;
  onRouteFailedToLoad?: (event: {
    nativeEvent: { errorMessage: string };
  }) => void;
  /** Fired when the user toggles the in-skin mute button, with the new muted state. */
  onMuteChange?: (event: { nativeEvent: { isMuted: boolean; source?: string } }) => void;
  style?: StyleProp<ViewStyle>;
  uiStyle?: "day" | "night";
};
