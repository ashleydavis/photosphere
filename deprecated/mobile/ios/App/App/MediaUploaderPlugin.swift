//
//  MediaUploaderPlugin.swift
//  App
//
//  Created by Ashley Davis on 20/1/2023.
//

import Capacitor
import Photos
import CryptoKit

@objc(MediaUploaderPlugin)
public class MediaUploaderPlugin: CAPPlugin {
  
  //
  // Updates settings for the plugin.
  //
  @objc func updateSettings(_ call: CAPPluginCall) {
    let backendURL = call.getString("backend")!
    print("Setting backend to " + backendURL)
    UserDefaults.standard.set(backendURL, forKey: "backend")
    call.resolve()
  }
  
  //
  // Checks if we permission to access the photo library.
  //
  @objc func checkPermission(_ call: CAPPluginCall) {
    call.resolve([
      "havePermissions": PHPhotoLibrary.authorizationStatus() == .authorized,
    ]);
  }
  
  //
  // Errors thrown during permission requests
  // Like `PHAuthorizationStatus` but without `unknown` case
  //
  public enum PermissionError: Swift.Error {
    // Thrown if the permission was denied
    case denied
    // Thrown if the permission could not be determined
    case notDetermined
    // Thrown if the access was restricted
    case restricted
    // Thrown if an unknown error occurred
    case unknown
  }
  
