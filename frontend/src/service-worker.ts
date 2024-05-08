//
// This service worker allows offline access to static assets.
//
// https://css-tricks.com/add-a-service-worker-to-your-site/
// https://joshuatz.com/posts/2021/strongly-typed-service-workers/
//

// @ts-check
/// <reference no-default-lib="true"/>
/// <reference lib="ES2017" />
/// <reference lib="webworker" />

self.addEventListener('fetch', (event: any) => {

    // Bug fix
    // https://stackoverflow.com/a/49719964
    if (event.request.cache === 'only-if-cached' && event.request.mode !== 'same-origin') {
        return;
    }

    event.respondWith(
        fetch(event.request)
            .then(response => {    
                // Create a copy of the response and save it to the cache.
                let copy = response.clone();
                event.waitUntil(caches.open('app')
                    .then(cache => {
                        return cache.put(event.request, copy);
                    }));
    
                // Return the response
                return response;    
            })
            .catch(error => {
                return caches.match(event.request);
            })
    );    
});    