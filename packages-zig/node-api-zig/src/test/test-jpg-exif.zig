//
// What exif-parser reads from test/test.jpg (a photo from a Pixel 6) the way Photosphere calls it (create,
// enableSimpleValues(false), parse), shared by the tests that read that photo's EXIF (imported by path).
//

//
// `JSON.stringify(tags, null, 2)` of the tags. Worked out from the photo's bytes by the rules of exif-parser 0.1.12
// (lib/exif.js and lib/parser.js): the IFDs are read in the order IFD0, IFD1, GPS, Exif SubIFD, Interop, and within
// each in file order; a tag's name comes from lib/exif-tags.js (the GPS table for the GPS IFD), and a tag with no
// name there is stored under "undefined"; the first value stored under a name wins, so IFD1's Orientation,
// XResolution, YResolution and ResolutionUnit, the OffsetTimeDigitized and OffsetTimeOriginal after OffsetTime
// (0x9010, all three "+10:00") and CompositeImage (0xA460) add nothing; format 7 (undefined) tags (ExifVersion,
// ComponentsConfiguration, FlashpixVersion, SceneType, InteropVersion) and the thumbnail pointers are left out;
// strings stop at their first NUL, numbers come as arrays and rationals as [numerator, denominator] pairs. Every
// value agrees with ImageMagick's `identify -format "%[EXIF:*]"` of the photo.
//
pub const TEST_JPG_TAGS_JSON =
    \\{
    \\  "Make": "Google",
    \\  "Model": "Pixel 6",
    \\  "Orientation": [
    \\    1
    \\  ],
    \\  "XResolution": [
    \\    [
    \\      72,
    \\      1
    \\    ]
    \\  ],
    \\  "YResolution": [
    \\    [
    \\      72,
    \\      1
    \\    ]
    \\  ],
    \\  "ResolutionUnit": [
    \\    2
    \\  ],
    \\  "Software": "HDR+ 1.0.748116481zd",
    \\  "ModifyDate": "2025:05:27 09:54:16",
    \\  "YCbCrPositioning": [
    \\    1
    \\  ],
    \\  "GPSVersionID": [
    \\    2,
    \\    2,
    \\    0,
    \\    0
    \\  ],
    \\  "GPSLatitudeRef": "S",
    \\  "GPSLatitude": [
    \\    [
    \\      29,
    \\      1
    \\    ],
    \\    [
    \\      1,
    \\      1
    \\    ],
    \\    [
    \\      856,
    \\      100
    \\    ]
    \\  ],
    \\  "GPSLongitudeRef": "E",
    \\  "GPSLongitude": [
    \\    [
    \\      152,
    \\      1
    \\    ],
    \\    [
    \\      11,
    \\      1
    \\    ],
    \\    [
    \\      2208,
    \\      100
    \\    ]
    \\  ],
    \\  "GPSAltitudeRef": [
    \\    0
    \\  ],
    \\  "GPSAltitude": [
    \\    [
    \\      88484,
    \\      100
    \\    ]
    \\  ],
    \\  "GPSTimeStamp": [
    \\    [
    \\      23,
    \\      1
    \\    ],
    \\    [
    \\      54,
    \\      1
    \\    ],
    \\    [
    \\      8,
    \\      1
    \\    ]
    \\  ],
    \\  "GPSImgDirectionRef": "M",
    \\  "GPSImgDirection": [
    \\    [
    \\      21,
    \\      1
    \\    ]
    \\  ],
    \\  "GPSDateStamp": "2025:05:26",
    \\  "ExposureTime": [
    \\    [
    \\      3790,
    \\      1000000
    \\    ]
    \\  ],
    \\  "FNumber": [
    \\    [
    \\      185,
    \\      100
    \\    ]
    \\  ],
    \\  "ExposureProgram": [
    \\    2
    \\  ],
    \\  "ISO": [
    \\    65
    \\  ],
    \\  "DateTimeOriginal": "2025:05:27 09:54:16",
    \\  "CreateDate": "2025:05:27 09:54:16",
    \\  "undefined": "+10:00",
    \\  "ShutterSpeedValue": [
    \\    [
    \\      804,
    \\      100
    \\    ]
    \\  ],
    \\  "ApertureValue": [
    \\    [
    \\      178,
    \\      100
    \\    ]
    \\  ],
    \\  "BrightnessValue": [
    \\    [
    \\      544,
    \\      100
    \\    ]
    \\  ],
    \\  "ExposureCompensation": [
    \\    [
    \\      0,
    \\      6
    \\    ]
    \\  ],
    \\  "MaxApertureValue": [
    \\    [
    \\      178,
    \\      100
    \\    ]
    \\  ],
    \\  "SubjectDistance": [
    \\    [
    \\      996,
    \\      1000
    \\    ]
    \\  ],
    \\  "MeteringMode": [
    \\    2
    \\  ],
    \\  "Flash": [
    \\    16
    \\  ],
    \\  "FocalLength": [
    \\    [
    \\      6810,
    \\      1000
    \\    ]
    \\  ],
    \\  "SubSecTime": "228",
    \\  "SubSecTimeOriginal": "228",
    \\  "SubSecTimeDigitized": "228",
    \\  "ColorSpace": [
    \\    1
    \\  ],
    \\  "ExifImageWidth": [
    \\    2560
    \\  ],
    \\  "ExifImageHeight": [
    \\    1920
    \\  ],
    \\  "SensingMethod": [
    \\    2
    \\  ],
    \\  "CustomRendered": [
    \\    1
    \\  ],
    \\  "ExposureMode": [
    \\    0
    \\  ],
    \\  "WhiteBalance": [
    \\    0
    \\  ],
    \\  "DigitalZoomRatio": [
    \\    [
    \\      0,
    \\      1
    \\    ]
    \\  ],
    \\  "FocalLengthIn35mmFormat": [
    \\    24
    \\  ],
    \\  "SceneCaptureType": [
    \\    0
    \\  ],
    \\  "Contrast": [
    \\    0
    \\  ],
    \\  "Saturation": [
    \\    0
    \\  ],
    \\  "Sharpness": [
    \\    0
    \\  ],
    \\  "SubjectDistanceRange": [
    \\    1
    \\  ],
    \\  "LensMake": "Google",
    \\  "LensModel": "Pixel 6 back camera 6.81mm f/1.85",
    \\  "InteropIndex": "R98"
    \\}
    ;
