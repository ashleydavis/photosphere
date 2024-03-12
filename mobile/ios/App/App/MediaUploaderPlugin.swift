//
//  MediaUploaderPlugin.swift
//  App
//
//  Created by Ashley Davis on 20/1/2023.
//

import Capacitor
import Photos

@objc(MediaUploaderPlugin)
public class MediaUploaderPlugin: CAPPlugin {
  
  @objc func updateSettings(_ call: CAPPluginCall) {
    let backendURL = call.getString("backend")!
    print("Setting backend to " + backendURL)
    UserDefaults.standard.set(backendURL, forKey: "backend")
    call.resolve()
  }
  
  @objc public override func checkPermissions(_ call: CAPPluginCall) {
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
  // Requests the user's permission to the photo library
  //
  // - Parameter completion: a closure which gets a `Result` (`Void` on `success` and `Error` on `failure`)
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
  
  @objc public func requestPermissions(_ call: CAPPluginCall) async {
    do {
      try await requestPermission()
      call.resolve();
    }
    catch {
      call.reject("Access to media library has been denied by the user.");
    }
  }
  
  @objc func checkSyncStatus(_ call: CAPPluginCall) {
    call.resolve([
      "syncing": MediaUploader.running,
    ])
  }
  
  @objc func startSync(_ call: CAPPluginCall) {
    print("Starting file scan")
    call.resolve()
    
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
  
  @objc func stopSync(_ call: CAPPluginCall) {
    if !MediaUploader.running {
      MediaUploader.stopWork = true;
      print("Stopping file scan")
    }
    call.resolve()
  }
  
  @objc func getFiles(_ call: CAPPluginCall) {
    
    let uploadList = UserDefaults(suiteName: "local-media")!
    
    var files: [JSObject] = []
    
    for (key, value) in uploadList.dictionaryRepresentation() {
      if key.starts(with: MediaUploader.assetIdPrefix) {
        let fileDetails = try! JSONDecoder().decode(FileDetails.self, from: (value as! String).data(using: .utf8)!)
        files.append([
          "name": fileDetails.name,
          "type": fileDetails.contentType,
          "hash": fileDetails.hash ?? NSNull(),
          "uploaded": fileDetails.uploaded,
          "date": fileDetails.creationDate,
        ] as JSObject)
      }
    }

    call.resolve([
      "files": files,
    ])
  }
}
