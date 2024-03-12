package com.photosphere.codecapers;

import static android.content.Context.MODE_PRIVATE;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.location.Address;
import android.location.Geocoder;
import android.media.ExifInterface;
import android.media.ThumbnailUtils;
import android.os.storage.StorageManager;
import android.os.storage.StorageVolume;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import com.google.gson.Gson;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.math.BigInteger;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Map;

class FileDetails {
    public String name;
    public String path;
    public String contentType;
    public Date creationDate;

    public FileDetails(String name, String path, String contentType, Date creationDate) {
        this.name = name;
        this.path = path;
        this.contentType = contentType;
        this.creationDate = creationDate;
    }
}

//
// Scans the file system for files and uploads them.
//
public class UploadWorker extends Worker {

    //
    // Setting to true when the work is running.
    //
    public static boolean running = false;

    //
    // Setting this to true aborts the work.
    //
    public static boolean stopWork = false;

    public static int nextId = 0;
    public int id = ++nextId;

    //
    // Records settings.
    //
    SharedPreferences settings = getApplicationContext().getSharedPreferences("settings", MODE_PRIVATE);

    //
    // Records files that have been found.
    //
    // https://developer.android.com/reference/android/content/SharedPreferences
    // https://www.androidauthority.com/how-to-store-data-locally-in-android-app-717190/
    // https://stackoverflow.com/a/49938549/25868
    //
    SharedPreferences filePrefs = getApplicationContext().getSharedPreferences("local-files", MODE_PRIVATE);

    public UploadWorker(
            @NonNull Context context,
            @NonNull WorkerParameters params) {
        super(context, params);
    }

    @Override
    public Result doWork() {

        //
        // Delete all recorded entries.
        //
//        SharedPreferences.Editor editor = filePrefs.edit();
//        editor.clear();
//        editor.commit();

        //TODO: Would be good to mark all previously recorded files as "unchecked".

        this.running = true;
        this.stopWork = false;

        Log.v("Dbg", "Scanning file system.");

        //
        // Scan the file system for images.
        //
        this.scanFilesystem();

        Log.v("Dbg", "Finished scanning.");

        this.running = false;
        this.stopWork = false; // Reset, in case the work was stopped.

        // Indicate whether the work finished successfully with the Result
        return Result.success();
    }

    //
    // Scans the entire file system for files to upload.
    //
    private void scanFilesystem() {
        StorageManager sm = this.getApplicationContext().getSystemService(StorageManager.class);
        for (StorageVolume volume : sm.getStorageVolumes()) {

            Log.i("Dbg[" + id + "]: Scanning -> ", volume.getDirectory().getPath());
            scanDirectory(volume.getDirectory());
        }
    }

    //
    // Scans a directory to find image files.
    //
    private void scanDirectory(File directory) {

        if (stopWork) {
            Log.i("Dbg", "Stopping work.");
            return;
        }

        File[] files = directory.listFiles();
        if (files == null) {
            return;
        }

        for (File file : files) {
            if (stopWork) {
                Log.i("Dbg", "Stopping work.");
                return;
            }

            if (file.isDirectory()) {
                if (file.getName().equals(".thumbnails")) {
                    Log.i("Dbg[" + id + "]", "Skipping .thumbnails directory.");
                    continue;
                }
                scanDirectory(file);
            }
            else if (file.getName().endsWith(".png")) {
                String existingEntry = filePrefs.getString(file.getPath(), null);
                if (existingEntry == null) {
                    Log.i("Dbg[" + id + "]", "No record yet for " + file.getPath());

                    // https://developer.android.com/reference/android/content/SharedPreferences.Editor
                    SharedPreferences.Editor editor = filePrefs.edit();

                    // https://stackoverflow.com/a/18463758/25868
                    Gson gson = new Gson();
                    Date lastModifiedDate = new Date(file.lastModified());
                    String json = gson.toJson(new FileDetails(file.getName(), file.getPath(), "image/png", lastModifiedDate));
                    editor.putString(file.getPath(), json);
                    editor.commit();
                }
                else {
                    // Log.i("Dbg[" + id + "]", "Have record for " + file.getPath());

                    //TODO: Update existing entry, mark as "found".
                }
            }
            else if (file.getName().endsWith(".jpg")) {
                String existingEntry = filePrefs.getString(file.getPath(), null);
                if (existingEntry == null) {
                    Log.i("Dbg[" + id + "]", "No record yet for " + file.getPath());

                    // https://developer.android.com/reference/android/content/SharedPreferences.Editor
                    SharedPreferences.Editor editor = filePrefs.edit();

                    // https://stackoverflow.com/a/18463758/25868
                    Gson gson = new Gson();
                    Date lastModifiedDate = new Date(file.lastModified());
                    String json = gson.toJson(new FileDetails(file.getName(), file.getPath(), "image/jpeg", lastModifiedDate));
                    editor.putString(file.getPath(), json);
                    editor.commit();
                }
                else {
                    // Log.i("Dbg[" + id + "]", "Have record for " + file.getPath());

                    //TODO: Update existing entry, mark as "found".
                }
            }
        }
    }
}
