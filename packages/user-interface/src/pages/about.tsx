import React from "react";

export function AboutPage() {
    return (
        <div className="w-full h-full p-4 overflow-y-auto pb-32">
            <div className="m-auto" style={{maxWidth: "800px"}}>
                <h1 className="mt-6 text-3xl">About Photosphere</h1>

                <p className="pt-4">Photosphere is developed by <a target="_blank" href="https://codecapers.com.au/about">Ashley Davis</a>.</p>

                <p className="pt-4">
                    Photosphere is a cross-platform application for managing your database of digital media files (photos and videos). 
                    I like to think of it as the spiritual successor to Picasa but with a UI more like modern Google Photos and backed 
                    by a Git-style database for immutable binary assets like photos and videos that have editable metadata.
                </p>

                <p>
                    I'm building Photopshere to search, edit and protect the photos, videos and other digital assets for myself and my family, whilst being able
                    to control the storage, encryption and privacy of those assets.
                </p>

                <p className="pt-4">
                    This software is open source. The current version is ready for technical users to try out and give feedback.
                    In 2026 I plan to finish the GUI apps (mobile and desktop) that will open Photosphere up to non-technical users.
                    If you would like to use Photosphere in the future, please send me an email on <a href="mailto:ashley@codecapers.com.au">ashley@codecapers.com.au</a>.
                </p>

                <p className="pt-4">
                    The big concept of Photosphere is that you bring your own storage from one of the major cloud vendors,
                    like Digital Ocean Spaces or AWS S3, and that's basically all you need. 
                    This software uses no traditional database, it reads metadata and assets directly from cloud storage.
                    Assets stored in the cloud can be encrypted to ensure they are kept safe no matter what happens.
                </p>
 
                <p className="text-xl pt-4">
                    The early development of Photosphere is examined in the book <a target="_blank" href="https://www.manning.com/books/the-feedback-driven-developer">The Feedback-Driven Developer</a>.
                    Buy the book to support the development of this software.
                </p>

                <p className="pt-4">
                    Thanks to Pexel and Unsplash for the images used in this demo of Photosphere.
                </p>
            </div>
        </div>
    );
}