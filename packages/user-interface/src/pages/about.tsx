import React from "react";
import { version } from "config";

export function AboutPage() {
    return (
        <div className="w-full h-full p-4 overflow-y-auto pb-32">
            <div className="m-auto" style={{maxWidth: "800px"}}>
                <h1 className="mt-6 text-3xl">About Photosphere</h1>
                <p className="pt-2 text-gray-500">Version {version}</p>

                <p className="pt-4">Photosphere is developed by <a target="_blank" href="https://codecapers.com.au/about">Ashley Davis</a>.</p>

                <p className="pt-4">
                    Photosphere is a local-first application for managing your database of digital media files (photos and videos). Think of it as the spiritual successor to Picasa, but with a UI more like modern Google Photos, backed by a Git-style database for immutable binary files with editable metadata.
                </p>

                <p className="pt-4">
                    Important features:
                </p>
                <ul className="pt-2 list-disc list-inside">
                    <li>Local first so you own it and you control it.</li>
                    <li>Open source so you can understand what it does with your files.</li>
                    <li>Maintain data sovereignty: the storage and privacy of your files are under your control.</li>
                    <li>Build a corruption resistant database of your digital media files.</li>
                    <li>Backup your database and keep your backup updated.</li>
                    <li>Bidirectional synchronization between databases on different devices.</li>
                    <li>Detect and repair corrupt files.</li>
                    <li>Securely encrypt files that you store in the cloud vendor of your choice.</li>
                    <li>Use the GUI to search, view and edit your photos and videos.</li>
                </ul>

                <p className="pt-4">
                    Early development of Photosphere was covered in the book <a target="_blank" href="https://tfdd.codecapers.com.au/">The Feedback-Driven Developer</a>.
                </p>

            </div>
        </div>
    );
}