//
//  MediaUploaderPlugin.m
//  App
//
//  Created by Ashley Davis on 20/1/2023.
//

#import <Capacitor/Capacitor.h>

CAP_PLUGIN(MediaUploaderPlugin, "FileUploader",
    CAP_PLUGIN_METHOD(updateSettings, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(checkPermission, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(requestPermission, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(checkSyncStatus, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(startSync, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(stopSync, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(getFiles, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(loadThumbnail, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(loadFullImage, CAPPluginReturnPromise);
)
