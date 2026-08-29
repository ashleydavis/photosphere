package au.com.codecapers.photosphere.jsengine;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.FileInputStream;

//
// Hands a WebP to ImageMagick as a PNG, because the bundled Android build cannot read one.
//
// The prebuilt Android-ImageMagick7 libraries report WebP support and read a WebP header fine, but
// decoding the pixels of one that carries an alpha channel dereferences a null inside WebPDecode.
// In the standalone `magick` binary that surfaces as a failed exit; in this app ImageMagick runs
// in-process, so the same null takes the whole app down. An import of a real photo library hit it
// on the first such image and died there every time, always on the same one.
//
// Android's own decoder reads those files without trouble, so a WebP is decoded here and ImageMagick
// is handed the PNG instead. PNG because it is lossless and keeps the alpha, and because everything
// ImageMagick is asked to do with the file afterwards produces a derived image anyway. Only the
// input substitution happens here: the original file is untouched, so what gets hashed and stored
// is still the file the library gave us.
//
// Every WebP is converted, not just the ones with alpha, because telling them apart means parsing
// the chunk table and the difference is one platform decode of a rare file.
//
public class WebPInput {

    //
    // The bytes a RIFF container starts with, and the four that name it as WebP at offset 8.
    //
    private static final byte[] RIFF_MAGIC = { 'R', 'I', 'F', 'F' };
    private static final byte[] WEBP_MAGIC = { 'W', 'E', 'B', 'P' };

    //
    // How many bytes have to be read to recognise the container.
    //
    private static final int HEADER_LENGTH = 12;

    //
    // Quality passed to the PNG encoder. PNG ignores it, but compress() demands one.
    //
    private static final int PNG_QUALITY = 100;

    //
    // Which element of an ImageMagick argv names the file being read.
    //
    // The shared TypeScript builds every argv starting with the input path, except the identify
    // form, where "identify" comes first and the path follows it. Anything shorter than that has no
    // input to substitute.
    //
    public static int inputPathIndex(String[] args) {
        if (args.length > 1 && "identify".equals(args[0])) {
            return 1;
        }

        if (args.length > 0) {
            return 0;
        }

        return -1;
    }

    //
    // Whether the named file is a WebP, judged by its own first bytes rather than its name.
    //
    // A file too short to hold the header, or one that cannot be opened, is simply not a WebP as far
    // as this is concerned: it is ImageMagick's job to report what is wrong with it.
    //
    public static boolean isWebP(File file) {
        byte[] header = new byte[HEADER_LENGTH];
        try (InputStream input = new FileInputStream(file)) {
            int read = 0;
            while (read < HEADER_LENGTH) {
                int got = input.read(header, read, HEADER_LENGTH - read);
                if (got < 0) {
                    return false;
                }
                read += got;
            }
        }
        catch (IOException error) {
            return false;
        }

        return startsWith(header, 0, RIFF_MAGIC) && startsWith(header, 8, WEBP_MAGIC);
    }

    //
    // Whether the four bytes at the given offset are the given marker.
    //
    static boolean startsWith(byte[] header, int offset, byte[] marker) {
        for (int index = 0; index < marker.length; index += 1) {
            if (header[offset + index] != marker[index]) {
                return false;
            }
        }

        return true;
    }

    //
    // Decodes a WebP with Android's decoder and writes it as a PNG, returning the file written.
    //
    // Throws when the decode or the encode fails, so an image that cannot be converted stops the task
    // that asked for it rather than quietly going to ImageMagick and taking the app down.
    //
    public static File decodeToPng(File source, File outputDir) {
        Bitmap bitmap = BitmapFactory.decodeFile(source.getAbsolutePath());
        if (bitmap == null) {
            throw new RuntimeException("Android could not decode the WebP \"" + source.getAbsolutePath() + "\"");
        }

        File output = new File(outputDir, source.getName() + ".png");
        try (FileOutputStream stream = new FileOutputStream(output)) {
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, PNG_QUALITY, stream)) {
                throw new RuntimeException("Failed writing the decoded WebP to \"" + output.getAbsolutePath() + "\"");
            }
        }
        catch (IOException error) {
            throw new RuntimeException("Failed writing the decoded WebP to \"" + output.getAbsolutePath() + "\": " + error.getMessage(), error);
        }
        finally {
            bitmap.recycle();
        }

        return output;
    }
}
