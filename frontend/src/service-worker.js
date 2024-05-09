//
// This service worker allows offline access to static assets.
//
// - https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API
// - https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API/Using_Service_Workers#the_premise_of_service_workers
// - https://developer.mozilla.org/en-US/docs/Web/API/FetchEvent/respondWith
// - https://css-tricks.com/add-a-service-worker-to-your-site/
//
// Debugging:
//  https://www.chromium.org/blink/serviceworker/service-worker-faq/
//
// From Developer Tools > Application > Service Workers, check "Update on reload" and reload the page.
//
// To view running service workers:
//  chrome://inspect/#service-workers
//  chrome://serviceworker-internals/
//

const CACHE_NAME = 'photosphere-v1';

//
// On fetch, return the cached resources.
//
self.addEventListener("fetch", event => {
    event.respondWith(networkFirst(event.request));
});

//
// Puts a response in the cache.
//
async function cacheResponse(request, response) {
    const cache = await caches.open(CACHE_NAME);
    await cache.put(request, response);

    // console.log(`✔ Cached response for HTTP ${request.method} ${request.url}`);
};

//
// The types of assets that can be cached.
//
const cachableDestinations = [
    "document",
    "script",
    "style",
    "font",
];

//
// Checks if the destination type is cacheable.
//
function isCacheable(destination) {
    for (const cachableDestination of cachableDestinations) {
        if (destination === cachableDestination) {
            // console.log(`## Cacheable destination: ${destination}`);
            return true;
        }
    }

    // console.log(`## Uncacheable destination: ${destination}`);
    return false;
}

//
// Fetch using a network-first strategy.
//
async function networkFirst(request) {
    try {
        //
        // Fetch the resource from the network.
        //
        // console.log(`>> HTTP ${request.method} ${request.url} from network.`);

        const responseFromNetwork = await fetch(request);

        // console.log(`<< Response to ${request.url}:`); 
        // console.log(responseFromNetwork);
        // console.log(`== ${responseFromNetwork.headers.get("Content-Type")}`);

        // console.log("Response headers:");
        // for (const [key, value] of responseFromNetwork.headers.entries()) {
        //     console.log(`${key}: ${value}`);
        // }

        if (request.url.startsWith("http://") || request.url.startsWith("https://")) {
            if (isCacheable(request.destination)) {
                //
                // Cache the response.
                //
                // Cloning the response is necessary because request and response streams can only be read once.
                //
                cacheResponse(request, responseFromNetwork.clone())
                    .catch(err => {
                        console.error(`Failed to cache response for HTTP ${request.method} ${request.url}`);
                        console.error(err);
                    });
            }
            else {
                if (request.destination) {
                    console.log(`!! Not caching request with destination: ${request.destination || "unknown"}`);
                }
                else {
                    // console.log(`!! Not caching request with unknown destination. Request = ${request.url}`);
                }
            }
        }

        return responseFromNetwork;
    }
    catch (err) {
        console.error(`Failed to fetch Request ${request.method} ${request.url} from network.`);
        console.error(err);

        //
        // Fetching the resource from the network failed. Try to get it from the cache.
        //
        // console.log(`>> Request ${request.method} ${request.url} from cache.`);
        const responseFromCache = await caches.match(request);
        if (responseFromCache) {
            //
            // Request is satsified from the cache.
            //
            // console.log(`Request satisfied from cache: Request ${request.method} ${request.url}`);
            return responseFromCache;
        }

        //
        // There is nothing in the cache and a network error happened.
        //
        const message = `An error happened while fetching Request ${request.method} ${request.url}]\r\n${err}`;
        return new Response(message, {
            status: 408,
            headers: { "Content-Type": "text/plain" },
        });        
    }
}
