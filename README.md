# VideoOCR

A macOS app for extracting text from videos using OCR. The app runs locally on your Mac with Apple's Vision framework, so large videos do not need to be uploaded to a web service.

## Features

- Open a video from your Mac.
- Extract visible text from video frames with a configurable interval.
- **Center-Focus Cropping**: Automatically crop and focus OCR on the central area of the frame (adjustable ratio, e.g. 70% of the center) where the main content usually lies.
- **Pure Text Output**: Extract and display all visible text in chronological order, with source frame images next to each text block.
- Choose English or Vietnamese OCR recognition language.
- View OCR results by timestamp.
- Copy or share Markdown output.

## Download the macOS app

You can download the latest macOS build as a DMG file from the GitHub repository:

- Open the repository on GitHub
- Go to the dist folder
- Download [dist/VideoOCR.dmg](dist/VideoOCR.dmg)

After downloading, open the DMG, drag VideoOCR to Applications, and launch it from there.

## Generate the Xcode project

```bash
xcodegen generate
```

Open `VideoOCR.xcodeproj` in Xcode and run the `VideoOCR` scheme on your Mac.

If command-line builds fail with `xcodebuild requires Xcode`, install/open Xcode first, then switch the active developer directory:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Command Line Interface (macOS)

You can also run the OCR engine directly from your Mac terminal:

```bash
swift video_ocr_macos.swift <video-path> [options]

Options:
  --output <path>        Markdown output path. Default: video_ocr_output.md
  --jsonl <path>         Optional raw JSONL output path
  --interval <seconds>   Sample interval. Default: 1
  --max-size <pixels>    Max frame size for OCR. Default: 1600
  --language <tag>       OCR language. Default: en-US
  --center-crop <ratio>  Center crop ratio (0.3–1.0). Default: 0.7
```

## Notes

- A smaller frame interval is more accurate but slower.
- All OCR happens locally on the device.
- Center focus cropping helps filter out irrelevant background or sidebar text, focusing only on the central content.
