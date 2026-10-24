//
// Handles the core's native calls for the device photo library: mediaLibraryList, mediaLibraryAlbums, mediaLibraryOpen, mediaLibraryClose
// and mediaLibraryDelete. Automatic import reads the library through these, with the Photos framework. The pure decisions (where a
// page starts and stops, the path an exported item lands on, which types are supported, batching deletions) are in MediaLibrary. The
// core calls from a worker thread and waits, so a request may block on the system's delete confirmation.
//
// Everything here is written against APIs available in iOS 11, so it builds under the pinned Xcode 14.2 / macOS 12.7.6 environment
// without raising any minimum version.
//

import Foundation
import Photos
import ZiggyNativeIOS

// The photo library requests.
final class MediaLibraryNativeCalls: ZiggyNativeCallHandler {
    // The directory exported items are written under.
    private let exportRoot: URL

    // exportRoot is where an item is copied out of the library to be imported, which is the temporary directory.
    init(exportRoot: URL) {
        self.exportRoot = exportRoot
    }

    func handle(method: String, requestJson: String) throws -> String {
        switch method {
        case "mediaLibraryList":
            let request = try NativeCallJson.object(from: requestJson, method: method)
            try requireAccess(method)
            let cursor = try NativeCallJson.string(request, "cursor", method: method)
            guard let pageSize = request["pageSize"] as? Int else {
                throw ZiggyNativeCallError("The request \(method) was not understood: \"pageSize\" is missing or is not a number.")
            }
            return try list(cursor: cursor, pageSize: pageSize)
        case "mediaLibraryAlbums":
            try requireAccess(method)
            return try albums()
        case "mediaLibraryOpen":
            let request = try NativeCallJson.object(from: requestJson, method: method)
            try requireAccess(method)
            return try NativeCallJson.quote(try open(itemId: try NativeCallJson.string(request, "itemId", method: method)), method: method)
        case "mediaLibraryClose":
            let request = try NativeCallJson.object(from: requestJson, method: method)
            try close(itemId: try NativeCallJson.string(request, "itemId", method: method))
            return "null"
        case "mediaLibraryDelete":
            let request = try NativeCallJson.object(from: requestJson, method: method)
            try requireAccess(method)
            return try delete(itemIds: try NativeCallJson.strings(request, "itemIds", method: method))
        default:
            throw ZiggyNativeCallError("MediaLibraryNativeCalls does not handle \"\(method)\".")
        }
    }

