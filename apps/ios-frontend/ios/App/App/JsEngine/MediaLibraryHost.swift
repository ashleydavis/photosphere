import Foundation
import Photos

//
// Reads the device photo library through the Photos framework, for automatic import.
//
// The pure decisions (where a page starts and stops, the sandbox path an export lands on, which
// types are supported, batching deletions) are in MediaLibrary and unit tested without a photo
// library. This is the part that needs the framework: the PHAsset fetch, exporting an asset's
// resource into the sandbox, listing albums, and asking to delete.
//
// Everything here is written against APIs available in iOS 11, so it builds under the pinned
// Xcode 14.2 / macOS 12.7.6 environment without raising any minimum version.
//
final class MediaLibraryHost {

    //
    // The sandbox root exported items are written under.
    //
    private let storageRoot: URL

    //
    // Presents the system confirmation for deleting assets the app did not create, and reports what
    // the user chose. Nil when nothing can present one.
    //
    // The Photos framework presents this itself inside performChanges, so the default implementation
    // simply calls it; a test stages an outcome here instead, which is what lets the batching, the
    // selection and the handling of both answers be tested without a dialog no test can tap.
    //
    var deleteRequester: (([PHAsset]) -> Bool)?

    init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    //
    // Every image and video in the library, newest first, so a backfill that is interrupted has
    // brought in the photos the user is most likely to want first.
    //
    private func fetchAllAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue)
        return PHAsset.fetchAssets(with: options)
    }

    //
    // The MIME type of an asset, taken from its primary resource.
    //
    private func mimeType(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else {
            return asset.mediaType == .video ? "video/quicktime" : "image/jpeg"
        }

        // uniformTypeIdentifier is a UTI such as "public.jpeg"; the file name's extension is the more
        // dependable source of a MIME type here and is what the Android side effectively uses.
        let fileExtension = (resource.originalFilename as NSString).pathExtension.lowercased()
        switch fileExtension {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "webm": return "video/webm"
        default: return asset.mediaType == .video ? "video/quicktime" : "image/jpeg"
        }
    }

    //
    // The name an asset's file has, for showing the user and for choosing an extension.
    //
    private func displayName(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first?.originalFilename ?? asset.localIdentifier
    }

    //
    // The size of an asset's primary resource in bytes, or zero when the framework will not say.
    //
    private func fileSize(for asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else {
            return 0
        }
        // fileSize is not a public property; it is available through the resource's value dictionary.
        let value = resource.value(forKey: "fileSize")
        return (value as? Int64) ?? Int64((value as? Int) ?? 0)
    }

    //
    // host.mediaLibraryList(cursor, pageSize): returns one page of the library as JSON.
    //
    func mediaLibraryList(cursor: String?, pageSize: Int) -> String {
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
                // An asset can be in several albums, so it claims none of its own. The album filter
                // is applied by listing an album's assets, not by tagging each one.
                "albumId": "",
            ])
        }

        var page: [String: Any] = ["items": items]
        // The cursor advances by everything the fetch walked, not by what survived the type filter:
        // skipping the filtered-out assets would make the next page start on top of them and the walk
        // would never finish.
        if let nextCursor = MediaLibrary.nextCursor(offset: offset, itemsReturned: itemsSeen, totalCount: totalCount) {
            page["nextCursor"] = nextCursor
        }

        return jsonString(from: page)
    }

    //
    // host.mediaLibraryAlbums(): returns the albums in the library as JSON.
    //
    func mediaLibraryAlbums() -> String {
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

        return jsonString(from: albums)
    }

    //
    // host.mediaLibraryOpen(itemId): copies one library item into the sandbox and returns the
    // sandbox-relative path the import can read it from.
    //
    // A library asset is not a file the import can open, which is why this exists. The copy is
    // deleted again by mediaLibraryClose once the import has finished with it.
    //
    func mediaLibraryOpen(itemId: String) throws -> String {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [itemId], options: nil)
        guard assets.count > 0 else {
            throw MediaLibraryError.itemNotFound(itemId)
        }
        let asset = assets.object(at: 0)

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else {
            throw MediaLibraryError.exportFailed(itemId)
        }

        let relativePath = MediaLibrary.buildExportPath(
            itemId: itemId,
            displayName: displayName(for: asset),
            mimeType: mimeType(for: asset))
        let destination = try PathSandbox.resolveWithin(root: storageRoot, candidate: relativePath)

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        // writeData is asynchronous, and the host function it serves is synchronous because
        // everything across the engine bridge is, so the calling thread waits for it here.
        let finished = DispatchSemaphore(value: 0)
        var writeError: Error?

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
            writeError = error
            finished.signal()
        }
        finished.wait()

        if writeError != nil {
            throw MediaLibraryError.exportFailed(itemId)
        }

        return relativePath
    }

    //
    // host.mediaLibraryClose(itemId): deletes the sandbox copy the export made.
    //
    // The library asset itself is untouched. Removing a photo from the device is cleanup, which is a
    // separate operation the user confirms.
    //
    func mediaLibraryClose(itemId: String) {
        guard let tempDir = try? PathSandbox.resolveWithin(root: storageRoot, candidate: MediaLibrary.mediaTempDir) else {
            return
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path) else {
            return
        }

        let prefix = MediaLibrary.sanitiseId(itemId) + "."
        for entry in entries where entry.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: tempDir.appendingPathComponent(entry))
        }
    }

    //
    // host.mediaLibraryDelete(itemIdsJson): asks to delete the named items, as one system
    // confirmation per batch, and returns what happened as JSON.
    //
    // Nothing is reported as deleted unless the framework said so. A caller that believed a photo was
    // gone when it was not would go on to free space that is still in use.
    //
    func mediaLibraryDelete(itemIdsJson: String) throws -> String {
        let itemIds = try parseIds(itemIdsJson)

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

        return jsonString(from: ["deletedIds": deletedIds, "failedIds": failedIds])
    }

    //
    // Deletes the given assets, through the staged requester when one is installed and through the
    // Photos framework otherwise. The framework presents its own confirmation.
    //
    private func performDelete(_ assets: [PHAsset]) -> Bool {
        // A staged answer stands in for the system confirmation, and is used by one request only.
        if let staged = MediaDeleteStaging.consume() {
            MediaDeleteStaging.record(requestSize: assets.count)
            return staged
        }

        if let requester = deleteRequester {
            return requester(assets)
        }

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

    //
    // Reads the ids out of the JSON array the worker sent.
    //
    private func parseIds(_ itemIdsJson: String) throws -> [String] {
        guard let data = itemIdsJson.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw MediaLibraryError.exportFailed("the list of items to delete could not be read")
        }
        return parsed
    }

    //
    // Serialises a JSON value for the engine bridge, which carries only strings.
    //
    private func jsonString(from value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
