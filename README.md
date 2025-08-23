# myapps
My public applications
Applications included in this repository are freely available under enclosed license.

Absolutely no warranty provided. USE AT YOUR OWN RISK.

PhotosExportGPSFixer
---

Apple Photos on MacOS exports GPS metadata in XMP files that does not work correctly with apps like Adobe Lightroom. Call it a bug or feature, doesn't really matter, the fact is that Adobe Lightroom (and likely other apps) don't handle the GPS location data correctly.

Bottom line is that Apple is not honoring the sign on GPSLongitude or GPSLatitude in the XMP file they generate. 

How GPS coordinates are represented in an image file (not a XMP file)
* GPSLatitudeRef (N/S):
  * North (N) → positive value
  * South (S) → negative value
* GPSLongitudeRef (E/W):
  * East (E) → positive value
  * West (W) → negative value

To fix the XMP so it can be consumed by Lightroom, you need to add the Ref value. It's a bit more complicated since RAW image always has GPSLatitude and GPSLongitude in a pure decimal format and XMP uses Degree+Minute format but let's ignore that.

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
<exif:GPSLatitude>6,2.6882600000000068N</exif:GPSLatitude>
<exif:GPSLongitudeRef>W</exif:GPSLongitudeRef>
<exif:GPSLongitude>75,56.23919999999998W</exif:GPSLongitude>
```

PhotosExportGPSFixer will repair GPS location metadata in RAW photos exported by Apple Photos "Export Unmodified Original..." with "export IPTC as XMP" enabled. Good for Lightroom or other photo editors that expect the Ref to be embedded in the Lat/Long data.

When you export images from macOS Photos with XMP sidecar files, the GPS data in those XMPs do not include the Ref value due to a bug/feature in Apple Photos. Applications like Adobe Lightroom do not correctly interpret these coordinates, depending where the photos are taken (in locations where the latitude or longitude are negative.

How to use

Drop a folder of images onto Photos Export GPS Fixer and it scans your exported images and their XMP sidecars, compares the embedded GPS data in the image to the XMP metadata, and corrects XMP formatting of GPSLatitude and GPSLongitude so your photos import into other software with the correct location.

Features:
• Works with HEIC, HEIF, and DNG exports from macOS Photos
• Fixes hemisphere references (N/S/E/W) for compatibility with photo editors such as Adobe Lightroom
• Never creates new XMP files — only updates existing ones
• Does not change the RAW image files, just the XMP metadata files
• Batch process entire folders or single photos via drag and drop
• Optional dry-run mode on by default to preview changes before making any changes
