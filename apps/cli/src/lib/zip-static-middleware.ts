import { Request, Response, NextFunction } from 'express';
import AdmZip from 'adm-zip';
import path from 'path';
import mime from 'mime';

//
// Creates Express middleware that serves static files from an in-memory zip file.
//
export function createZipStaticMiddleware(zipBuffer: Buffer, basePath: string = ''): (req: Request, res: Response, next: NextFunction) => void {
    const zip = new AdmZip(zipBuffer);
    const entries = new Map<string, AdmZip.IZipEntry>();

    // Build a map of all file paths in the zip
    zip.getEntries().forEach(entry => {
        if (!entry.isDirectory) {
            // Normalize the path and remove basePath prefix if provided
            let entryPath = entry.entryName.replace(/\\/g, '/');
            if (basePath && entryPath.startsWith(basePath)) {
                entryPath = entryPath.slice(basePath.length);
            }
            if (!entryPath.startsWith('/')) {
                entryPath = '/' + entryPath;
            }
            entries.set(entryPath, entry);
        }
    });

    return (req: Request, res: Response, next: NextFunction) => {
        // Only handle GET and HEAD requests
        if (req.method !== 'GET' && req.method !== 'HEAD') {
            return next();
        }

        // Clean up the request path
        let requestPath = decodeURIComponent(req.path);
        
        // Try to find the exact file
        let entry = entries.get(requestPath);
        
        // If not found and path ends with /, try index.html
        if (!entry && requestPath.endsWith('/')) {
            entry = entries.get(requestPath + 'index.html');
        }
        
        // If still not found and path doesn't have an extension, try index.html
        if (!entry && !path.extname(requestPath)) {
            entry = entries.get(requestPath + '/index.html');
        }

        if (!entry) {
            // File not found in zip, pass to next middleware
            return next();
        }

        // Get the file content from the zip
        const content = zip.readFile(entry);
        if (!content) {
            return next();
        }

        // Set content type based on file extension
        const mimeType = mime.getType(entry.entryName) || 'application/octet-stream';
        res.setHeader('Content-Type', mimeType);
        res.setHeader('Content-Length', content.length);
        
        // Set cache headers for static assets
        if (mimeType.startsWith('image/') || mimeType.startsWith('font/') || 
            requestPath.includes('.js') || requestPath.includes('.css')) {
            res.setHeader('Cache-Control', 'public, max-age=31536000');
        }

        // Send the file content
        if (req.method === 'HEAD') {
            res.end();
        } else {
            res.send(content);
        }
    };
}