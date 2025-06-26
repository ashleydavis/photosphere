# Setting up Google Cloud for Photosphere Reverse Geocoding

Photosphere can automatically determine the location names (city, state, country) from the GPS coordinates embedded in your photos and videos. This feature is called "reverse geocoding" and requires a Google Cloud Platform API key.

## Why Do You Need This?

When you take photos with your phone or camera, they often include GPS coordinates showing exactly where the photo was taken. However, coordinates like "37.7749, -122.4194" aren't very meaningful to humans. Reverse geocoding converts these coordinates into human-readable locations like "San Francisco, CA, United States".

## Setting up Google Cloud Platform

### Step 1: Create a Google Cloud Project

1. Go to the [Google Cloud Console](https://console.cloud.google.com/)
2. Sign in with your Google account
3. Click **"New Project"** or use the project selector at the top
4. Enter a project name (e.g., "Photosphere Geocoding")
5. Click **"Create"**

### Step 2: Enable the Geocoding API

1. In your project dashboard, go to **"APIs & Services" > "Library"**
2. Search for **"Geocoding API"**
3. Click on **"Geocoding API"** from the results
4. Click **"Enable"**

### Step 3: Create an API Key

1. Go to **"APIs & Services" > "Credentials"**
2. Click **"+ Create Credentials"** and select **"API Key"**
3. Your new API key will be generated and displayed
4. **Important**: Copy this key and save it securely - you'll need it for Photosphere

### Step 4: Secure Your API Key (Recommended)

For security, you should restrict your API key to only work with the Geocoding API:

1. In the API key list, click the **pencil icon** next to your new key
2. Under **"API restrictions"**, select **"Restrict key"**
3. Check **"Geocoding API"** from the list
4. Click **"Save"**

## Understanding Costs

Google Cloud provides a free tier for the Geocoding API:
- **Free quota**: 40,000 requests per month
- **Cost after free tier**: $5.00 per 1,000 requests

### How Many Requests Will You Use?

Each photo or video with GPS coordinates requires one geocoding request. For example:
- **1,000 photos**: 1,000 requests (well within free tier)
- **10,000 photos**: 10,000 requests (still within free tier)
- **50,000 photos**: 50,000 requests (would cost ~$50 for the extra 10,000)

Photosphere is smart about caching results, so if you have multiple photos from the same location, it won't make duplicate requests.

## Adding Your API Key to Photosphere

### During Initial Setup

When you run `psi init`, Photosphere will ask if you want to configure reverse geocoding and prompt you for your Google API key.

### Adding Later

You can add or update your API key anytime using:

```bash
psi configure --google-api-key
```

### What Happens Without an API Key?

If you don't provide a Google API key:
- Your photos and videos will still be imported normally
- GPS coordinates will be stored (if present in the files)
- Location names will not be automatically determined
- You can add the API key later and run a command to geocode existing photos

## Troubleshooting

### "API key not valid" Error

1. Make sure you copied the full API key correctly
2. Verify the Geocoding API is enabled in your Google Cloud project
3. Check that your API key isn't restricted to specific IPs (unless intentional)

### Quota Exceeded Error

1. Check your usage in the Google Cloud Console under **"APIs & Services" > "Quotas"**
2. If you've exceeded the free tier, consider:
   - Enabling billing to continue with paid usage
   - Waiting until next month for the quota to reset
   - Temporarily disabling geocoding in Photosphere

### High Costs

If you're seeing unexpected costs:
1. Check for duplicate locations that should be cached
2. Consider if you have an unusually large number of unique photo locations
3. Review your API usage in the Google Cloud Console

## Security Best Practices

1. **Never share your API key publicly** (don't commit it to version control)
2. **Use API restrictions** to limit the key to only the Geocoding API
3. **Monitor usage** regularly in the Google Cloud Console
4. **Set up billing alerts** to notify you of unexpected usage

## Privacy Considerations

- Google will receive the GPS coordinates from your photos for geocoding
- Photosphere caches location results locally to minimize API calls
- No actual photo content is sent to Google - only coordinates
- Consider if you're comfortable with Google knowing the locations where you take photos

## Need Help?

If you encounter issues with Google Cloud setup:
- Check the [Google Cloud Geocoding API documentation](https://developers.google.com/maps/documentation/geocoding)
- Review your project settings in the Google Cloud Console
- Create an issue on the [Photosphere GitHub repository](https://github.com/ashleydavis/photosphere/issues)