import axios from "axios";

//
// https://developers.google.com/maps/documentation/javascript
// 
// Setup up project: https://developers.google.com/maps/documentation/javascript/cloud-setup
// Using API keys: https://developers.google.com/maps/documentation/javascript/get-api-key
// Reverse geocoding: https://developers.google.com/maps/documentation/javascript/examples/geocoding-reverse
// Had to wait 10 mins for the API key to come online: https://stackoverflow.com/a/27463276/25868
// I had to enable Maps, Places and Geocoding APIs to get the key to work.
//
// https://github.com/zhso/reverse-geocoding/blob/6ab209acd2c4d32438c947ecbd5bf4d50f4c5b8d/src/index.js#L18
//

const GOOGLE_API_KEY = process.env.GOOGLE_API_KEY;

//
// Represents a GPS location.
//
export interface ILocation {
    lat: number;
    lng: number;
}

//
// Reverse geocode the requested location (needs lat and lng fields).
//
// You must set an approriately configured Google API key in the environment variable GOOGLE_API_KEY for this to work.
//
export async function reverseGeocode(location: ILocation): Promise<string | undefined> {

    if (!GOOGLE_API_KEY) {
        return undefined;
    }

    const url = `https://maps.googleapis.com/maps/api/geocode/json?latlng=${location.lat},${location.lng}&key=${GOOGLE_API_KEY}`
    const { data } = await axios.get(url);

    if (data.results && data.results.length > 0) {
        return data.results[0].formatted_address;
    }

    return undefined;
}