  //
  // Requests the permission to access the photo library.
  //
  private func requestPermission() async throws {
    return try await withCheckedThrowingContinuation { continuation in
      let handler: (PHAuthorizationStatus) -> Void = { authorizationStatus in
        DispatchQueue.main.async {
          switch authorizationStatus {
          case .authorized, .limited:
            continuation.resume(with: .success(()))
          case .denied:
            continuation.resume(with: .failure(PermissionError.denied))
          case .restricted:
            continuation.resume(with: .failure(PermissionError.restricted))
          case .notDetermined:
            continuation.resume(with: .failure(PermissionError.notDetermined))
          @unknown default:
            continuation.resume(with: .failure(PermissionError.unknown))
          }
        }
      }
      
      if #available(iOS 14, macOS 11, macCatalyst 14, tvOS 14, *) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: handler)
      } else {
        PHPhotoLibrary.requestAuthorization(handler)
      }
    }
  }
  
  //
  // Requests the permission to access the photo library.
  //
  @objc func requestPermission(_ call: CAPPluginCall) {
    Task {
      do {
        try await requestPermission()
        call.resolve();
      }
      catch {
        call.reject("Access to media library has been denied by the user.");
      }
    }
  }
  
  //
  // Checks if syncing is in progress.
  //
  @objc func checkSyncStatus(_ call: CAPPluginCall) {
    call.resolve([
      "syncing": MediaUploader.running,
    ])
  }
  
  //
  // Starts syncing.
  //
  @objc func startSync(_ call: CAPPluginCall) {
    print("Starting file scan")
    
    Task {
      do {
        try await MediaUploader.instance.scanMedia();
        print("Finished file scan")
      }
      catch {
        print("scanMedia failed with error: \(error)")
      }
    }
  }
  
  //
  // Stops syncing.
  //
  @objc func stopSync(_ call: CAPPluginCall) {
    if !MediaUploader.running {
      MediaUploader.stopWork = true;
      print("Stopping file scan")
    }
    call.resolve()
  }
  
  //
  // Gets the list of files that have been synced.
  //
  @objc func getFiles(_ call: CAPPluginCall) {
    
    let uploadList = UserDefaults(suiteName: "local-media")!
    
    var files: [JSObject] = []
    
    for (key, value) in uploadList.dictionaryRepresentation() {
      if key.starts(with: MediaUploader.assetIdPrefix) {
        let fileDetails = try! JSONDecoder().decode(FileDetails.self, from: (value as! String).data(using: .utf8)!)
        files.append([
          "name": fileDetails.name,
          "path": fileDetails.localAssetid,
          "type": fileDetails.contentType,
          "date": fileDetails.creationDate,
        ] as JSObject)
      }
    }

    call.resolve([
      "files": files,
    ])
  }

  //
  // Computes the hash of the data.
  //
  private func computeHash(data : Data) -> String {
    // https://www.hackingwithswift.com/example-code/cryptokit/how-to-calculate-the-sha-hash-of-a-string-or-data-instance
    let hashed = SHA256.hash(data: data)
    return hashed.compactMap { String(format: "%02x", $0) }.joined()
  }

  //
  // Errors thrown during photo operations.
  //
  public enum Error: Swift.Error {
    // Thrown if a full size image URL is missing
    case missingFullSizeImageURL
    case unknown
  }

  //
  // Gets the data for the asset.
  //
  public func getAssetData(asset: PHAsset) async throws -> Data {
    
    let options = PHImageRequestOptions()
    // options.isNetworkAccessAllowed = true
    
    if #available(iOS 13, macOS 10.15, tvOS 13, *) {
      let imageManager = PHImageManager.default()
      return try await withCheckedThrowingContinuation { continuation in
        imageManager.requestImageDataAndOrientation(for: asset, options: options, resultHandler: { data, _, _, info in
          if let error = info?[PHImageErrorKey] as? Error {
            continuation.resume(with: .failure(error))
          } else if let data = data {
            continuation.resume(with: .success(data))
          } else {
            continuation.resume(with: .failure(Error.unknown))
          }
        })
      }
    } else {
      // Fallback on earlier versions
      return try await withCheckedThrowingContinuation { continuation in
        asset.requestContentEditingInput(with: nil) { contentEditingInput, _ in
          guard let fullSizeImageURL = contentEditingInput?.fullSizeImageURL else {
            continuation.resume(with: .failure(Error.missingFullSizeImageURL))
            return
          }
          
          do {
            let data = try Data(contentsOf: fullSizeImageURL)
            continuation.resume(with: .success(data))
          } catch {
            continuation.resume(with: .failure(error))
          }
        }
      }
    }
  }
  
  //
  // Internal function to load the full image.
  //
  @objc func _loadFullImage(_ path: String) async throws -> Data {
    let options = PHFetchOptions()
    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [path], options: options)
    let asset = fetchResult.firstObject!
    return try await getAssetData(asset: asset)
  }
  
  //
  // Internal function to load a thumbnail.
  //
  @objc func _loadThumbnail(_ path: String) async throws -> (thumbnailData: Data, width: CGFloat, height: CGFloat, hash: String) {
    
    let (fullImageData) = try await _loadFullImage(path)

    //
    // Resize image to create a thumbnail.
    // Eventually this should be uploaded in addition to the original asset.
    //
    // https://www.advancedswift.com/resize-uiimage-no-stretching-swift/
    //
    let image = UIImage(data: fullImageData)!
    let targetSize = CGSize(width: 100, height: 100)

    // Compute the scaling ratio for the width and height separately
    let widthScaleRatio = targetSize.width / image.size.width //TODO: I feel like there is something wrong with this formula. One of the dimensions should come out as 100, but both are bigger!
    let heightScaleRatio = targetSize.height / image.size.height

    // To keep the aspect ratio, scale by the smaller scaling ratio
    let scaleFactor = min(widthScaleRatio, heightScaleRatio)

    // Multiply the original image’s dimensions by the scale factor
    // to determine the scaled image size that preserves aspect ratio
    let scaledImageSize = CGSize(
        width: image.size.width * scaleFactor,
        height: image.size.height * scaleFactor
    )
    
    let renderer = UIGraphicsImageRenderer(size: scaledImageSize)
    let scaledImage = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: scaledImageSize))
    }
    
    let thumbData = scaledImage.jpegData(compressionQuality: 0.5)!

    let hash = computeHash(data: fullImageData);
    
    return (
      thumbData,
      image.size.width,
      image.size.height,
      hash
    )
  }

  //
  // Loads a thumbnail and other data for the image.
  //
  @objc func loadThumbnail(_ call: CAPPluginCall) {
    let path = call.getString("path")!
    
    Task {
      do {
        let (thumbData, width, height, hash) = try await _loadThumbnail(path)
        call.resolve([
            "thumbnail": thumbData.base64EncodedString(),
            "width": width,
            "height": height,
            "hash": hash,
        ])
       }
       catch {
         call.reject("Failed to load thumbnail")
       }
    }
  }

  // 
  // Loads the full resolution image.
  //
  @objc func loadFullImage(_ call: CAPPluginCall) {
    let path = call.getString("path")!
    let contentType = call.getString("contentType")!
    
    Task {
      do {
        var fullImageData = try await _loadFullImage(path)
        
        if contentType == "image/heic" {
          //
          // Convert heic files to jpg.
          //
          let image = UIImage(data: fullImageData)!
          fullImageData = image.jpegData(compressionQuality: 1)!
        }
        
        call.resolve([
            "fullImage": fullImageData.base64EncodedString(),
        ])
       }
       catch {
         call.reject("Failed to load full image.")
       }
    }
  }
}