    // A request fails, naming the permission, when the app can see none of the library, because an empty result would be taken for a
    // library with no photos in it and nothing would be backed up.
    private func requireAccess(_ method: String) throws {
        let status = PHPhotoLibrary.authorizationStatus()
        if status == .authorized {
            return
        }
        if #available(iOS 14.0, *), status == .limited {
            return
        }
        throw ZiggyNativeCallError("\(method) needs permission to read the photo library, and the app does not have it. Allow access to Photos for Photosphere in the phone's Settings.")
    }

    // Every image and video in the library, newest first, so a backfill that is interrupted has brought in the photos the user is most
    // likely to want first.
    private func fetchAllAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue)
        return PHAsset.fetchAssets(with: options)
    }

    // The MIME type of an asset, taken from its primary resource.
    private func mimeType(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else {
            return asset.mediaType == .video ? "video/quicktime" : "image/jpeg"
        }

        // uniformTypeIdentifier is a UTI such as "public.jpeg"; the file name's extension is the more dependable source of a MIME type
        // here.
        let fileExtension = (resource.originalFilename as NSString).pathExtension.lowercased()
        switch fileExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        case "heif":
            return "image/heif"
        case "bmp":
            return "image/bmp"
        case "tif", "tiff":
            return "image/tiff"
        case "mp4", "m4v":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "avi":
            return "video/x-msvideo"
        case "webm":
            return "video/webm"
        default:
            return asset.mediaType == .video ? "video/quicktime" : "image/jpeg"
        }
    }

    // The name an asset's file has, for showing the user and for choosing an extension.
    private func displayName(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first?.originalFilename ?? asset.localIdentifier
    }

    // The size of an asset's primary resource in bytes, or zero when the framework does not report it.
    private func fileSize(for asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else {
            return 0
        }
        // fileSize is not a public property; it is available through the resource's value dictionary.
        let value = resource.value(forKey: "fileSize")
        return (value as? Int64) ?? Int64((value as? Int) ?? 0)
    }

    // One page of the library as JSON.
    private func list(cursor: String, pageSize: Int) throws -> String {
        let offset = MediaLibrary.offsetFromCursor(cursor)
        let limit = pageSize > 0 ? pageSize : 50

        let assets = fetchAllAssets()
        let totalCount = assets.count

        var items: [[String: Any]] = []
        var itemsSeen = 0

        var index = offset
        while index < totalCount && itemsSeen < limit {
            let asset = assets.object(at: index)
            itemsSeen += 1
            index += 1

            let assetMimeType = mimeType(for: asset)
            if !MediaLibrary.isSupportedMimeType(assetMimeType) {
                continue
            }

            items.append([
                "id": asset.localIdentifier,
                "displayName": displayName(for: asset),
                "mimeType": assetMimeType,
                "size": fileSize(for: asset),
                "createdAtMs": Int((asset.creationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000),
                // An asset can be in several albums, so it claims none of its own.
                "albumId": "",
            ])
        }

        var page: [String: Any] = [
            "items": items,
        ]
        // The cursor advances by everything the fetch walked, not by what survived the type filter: skipping the filtered-out assets
        // would make the next page start on top of them and the walk would never finish.
        if let nextCursor = MediaLibrary.nextCursor(offset: offset, itemsReturned: itemsSeen, totalCount: totalCount) {
            page["nextCursor"] = nextCursor
        }

        return try NativeCallJson.text(from: page, method: "mediaLibraryList")
    }

    // The albums in the library as JSON.
    private func albums() throws -> String {
        var albums: [[String: Any]] = []

        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            albums.append([
                "id": collection.localIdentifier,
                "name": collection.localizedTitle ?? "",
                "itemCount": assets.count,
            ])
        }

        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smartAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            if assets.count == 0 {
                return
            }
            albums.append([
                "id": collection.localIdentifier,
                "name": collection.localizedTitle ?? "",
                "itemCount": assets.count,
            ])
        }

        return try NativeCallJson.text(from: albums, method: "mediaLibraryAlbums")
    }

    // Copies one library item into the temporary directory and returns the absolute path the import can read it from. A library asset
    // is not a file the import can open, which is why this exists. The copy is deleted again by close.
    private func open(itemId: String) throws -> String {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [itemId], options: nil)
        guard assets.count > 0 else {
            throw ZiggyNativeCallError(MediaLibraryError.itemNotFound(itemId).description)
        }
        let asset = assets.object(at: 0)

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else {
            throw ZiggyNativeCallError(MediaLibraryError.exportFailed(itemId).description)
        }

        let relativePath = MediaLibrary.buildExportPath(
            itemId: itemId,
            displayName: displayName(for: asset),
            mimeType: mimeType(for: asset))
        let destination = try PathSandbox.resolveWithin(root: exportRoot, candidate: relativePath)

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        // writeData is asynchronous, and the core's worker thread that made the call needs the result, so it blocks here until the write finishes.
        let finished = DispatchSemaphore(value: 0)
        var writeError: Error?

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
            writeError = error
            finished.signal()
        }
        finished.wait()

        if let writeError = writeError {
            throw ZiggyNativeCallError("\(MediaLibraryError.exportFailed(itemId).description) \(writeError.localizedDescription)")
        }

        return destination.path
    }

    // Deletes the temporary copy the export made. The library asset itself is untouched: removing a photo from the device is cleanup,
    // which is a separate operation the user confirms. The copy's name depends on the item's name and type, which are no longer known,
    // so every file in the temp directory whose name starts with this item's id is this item's copy.
    private func close(itemId: String) throws {
        let tempDir = try PathSandbox.resolveWithin(root: exportRoot, candidate: MediaLibrary.mediaTempDir)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            return
        }

        let prefix = MediaLibrary.sanitiseId(itemId) + "."
        for entry in try FileManager.default.contentsOfDirectory(atPath: tempDir.path) where entry.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: tempDir.appendingPathComponent(entry))
        }
    }

    // Requests deletion of the named items, as one system confirmation per batch, and returns what happened as JSON.
    //
    // Nothing is reported as deleted unless the framework reported it. A caller that believed a photo was gone when it was not would go on
    // to free space that is still in use.
    private func delete(itemIds: [String]) throws -> String {
        var deletedIds: [String] = []
        var failedIds: [String] = []

        for batch in try MediaLibrary.buildDeleteBatches(itemIds: itemIds, batchSize: MediaLibrary.deleteBatchSize) {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
            var assetsToDelete: [PHAsset] = []
            assets.enumerateObjects { asset, _, _ in
                assetsToDelete.append(asset)
            }

            if performDelete(assetsToDelete) {
                deletedIds.append(contentsOf: batch)
            }
            else {
                failedIds.append(contentsOf: batch)
            }
        }

        let reply: [String: Any] = [
            "deletedIds": deletedIds,
            "failedIds": failedIds,
        ]
        return try NativeCallJson.text(from: reply, method: "mediaLibraryDelete")
    }

    // Deletes the given assets through the Photos framework, which presents its own confirmation, and blocks until the user chooses.
    private func performDelete(_ assets: [PHAsset]) -> Bool {
        if assets.isEmpty {
            return true
        }

        let finished = DispatchSemaphore(value: 0)
        var wasDeleted = false

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
        }, completionHandler: { success, _ in
            wasDeleted = success
            finished.signal()
        })
        finished.wait()

        return wasDeleted
    }
}
