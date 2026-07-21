import { requireNativeModule, type EventSubscription } from "expo-modules-core";

import type {
  DownloadOfflineRegionOptions,
  OfflineCompleteEvent,
  OfflineErrorEvent,
  OfflineProgressEvent,
  OfflineRegionInfo,
} from "./ExpoMapboxNavigation.types";

const nativeModule = requireNativeModule("ExpoMapboxNavigation");

export default nativeModule;

/**
 * Whether the installed native binary exposes the offline-tile API. Guards against JS/native
 * version skew (JS updated but the app not yet rebuilt against the new native module): callers can
 * degrade gracefully instead of crashing on a missing method.
 */
export function isOfflineTilesSupported(): boolean {
  return typeof nativeModule.downloadOfflineRegion === "function";
}

/**
 * Download a region of navigation routing + map display tiles (and the style pack) for offline use.
 * Resolves once the download completes; progress arrives via `addOfflineProgressListener`.
 */
export function downloadOfflineRegion(
  options: DownloadOfflineRegionOptions
): Promise<{ regionId: string }> {
  return nativeModule.downloadOfflineRegion(options);
}

/** Remove a previously downloaded region (its tiles and style pack). Idempotent. */
export function removeOfflineRegion(
  regionId: string,
  styleURL?: string
): Promise<void> {
  return nativeModule.removeOfflineRegion(regionId, styleURL ?? null);
}

/** List the regions currently present in the tile store. */
export function getOfflineRegions(): Promise<OfflineRegionInfo[]> {
  return nativeModule.getOfflineRegions();
}

export function addOfflineProgressListener(
  listener: (event: OfflineProgressEvent) => void
): EventSubscription {
  return nativeModule.addListener("onOfflineProgress", listener);
}

export function addOfflineCompleteListener(
  listener: (event: OfflineCompleteEvent) => void
): EventSubscription {
  return nativeModule.addListener("onOfflineComplete", listener);
}

export function addOfflineErrorListener(
  listener: (event: OfflineErrorEvent) => void
): EventSubscription {
  return nativeModule.addListener("onOfflineError", listener);
}
