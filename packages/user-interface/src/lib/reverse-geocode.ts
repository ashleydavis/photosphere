//
// Reverse geocodes a lat/lng coordinate to a human-readable location string using Nominatim.
// Builds a composite string from the most useful address parts (street, suburb, city).
// Returns undefined if the request fails or no name can be determined.
//
export async function reverseGeocode(lat: number, lng: number): Promise<string | undefined> {
    const url = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}`;
    try {
        const response = await fetch(url, { headers: { "Accept-Language": "en" } });
        const data = await response.json();
        const address = data.address;
        if (!address) {
            return data.display_name || undefined;
        }

        const parts: string[] = [];

        const streetParts: string[] = [];
        if (address.house_number) {
            streetParts.push(address.house_number);
        }
        if (address.road) {
            streetParts.push(address.road);
        }
        if (streetParts.length > 0) {
            parts.push(streetParts.join(" "));
        }

        const suburb = address.suburb || address.neighbourhood || address.quarter;
        if (suburb) {
            parts.push(suburb);
        }

        const city = address.city || address.town || address.village || address.municipality;
        if (city) {
            parts.push(city);
        }

        if (parts.length === 0) {
            const fallback = address.county || address.state || address.country;
            if (fallback) {
                parts.push(fallback);
            }
        }

        return parts.length > 0 ? parts.join(", ") : (data.display_name || undefined);
    }
    catch {
        return undefined;
    }
}
