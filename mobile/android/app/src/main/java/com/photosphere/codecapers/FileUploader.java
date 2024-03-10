package com.photosphere.codecapers;

import static android.content.Context.MODE_PRIVATE;

import android.content.Intent;
import android.content.SharedPreferences;
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

import java.util.ArrayList;
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
            file.put("type", fileDetails.contentType);
            file.put("hash", fileDetails.hash);
            file.put("uploaded", fileDetails.uploaded);
            file.put("date", fileDetails.creationDate);
            files.put(file);
        }

        JSObject ret = new JSObject();
        ret.put("files", files);
        call.resolve(ret);
    }
}