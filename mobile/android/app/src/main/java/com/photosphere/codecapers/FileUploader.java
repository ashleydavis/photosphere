package com.photosphere.codecapers;

import static android.content.Context.MODE_PRIVATE;

import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.ThumbnailUtils;
import android.os.Environment;
import android.provider.Settings;
import android.util.Log;

import androidx.work.OneTimeWorkRequest;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;
import androidx.work.WorkRequest;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.google.common.util.concurrent.ListenableFuture;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.math.BigInteger;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;

import com.google.gson.Gson;

@CapacitorPlugin(name = "FileUploader")
public class FileUploader extends Plugin {

    @PluginMethod()
    public void updateSettings(PluginCall call) {
        SharedPreferences settings = this.getActivity().getApplicationContext().getSharedPreferences("settings", MODE_PRIVATE);
        SharedPreferences.Editor editor = settings.edit();
        String backendURL = call.getString("backend");
        Log.i("Dbg", "Setting backend to " + backendURL);
        editor.putString("backend", backendURL);
        editor.commit();
        call.resolve();
    }

    @PluginMethod()
    public void checkPermissions(PluginCall call) {
        JSObject ret = new JSObject();
        ret.put("havePermissions", Environment.isExternalStorageManager());
        call.resolve(ret);
    }

    @PluginMethod()
    public void requestPermissions(PluginCall call) {
        Log.i("Dbg", "Requesting permissions.");
        Intent intent = new Intent();
        intent.setAction(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION);
        this.getActivity().startActivity(intent);
    }

    private boolean isWorkScheduled() {
        try {
            WorkManager instance = WorkManager.getInstance(this.getActivity().getApplicationContext());
            ListenableFuture<List<WorkInfo>> statuses = instance.getWorkInfosByTag(UploadWorker.class.getName());
            boolean running = false;
            List<WorkInfo> workInfoList = statuses.get();
            for (WorkInfo workInfo : workInfoList) {
                WorkInfo.State state = workInfo.getState();
                if (state == WorkInfo.State.RUNNING | state == WorkInfo.State.ENQUEUED) {
                    running = true;
                }
            }
            return running;
        }
        catch (Exception ex) {
            return false;
        }
    }

    @PluginMethod()
    public void checkSyncStatus(PluginCall call) {
//        Log.i("Dbg", "Checking sync status: " + isWorkScheduled());

        JSObject ret = new JSObject();
        ret.put("syncing", isWorkScheduled() || UploadWorker.running);
        call.resolve(ret);
    }

    @PluginMethod()
    public void stopSync(PluginCall call) {
        Log.i("Dbg", "Stopping all work.");
        UploadWorker.stopWork = true;
        WorkManager.getInstance(this.getActivity().getApplicationContext())
                .cancelAllWork();

        call.resolve();
    }

    @PluginMethod()
    public void startSync(PluginCall call) {
        WorkManager.getInstance(this.getActivity().getApplicationContext())
                .cancelAllWork();

        WorkRequest uploadWorkRequest =
                new OneTimeWorkRequest.Builder(UploadWorker.class)
                        .build();

        WorkManager
                .getInstance(this.getActivity().getApplicationContext())
                .enqueue(uploadWorkRequest);
        
        call.resolve();
    }

    //
    // Gets the list of files scanned from the file system.
    //
    @PluginMethod()
    public void getFiles(PluginCall call) {

        JSArray files = new JSArray();
        SharedPreferences sharedPreferences = this.getActivity().getApplicationContext().getSharedPreferences("local-files", MODE_PRIVATE);
        for (Map.Entry<String, Object> entry : ((Map<String, Object>) sharedPreferences.getAll()).entrySet()) {
            String json = entry.getValue().toString();
            Gson gson = new Gson();
            FileDetails fileDetails = gson.fromJson(json, FileDetails.class);

            JSObject file = new JSObject();
            file.put("name", fileDetails.name);
            file.put("path", fileDetails.path);
            file.put("contentType", fileDetails.contentType);
            file.put("date", fileDetails.creationDate);
            files.put(file);
        }

        JSObject ret = new JSObject();
        ret.put("files", files);
        call.resolve(ret);
    }

    //
    // Converts bytes to hex values.
    //
    // https://stackoverflow.com/q/7166129/25868
    //
    private String bin2hex(byte[] data) {
        return String.format("%0" + (data.length*2) + "X", new BigInteger(1, data));
    }

    //
    // Computes the hash for a file.
    //
    // https://stackoverflow.com/a/32032908/25868
    //
    private String computeHash(File file) {
        try {
            byte[] buffer = new byte[4096];
            int count;
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            BufferedInputStream bis = new BufferedInputStream(new FileInputStream(file));
            while ((count = bis.read(buffer)) > 0) {
                digest.update(buffer, 0, count);
            }
            bis.close();

            return bin2hex(digest.digest());
        }
        catch (Exception ex) {
            Log.e("Err", "Failed to hash file " + file.getPath());
            return null;
        }
    }
    //
    // Loads a thumbnail for a file.
    //
    @PluginMethod()
    public void loadThumbnail(PluginCall call) {
        String path = call.getString("path");

        String hash = computeHash(new File(path));

        // https://developer.android.com/reference/android/graphics/Bitmap
        Bitmap origImage = BitmapFactory.decodeFile(path);

        // https://stackoverflow.com/a/6099182
        int width = origImage.getWidth();
        int height = origImage.getHeight();
        float aspectRatio = (float) width / height;
        int thumbWidth = 300;
        int thumbHeight = Math.round(thumbWidth / aspectRatio);

        // Creates a thumbnail for upload.
        // https://stackoverflow.com/a/12294235
        Bitmap thumbImage = ThumbnailUtils.extractThumbnail(origImage, thumbWidth, thumbHeight);

        ByteArrayOutputStream thumbOutputStream = new ByteArrayOutputStream();
        thumbImage.compress(Bitmap.CompressFormat.JPEG, 30, thumbOutputStream);
        String thumbnail = new String(Base64.getEncoder().encode(thumbOutputStream.toByteArray()));

        JSObject ret = new JSObject();
        ret.put("thumbnail", thumbnail);
        ret.put("width", width);
        ret.put("height", height);
        ret.put("hash", hash);
        call.resolve(ret);
    }

    //
    // Loads the full resolution image for a file.
    //
    @PluginMethod()
    public void loadFullImage(PluginCall call) {
        String path = call.getString("path");

        // https://developer.android.com/reference/android/graphics/Bitmap
        Bitmap origImage = BitmapFactory.decodeFile(path);

        ByteArrayOutputStream fullOutputStream = new ByteArrayOutputStream();
        origImage.compress(Bitmap.CompressFormat.JPEG, 100, fullOutputStream);
        String fullImage = new String(Base64.getEncoder().encode(fullOutputStream.toByteArray()));

        JSObject ret = new JSObject();
        ret.put("fullImage", fullImage);
        call.resolve(ret);
    }

}