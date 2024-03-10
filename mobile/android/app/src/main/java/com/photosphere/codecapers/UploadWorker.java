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
    public String hash;
    public Boolean uploaded;
    public Date creationDate;

    public FileDetails(String name, String path, String contentType, Date creationDate) {
        this.name = name;
        this.path = path;
        this.contentType = contentType;
        this.hash = null;
        this.uploaded = false;
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

        Log.v("Dbg", "Uploading files.");

        //
        // Upload files that have been found.
        //
        this.uploadFiles();

        Log.v("Dbg", "Finished scanning and uploading.");

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
    // Scans a directory and uploads files.
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
                    Log.i("Dbg[" + id + "]", "Have record for " + file.getPath());

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
                    Log.i("Dbg[" + id + "]", "Have record for " + file.getPath());

                    //TODO: Update existing entry, mark as "found".
                }
            }
        }
    }

    //
    // Upload files.
    //
    private void uploadFiles() {
        // https://stackoverflow.com/a/18463758/25868
        Gson gson = new Gson();

        for (Map.Entry<String, Object> entry : ((Map<String, Object>) filePrefs.getAll()).entrySet()) {
            if (stopWork) {
                Log.i("Dbg", "Stopping work.");
                return;
            }

            String filePath = entry.getKey();
            File file = new File(filePath);
            String json = entry.getValue().toString();
            FileDetails fileDetails = gson.fromJson(json, FileDetails.class);

            String hash = computeHash(file);
            if (!hash.equals(fileDetails.hash)) {
                Log.i("Dbg[" + id + "]", "No hash or hash changed for " + filePath + "\n"
                                                 + "Old hash: " + fileDetails.hash + "\n"
                                                 + "New hash: " + hash);

                //
                // Hash isn't set yet or this is a different file!
                //
                fileDetails.hash = hash;
                fileDetails.uploaded = false;

                //
                // Save hash.
                //
                SharedPreferences.Editor editor = filePrefs.edit();
                editor.putString(filePath, gson.toJson(fileDetails));
                editor.commit();
            }

            if (!fileDetails.uploaded) {
                boolean isUploaded = checkUploaded(fileDetails.hash);
                if (!isUploaded) {
                    Log.i("Dbg[" + id + "]", "Uploading " + filePath);

                    this.uploadFile(file, fileDetails.hash, fileDetails.contentType);

                    fileDetails.uploaded = true;

                    //
                    // Save uploaded state.
                    //
                    SharedPreferences.Editor editor = filePrefs.edit();
                    editor.putString(filePath, gson.toJson(fileDetails));
                    editor.commit();
                }
                else {
                    Log.v("Dbg[" + id + "]", "Checked with server, Already uploaded: " + filePath);
                }
            }
            else {
                Log.v("Dbg[" + id + "]", "Already uploaded: " + filePath);
            }
        }
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
    // Checks if a file has been uploaded already.
    //
    public boolean checkUploaded(String hash) {
        try {
            String baseURL = settings.getString("backend", null);
            URL url = new URL(baseURL + "/check-asset?hash=" + hash);
            HttpURLConnection urlConnection = (HttpURLConnection) url.openConnection();
            urlConnection.setRequestMethod("GET");
            urlConnection.connect();
            int responseCode = urlConnection.getResponseCode();
            urlConnection.disconnect();
            return responseCode == 200;
        }
        catch (Exception ex) {
            Log.e("Err", "Failed connecting to server.\r\n" + ex.toString());
            return false;
        }
    }

    //
    // Converts a bitmap to an input stream for upload.
    //
    // http://www.java2s.com/example/android/graphics/convert-bitmap-to-inputstream.html
    // https://developer.android.com/reference/android/graphics/Bitmap
    //
    private InputStream bitmap2InputStream(Bitmap bm, int quality) {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        bm.compress(Bitmap.CompressFormat.JPEG, quality, baos);
        InputStream inputStream = new ByteArrayInputStream(baos.toByteArray());
        return inputStream;
    }

    //
    // Uploads a file to the Photosphere backend.
    //
    // https://developer.android.com/reference/java/net/HttpURLConnection
    // https://gist.github.com/luankevinferreira/5221ea62e874a9b29d86b13a2637517b
    //
    private void uploadFile(File file, String hash, String contentType) {
        HttpURLConnection urlConnection = null;
        try {
            // https://developer.android.com/reference/android/graphics/Bitmap
            Bitmap origImage = BitmapFactory.decodeFile(file.getPath()); // TODO: This might load the entire file!

            // https://stackoverflow.com/a/6099182
            int width = origImage.getWidth();
            int height = origImage.getHeight();

            //
            // Get exif data.
            // TODO: Be good to convert this to JSON to so it can be uploaded to the backend.
            //
            // https://developer.android.com/reference/android/media/ExifInterface
            //
            // ExifInterface exifInterface = new ExifInterface(new FileInputStream(file));
            ExifInterface exifInterface = new ExifInterface(file);

            //Log.i("Dbg", "=============================== Location =============================");

            float[] latLong = new float[2];
            String location = null;
            if (exifInterface.getLatLong(latLong)) {
                //Log.i("Dbg", "Latitude: " + latLong[0]);
                //Log.i("Dbg", "Longitude: " + latLong[1]);

                //
                // Reverse geocode the location.
                //
                Geocoder geocoder = new Geocoder(getApplicationContext(), Locale.getDefault());
                // https://developer.android.com/reference/android/location/Address
                List<Address> addresses = geocoder.getFromLocation(latLong[0], latLong[1], 1);
                if (addresses.size() > 0) {
                    //Log.i("Dbg", addresses.get(0).toString());
                    location = addresses.get(0).toString(); //TODO: How can I format this correctly?
                }
                else {
                    //Log.i("Dbg", "No location!");
                }
            }

//            Log.i("Dbg", "============================= Exif =============================");

            JSONObject exif = new JSONObject();

            for (String attribute : exifAttributes) {
                String value = exifInterface.getAttribute(attribute);
                //Log.i("Dbg", attribute + " = " + value);
                exif.put(attribute, value);
            }

            // Creates a thumbnail for upload.
            // TODO: Would like to get the aspect ratio correct.
            // https://stackoverflow.com/a/12294235
            Bitmap thumbImage = ThumbnailUtils.extractThumbnail(origImage, 100, 100);

            ByteArrayOutputStream thumbOutputStream = new ByteArrayOutputStream();
            thumbImage.compress(Bitmap.CompressFormat.JPEG, 30, thumbOutputStream);
            String thumbnail = new String(Base64.getEncoder().encode(thumbOutputStream.toByteArray()));

            JSONObject metadata = new JSONObject();
            metadata.put("contentType", contentType);
            metadata.put("thumbContentType", "image/jpeg");
            metadata.put("fileName", file.getName());
            metadata.put("width", width);
            metadata.put("height", height);
            metadata.put("hash", hash);
            metadata.put("exif", exif);
            if (location != null) {
                metadata.put("location", location);
            }
            
            String baseURL = settings.getString("backend", null);
            URL url = new URL(baseURL + "/asset");
            urlConnection = (HttpURLConnection) url.openConnection();

            urlConnection.setUseCaches(false);
            urlConnection.setDoOutput(true);
            urlConnection.setRequestMethod("POST");
            urlConnection.setChunkedStreamingMode(0);
            urlConnection.setRequestProperty("content-type", contentType);
            urlConnection.setRequestProperty("metadata", metadata.toString());
            urlConnection.setRequestProperty("thumbnail", thumbnail);

            BufferedOutputStream bos = new BufferedOutputStream(urlConnection.getOutputStream());
            // Uploads the original file.
            BufferedInputStream bis = new BufferedInputStream(new FileInputStream(file));

            int i;
            byte[] buffer = new byte[4096];
            while ((i = bis.read(buffer)) > 0) {
                bos.write(buffer, 0, i);
            }
            bis.close();
            bos.close();

            InputStream inputStream;
            int responseCode = ((HttpURLConnection) urlConnection).getResponseCode();
            if ((responseCode >= 200) && (responseCode <= 202)) {
                inputStream = ((HttpURLConnection) urlConnection).getInputStream();
                int j;
                while ((j = inputStream.read()) > 0) {
                    //System.out.println(j);
                }
            }
        }
        catch (Exception ex) {
            Log.e("Error", "Failed to upload file " + file.getPath() + "\n" + ex.toString());
        }
        finally {
            if (urlConnection != null) {
                urlConnection.disconnect();
            }
        }
    }

    //
    // All exif attributes.
    //
    // https://gist.github.com/hypothermic/952fd9c49cbdcbab58177a5c0eaf72a5
    //
    private static final String[] exifAttributes = new String[] {
            "FNumber", "ApertureValue", "Artist", "BitsPerSample", "BrightnessValue", "CFAPattern", "ColorSpace", "ComponentsConfiguration",
            "CompressedBitsPerPixel", "Compression", "Contrast", "Copyright", "CustomRendered", "DateTime", "DateTimeDigitized", "DateTimeOriginal",
            "DefaultCropSize", "DeviceSettingDescription","DigitalZoomRatio", "DNGVersion", "ExifVersion", "ExposureBiasValue", "ExposureIndex",
            "ExposureMode",  "ExposureProgram", "ExposureTime", "FileSource", "Flash", "FlashpixVersion", "FlashEnergy", "FocalLength", "FocalLengthIn35mmFilm",
            "FocalPlaneResolutionUnit", "FocalPlaneXResolution", "FocalPlaneYResolution", "FNumber", "GainControl", "GPSAltitude", "GPSAltitudeRef",
            "GPSAreaInformation", "GPSDateStamp", "GPSDestBearing", "GPSDestBearingRef", "GPSDestDistance", "GPSDestDistanceRef", "GPSDestLatitude",
            "GPSDestLatitudeRef", "GPSDestLongitude", "GPSDestLongitudeRef", "GPSDifferential", "GPSDOP", "GPSImgDirection", "GPSImgDirectionRef",
            "GPSLatitude", "GPSLatitudeRef", "GPSLongitude", "GPSLongitudeRef", "GPSMapDatum", "GPSMeasureMode", "GPSProcessingMethod", "GPSSatellites",
            "GPSSpeed", "GPSSpeedRef", "GPSStatus", "GPSTimeStamp", "GPSTrack", "GPSTrackRef", "GPSVersionID", "ImageDescription", "ImageLength", "ImageUniqueID",
            "ImageWidth", "InteroperabilityIndex", "ISOSpeedRatings", "ISOSpeedRatings", "JPEGInterchangeFormat", "JPEGInterchangeFormatLength", "LightSource",
            "Make", "MakerNote", "MaxApertureValue", "MeteringMode", "Model", "NewSubfileType", "OECF", "AspectFrame", "PreviewImageLength", "PreviewImageStart",
            "ThumbnailImage", "Orientation", "PhotometricInterpretation", "PixelXDimension", "PixelYDimension", "PlanarConfiguration", "PrimaryChromaticities",
            "ReferenceBlackWhite", "RelatedSoundFile", "ResolutionUnit", "RowsPerStrip", "ISO", "JpgFromRaw", "SensorBottomBorder", "SensorLeftBorder",
            "SensorRightBorder", "SensorTopBorder", "SamplesPerPixel", "Saturation", "SceneCaptureType", "SceneType", "SensingMethod", "Sharpness",
            "ShutterSpeedValue", "Software", "SpatialFrequencyResponse", "SpectralSensitivity", "StripByteCounts", "StripOffsets", "SubfileType",
            "SubjectArea", "SubjectDistance", "SubjectDistanceRange", "SubjectLocation", "SubSecTime", "SubSecTimeDigitized", "SubSecTimeDigitized",
            "SubSecTimeOriginal", "SubSecTimeOriginal", "ThumbnailImageLength", "ThumbnailImageWidth", "TransferFunction", "UserComment", "WhiteBalance",
            "WhitePoint", "XResolution", "YCbCrCoefficients", "YCbCrPositioning", "YCbCrSubSampling", "YResolution"
    };
}
