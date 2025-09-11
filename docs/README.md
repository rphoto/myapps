# Photos Export GPS Fixer Application

Applications included in this repository are freely available under the enclosed license. 

**No support or warranty provided**

## Important: Use at Your Own Risk

We've tested the app with thousands of images and built in multiple safeguards, including **Dry Run** mode and automatic `.xmp-original` backups. However, no process is perfect and unexpected issues can occur.

**You run this app at your own risk. We cannot be responsible for loss or damage.** Please keep backups of your photo libraries and metadata.

---

## The Problem

Apple Photos on macOS exports GPS metadata in XMP files that does not work correctly with apps like Adobe Lightroom. Whether it's a bug or feature doesn't really matter—the fact is that Adobe Lightroom (and likely other apps) don't handle the GPS location data correctly.

When you export images from macOS Photos with XMP sidecar files, the GPS data in those XMPs do not include the hemisphere reference (Ref) value due to a bug/feature in Apple Photos. Applications like Adobe Lightroom do not correctly interpret these coordinates, particularly for photos taken in locations where the latitude or longitude are negative.

The bottom line is that Apple is not including the `GPSLatitudeRef`/`GPSLongitudeRef` values within the `GPSLatitude`/`GPSLongitude` coordinates in the XMP files they generate.

## The Solution

PhotosExportGPSFixer will repair GPS location metadata in RAW photos exported by Apple Photos using "Export Unmodified Original..." with "export IPTC as XMP" enabled. This makes the photos compatible with Lightroom and other photo editors that expect the hemisphere reference to be embedded in the latitude/longitude data.

### Understanding GPS Reference Values

The reference (Ref) values specify the hemisphere:

- **GPSLatitudeRef:**
  - N: North (positive latitude)
  - S: South (negative latitude)
- **GPSLongitudeRef:**
  - E: East (positive longitude)
  - W: West (negative longitude)

### Example Fix

**Original XMP from Apple Photos:**
```xml
<exif:GPSLatitudeRef>N</exif:GPSLatitudeRef>
<exif:GPSLatitude>6.0448043333333334</exif:GPSLatitude>
<exif:GPSLongitudeRef>W</exif:GPSLongitudeRef>
<exif:GPSLongitude>75.93732</exif:GPSLongitude>
```

**Fixed XMP (compatible with Lightroom, etc):**
```xml
<exif:GPSLatitudeRef>N</exif:GPSLatitudeRef>
<exif:GPSLatitude>6.0448043333333334N</exif:GPSLatitude>
<exif:GPSLongitudeRef>W</exif:GPSLongitudeRef>
<exif:GPSLongitude>75.93732W</exif:GPSLongitude>
```

The application adds the hemisphere reference letter (N/S/E/W) to the end of the coordinate values and handles all necessary conversions while ensuring the XMP values remain consistent with the original RAW file data.

## How to Use

Simply drag and drop a folder of images onto Photos Export GPS Fixer. The application will:

1. Scan your exported images and their XMP sidecars
2. Compare the embedded GPS data in the image files to the XMP metadata
3. Correct the XMP formatting of `GPSLatitude` and `GPSLongitude` so your photos import into other software with the correct location

## Features

- **File Format Support:** Works with HEIC, HEIF, and DNG exports from macOS Photos
- **Conservative Updates:** Never creates new XMP files—only updates existing ones
- **Automatic Backups:** Creates a backup `.xmp-original` file (only when one does not already exist)
- **Non-Destructive to Image files:** Does not change the RAW image files, only the XMP metadata files
- **Batch Processing:** Process entire folders or single photos via drag and drop
- **Preview Mode:** Optional dry-run mode enabled by default to preview changes before making any modifications
