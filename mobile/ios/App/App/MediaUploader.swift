//
//  MediaUploader.swift
//  iOS file scanning prototype
//
//  Created by Ashley Davis on 15/1/2023.
//

import Foundation
import CryptoKit
import Photos
import UIKit
import CoreLocation
import Contacts

struct FileDetails : Codable {
  let name: String
  let localAssetid: String
  let contentType: String
  var hash: String?
  var uploaded: Bool
  let width: Int
  let height: Int
  var location: String?
  let creationDate: Date
}

struct MediaUploader {
    
  public static let instance = MediaUploader()
  
  //
  // Setting to true when the work is running.
  //
  public static var running = false;

  //
  // Setting this to true aborts the work.
  //
  public static var stopWork = false;

  
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
  // - Parameter completion: a closure which gets a `Result` (`Data` on `success` or `Error` on `failure`)
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
  // Computes the hash of the data.
  //
  private func computeHash(data : Data) -> String {
    // https://www.hackingwithswift.com/example-code/cryptokit/how-to-calculate-the-sha-hash-of-a-string-or-data-instance
    let hashed = SHA256.hash(data: data)
    return hashed.compactMap { String(format: "%02x", $0) }.joined()
  }

  //
  // Uploads an asset to the backend.
  //
  private func checkFileUploaded(hash: String) async throws -> Bool {
    let url = URL(string: "http://192.168.20.14:3000/check-asset?hash=" + hash)!
    var request = URLRequest(url: url)
    request.httpMethod = "GET";
    
    // https://wwdcbysundell.com/2021/using-async-await-with-urlsession/
    let (_, response) = try await URLSession.shared.data(from: url)
    return (response as! HTTPURLResponse).statusCode == 200
  }
  
  //
  // Uploads an asset to the backend.
  //
  private func uploadFile(_ contentType: String, _ fileDetails: FileDetails, _ assetData: Data, _ thumbData: Data, _ properties: [String : Any]?) async throws {
    
    var metadata: [String : Any] = [
      "contentType": contentType,
      "thumbContentType": "image/jpeg",
      "fileName": fileDetails.name,
      "width": fileDetails.width,
      "height": fileDetails.height,
      "hash": fileDetails.hash!,
    ]
    if fileDetails.location != nil {
      metadata["location"] = fileDetails.location
    }
    
    if properties != nil {
      metadata["exif"] = properties;
    }
        
    let jsonMetadata = String(data: try! JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)
    
    let url = URL(string: "http://192.168.20.14:3000/asset")!
    let session = URLSession.shared
    var request = URLRequest(url: url)
    request.httpMethod = "POST";
    request.setValue(contentType, forHTTPHeaderField: "content-type")
    request.setValue(jsonMetadata, forHTTPHeaderField: "metadata")
    request.setValue(thumbData.base64EncodedString(), forHTTPHeaderField: "thumbnail")
    request.httpBody = assetData
    
    //print("Thumb data:")
    //print(thumbData.base64EncodedString())
    
    //todo: convert this to the async version!
    try await withCheckedThrowingContinuation { continuation in
      let task = session.dataTask(with: request as URLRequest, completionHandler: { data1, response, error in
        
        guard error == nil else {
          return
        }
        
        guard let data1 = data1 else {
          return
        }
        
        do {
          if let json = try JSONSerialization.jsonObject(with: data1, options: .mutableContainers) as? [String: Any] {
            print("Got response ^^^^^^^^^^^^")
            print(json)
            
            continuation.resume(with: .success(()))
          }
        } catch let error {
          print(error.localizedDescription)
        }
      })
      
      task.resume()
    }
  }
  
  public typealias ReverseGeocodeCompletion = (Result<String?, Swift.Error>) -> Void
  
