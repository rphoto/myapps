# Photos Export GPS Fixer Application
Applications included in this repository are freely available under enclosed license.

### Important: Use at Your Own Risk

We’ve tested the app with thousands of images and built in multiple safeguards, including **Dry Run** and automatic `.xmp-original` backups. However, no process is perfect and unexpected issues can occur.

**You run this app at your own risk. We cannot be responsible for loss or damage.** Please keep backups of your photo libraries and metadata.

---

Apple Photos on MacOS exports GPS metadata in XMP files that does not work correctly with apps like Adobe Lightroom. Call it a bug or feature, doesn't really matter, the fact is that Adobe Lightroom (and likely other apps) don't handle the GPS location data correctly.

PhotosExportGPSFixer will repair GPS location metadata in RAW photos exported by Apple Photos "Export Unmodified Original..." with "export IPTC as XMP" enabled. Good for Lightroom or other photo editors that expect the Ref to be embedded in the Lat/Long data.

When you export images from macOS Photos with XMP sidecar files, the GPS data in those XMPs do not include the Ref value due to a bug/feature in Apple Photos. Applications like Adobe Lightroom do not correctly interpret these coordinates, depending where the photos are taken (in locations where the latitude or longitude are negative.

The bottom line is that Apple is not including the GPSLatitudeRef/GPSLongitudeRef in the GPSLatitude/GPSLongitude value in the XMP file they generate. 

The reference (Ref) values specify the hemisphere:

- **GPSLatitudeRef:**
  - N: North
  - S: South

- **GPSLongitudeRef:**
  - E: East
  - W: West

To fix the XMP so it can be consumed by Lightroom, you need to add the Ref value to the GPSLatitude and GPSLongitude.

This was the original in .xmp file
```xml
<exif:GPSLatitudeRef>N</exif:GPSLatitudeRef>
<exif:GPSLatitude>6.0448043333333334</exif:GPSLatitude>
<exif:GPSLongitudeRef>W</exif:GPSLongitudeRef>
<exif:GPSLongitude>75.93732</exif:GPSLongitude>
``` 
Fixed metadata: Just add the Ref to the end of GPSLatitude and GPSLongitude. Note the format of the number is different and has some rounding errors. The application does all the conversions and makes sure the XMP is close to the same value of the RAW
```xml
<exif:GPSLatitudeRef>N</exif:GPSLatitudeRef>
<exif:GPSLatitude>6.0448043333333334N</exif:GPSLatitude>
<exif:GPSLongitudeRef>W</exif:GPSLongitudeRef>
<exif:GPSLongitude>75.93732W</exif:GPSLongitude>
```


How to use

Drop a folder of images onto Photos Export GPS Fixer and it scans your exported images and their XMP sidecars, compares the embedded GPS data in the image to the XMP metadata, and corrects XMP formatting of GPSLatitude and GPSLongitude so your photos import into other software with the correct location.

Features:
• Works with HEIC, HEIF, and DNG exports from macOS Photos
• Fixes hemisphere references (N/S/E/W) for compatibility with photo editors such as Adobe Lightroom
• Never creates new XMP files — only updates existing ones
• Creates a backup xmp-original file (only when one does not already exist)
• Does not change the RAW image files, just the XMP metadata files
• Batch process entire folders or single photos via drag and drop
• Optional dry-run mode on by default to preview changes before making any changes
