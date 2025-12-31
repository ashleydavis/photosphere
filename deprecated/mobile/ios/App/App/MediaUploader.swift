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

//    print("********** Uploading assets ************")
//    
//    for asset in items {
//      if Self.stopWork {
//        print("Stopped file scan")
//        return;
//      }
//      try await uploadAsset(assetLocalId: asset.localIdentifier, uploadList: uploadList)
//    }
    
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
