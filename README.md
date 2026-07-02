# VideoOCR

VideoOCR is a simple macOS app for extracting text from videos using OCR. The app runs locally on your Mac, so your videos do not need to be uploaded to any online service.

## What it does

- Open a video file on your Mac.
- Extract visible text from the video.
- Show the extracted text in a simple view.

## Download the app

You can download the latest macOS build from the GitHub repository:

- Open the repository on GitHub.
- Go to the dist folder.
- Download [dist/VideoOCR.dmg](dist/VideoOCR.dmg).

After downloading:

1. Open the DMG file.
2. Drag VideoOCR into Applications.
3. Open the app from Applications.

## If the app cannot be opened on macOS

If macOS shows a warning like “cannot be opened because it is from an unidentified developer” or blocks the app, you can try this command in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/VideoOCR.app
```

Then try opening the app again.

## Build from source

If you want to build it yourself, open the Xcode project and run the app on your Mac.