  //
  // Reverse geocodes a particular location.
  //
  private func reverseGeocode(location: CLLocation) async throws -> String {
    let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
    let placemark = placemarks[0] as CLPlacemark
    var addressString = CNPostalAddressFormatter().string(from: placemark.postalAddress!)
    addressString = addressString
      .split(separator: "\n")
      .map({ line in line.trimmingCharacters(in: .whitespacesAndNewlines) })
          .joined(separator: ", ")
    return addressString
  }
  
  public enum AssetPropertiesError: Swift.Error {
          /// Thrown if a CIImage instance could not be created
          case couldNotCreateCIImage
          /// Thrown if a full size image URL is missing
          case missingFullSizeImageURL
          /// Thrown if the camera produced an unsupported result
          case unsupportedCameraResult
  }
  
  public typealias AssetPropertiesCompletion = (Result<[String : Any], AssetPropertiesError>) -> Void
  
  //
  // Transform asset properties into a format serializable to JSON.
  //
  private func transformProperties(_ props: [String : Any]) -> [String : Any] {
    var out: [String : Any] = [:];
    
    for (key, value) in props {
      if let dict = value as? [String: Any] {
        out[key] = transformProperties(dict)
      }
      else if let _ = value as? Data {
        // Filter out blocks of inline data.
        // Could later convert this to base64 if it's useful.
      }
      else {
        out[key] = value
      }
    }
    
    return out
  }
  
  //
  // Retreive properties (e.g. exif data) for the asset.
  //
  private func getAssetProperties(_ asset: PHAsset) async throws -> [String : Any] {
    let contentEditingOptions = PHContentEditingInputRequestOptions()
    contentEditingOptions.isNetworkAccessAllowed = true
    
    return try await withCheckedThrowingContinuation { continuation in
      asset.requestContentEditingInput(with: contentEditingOptions) { contentEditingInput, _ in
        guard let fullSizeImageURL = contentEditingInput?.fullSizeImageURL else {
          continuation.resume(with: .failure(AssetPropertiesError.missingFullSizeImageURL))
          return
        }
        
        guard let fullImage = CIImage(contentsOf: fullSizeImageURL) else {
          continuation.resume(with: .failure(AssetPropertiesError.couldNotCreateCIImage))
          return
        }
        
        continuation.resume(with: .success(transformProperties(fullImage.properties)))
      }
    }
  }
  
  private func uploadAsset(assetLocalId: String, uploadList: UserDefaults) async throws -> Void {
    let jsonString = uploadList.string(forKey: Self.assetIdPrefix + assetLocalId)!
    var fileDetails = try JSONDecoder().decode(FileDetails.self, from: jsonString.data(using: .utf8)!)
    if fileDetails.uploaded {
      print("Asset already marked as uploaded " + assetLocalId)
      return
    }
    
    var contentType = fileDetails.contentType;
    let options = PHFetchOptions()
    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetLocalId], options: options)
    let asset = fetchResult.firstObject!
    var assetData = try await getAssetData(asset: asset)

    if contentType == "image/heic" {
      //
      // Convert heic files to jpg.
      //
      contentType = "image/jpg";

      let image = UIImage(data: assetData)!
      assetData = image.jpegData(compressionQuality: 1)!
    }
    
    //
    // Test to resize image to create a thumbnail.
    // Eventually this should be uploaded in addition to the original asset.
    //
    // https://www.advancedswift.com/resize-uiimage-no-stretching-swift/
    //
    let image = UIImage(data: assetData)!
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

    if fileDetails.hash == nil {
      // Compute a hash for the file.
      fileDetails.hash = computeHash(data: assetData);

      // Update record in local storage.
      let jsonData = try JSONEncoder().encode(fileDetails)
      uploadList.set(String(data: jsonData, encoding: .utf8)!, forKey: Self.assetIdPrefix + asset.localIdentifier)
    }
    
    //
    // Check if file has already been uploaded, based on the hash.
    //
    let uploaded = try await checkFileUploaded(hash: fileDetails.hash!)
    if (uploaded) {
      // Record that this file has already been uploaded.
      fileDetails.uploaded = true

      // Update record in local storage.
      let jsonData = try JSONEncoder().encode(fileDetails)
      uploadList.set(String(data: jsonData, encoding: .utf8)!, forKey: Self.assetIdPrefix + asset.localIdentifier)
      return
    }
        
    if fileDetails.location == nil && asset.location != nil {
      // Reverse geocode the location.
      fileDetails.location = try await reverseGeocode(location: asset.location!)
      if fileDetails.location != nil {
        // Update record in local storage.
        let jsonData = try JSONEncoder().encode(fileDetails)
        uploadList.set(String(data: jsonData, encoding: .utf8)!, forKey: Self.assetIdPrefix + asset.localIdentifier)
      }
    }
    
    //
    // Test to get EXIF data.
    //
    let properties = try await getAssetProperties(asset)
//    print("Got properties:")
//    print(properties)
    
    //
    // Now actually upload the file.
    //
    try await uploadFile(contentType, fileDetails, assetData, thumbData, properties)
    
    //
    // Record that the file was uploaded.
    //
    fileDetails.uploaded = true
    
    let jsonData = try JSONEncoder().encode(fileDetails)
    uploadList.set(String(data: jsonData, encoding: .utf8)!, forKey: Self.assetIdPrefix + asset.localIdentifier)
  }
  
  public static let assetIdPrefix = "xid_";
  
  //
  // Starts scanning and uploading of media.
  //
  public func scanMedia() async throws -> Void {

    Self.running = true;
    Self.stopWork = false;

    let uploadList = UserDefaults(suiteName: "local-media")!

    let options = PHFetchOptions()
    //todo: http://www.gfrigerio.com/read-exif-data-of-pictures/
//    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let result = PHAsset.fetchAssets(with: options)
    var items: [PHAsset] = []
    result.enumerateObjects { asset, _, _ in
      items.append(asset)
    }
    
    print("********** Saving upload list ************")

    // https://stackoverflow.com/a/33186219
    let jsonEncoder = JSONEncoder();

    for asset in items {
      if Self.stopWork {
        print("Stopped file scan")
        return;
      }
      
      let existingAssetJson = uploadList.string(forKey: Self.assetIdPrefix + asset.localIdentifier)
      if (existingAssetJson == nil) {
        print("Saving record for asset " + asset.localIdentifier)
        // No record yet for this asset.
        let resource = PHAssetResource.assetResources(for: asset)[0]
        let mimetype = UTType(resource.uniformTypeIdentifier)!.preferredMIMEType!
                
        let fileDetails = FileDetails(
          name: resource.originalFilename,
          localAssetid: asset.localIdentifier,
          contentType: mimetype,
          hash: nil,
          uploaded: false,
          width: resource.pixelWidth,
          height: resource.pixelHeight,
          creationDate: asset.creationDate!
        )
        let jsonData = try jsonEncoder.encode(fileDetails)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        uploadList.set(jsonString, forKey: Self.assetIdPrefix + asset.localIdentifier)
      }
      else {
        print("Already have record for " + asset.localIdentifier)
      }
    }
    
    //
    // Print all upload records in storage.
    //
//    for (key, value) in uploadList.dictionaryRepresentation() {
//      if key.starts(with: assetIdPrefix) {
//        print("\(key) = \(value) \n")
//      }
//    }

    print("********** Uploading assets ************")
    
    for asset in items {
      if Self.stopWork {
        print("Stopped file scan")
        return;
      }
      try await uploadAsset(assetLocalId: asset.localIdentifier, uploadList: uploadList)
    }
    
    print("========== Done ===========")
  }
  
  //
  // Remove previous settings.
  //
  // https://stackoverflow.com/a/43402172
  //
  public func clearStorage() {
    let uploadList = UserDefaults(suiteName: "local-media")!
    for key in uploadList.dictionaryRepresentation().keys {
      if key.starts(with: Self.assetIdPrefix) {
        // print("Removing " + key)
        uploadList.removeObject(forKey: key)
      }
    }
  }
}
