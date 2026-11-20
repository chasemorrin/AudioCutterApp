# Audio Cutter and Exporter: App Store Listing

Paste each field into App Store Connect (My Apps → your app → the version page). Field limits are in brackets.

## Basics

| Field | Value |
|---|---|
| Name [30] | Audio Cutter and Exporter |
| Subtitle [30] | Split concert recordings |
| Bundle ID | com.chasemorrin.AudioCutter (already set in the project; it can't change after the first upload) |
| Primary category | Music |
| Secondary category | Utilities |
| Price | $4.99 (paid upfront, one price point) |
| Age rating | 4+ (answer "None" to every question) |
| Support URL | https://chasemorrin.github.io/AudioCutterApp/ |
| Privacy Policy URL | https://chasemorrin.github.io/AudioCutterApp/privacy.html |
| Copyright | 2026 Chase Morrin |

If "Audio Cutter and Exporter" is taken, try "Concert Cutter and Exporter" or "Set Splitter".

## Promotional text [170]

Turn one long concert recording into separate songs. Automatic cut suggestions, clean names, and tags that import neatly into Apple Music.

## Keywords [100]

```
split,cut,trim,recording,concert,songs,voice memos,audio editor,applause,tracks,album,m4a,wav,export
```

## Description [4000]

You recorded the whole show. Now turn it into songs.

Audio Cutter and Exporter splits a long recording, like a concert, rehearsal or gig captured in Voice Memos, into individual tracks. It works with recordings of any length without slowing down, so a full set is no problem.

AUTOMATIC CUT SUGGESTIONS
The app listens for applause and suggests a cut at the end of each burst, so the next song starts cleanly. Too many cuts or too few? Switch between Strict, Normal and Sensitive, or place and adjust every cut by hand.

PRECISE EDITING
• Scrub through the whole recording on a zoomable waveform
• Pinch to zoom in on a single moment
• Add a cut at the playhead, play from any cut, and nudge cuts by a second or a tenth of a second
• Undo any change

SECTIONS
• Name each song
• Mark talking, tuning or dead air as Discard, and it's dimmed on the waveform and left out of the export
• Preview any section before you commit

EXPORT
• Save as Apple Lossless, AAC or WAV
• Files are numbered in order: "01 - Song Name", "02 - Song Name"
• Add artist, album artist and album, plus automatic track numbers, so your songs group together as one album in Apple Music
• Save individual files, or one zip file, straight to the Files app

MULTIPLE PROJECTS
Keep several recordings in progress at once. Your cuts and names are saved automatically, so you can close the app at any time and pick up where you left off. Delete a project to free up space.

PRIVATE BY DESIGN
Everything happens on your device. Your recordings are never uploaded, and the app collects no data.

Made by a working jazz pianist and music teacher who got tired of cutting up concert recordings by hand.

## What's New (version 1.0)

First release.

## App Privacy (the questionnaire in App Store Connect)

- "Do you or your third-party partners collect data from this app?" → **No**. The app then shows "Data Not Collected".

## Export compliance

- In Xcode: target → Info tab → add the key **App Uses Non-Exempt Encryption** = **NO**.
- If App Store Connect still asks: "Does your app use encryption?" → the app uses only the encryption built into iOS, so choose the option for exempt/none.

## Notes for the App Review team

```
Audio Cutter and Exporter splits a long audio recording into individual songs. It does not need an account or an internet connection.

To try it:
1. Save the attached file "Sample Concert (for App Review).m4a" to the Files app on the device.
2. Open the app and tap "Import new recording", then pick that file.
3. The app suggests three cuts, placed at the end of each applause. Tap the "Sections" tab to see the songs, then tap Preview on any section.
4. Scroll down in Sections and tap "Export 3 songs as M4A". Choose "Save to Files" in the share sheet.

The app uses no camera, microphone, location, or network access, and collects no data. Files are only read through the standard iOS file picker.
```

Attach `Sample Concert (for App Review).m4a` (3 minutes, three short "songs" separated by applause) under App Review Information → Attachment.

## Screenshots

Take them in the Simulator or on a device. Sizes change over time, and App Store Connect lists the required ones on the version page. Right now that means one set for the largest iPhone and one for the largest iPad.

Use the sample recording and show:
1. Project list
2. Waveform with numbered cuts (zoomed out)
3. Zoomed in on a cut
4. Sections tab with names and Keep / Discard
5. Export panel with format and tags filled in
6. (iPad) the side-by-side layout

Use real-looking song names ("Autumn Leaves", "Take Five") rather than "Song 1".

## Before you submit

- [ ] Paid Apps Agreement accepted, bank and tax info entered
- [ ] Small Business Program application submitted
- [ ] Support and privacy pages live: repo Settings → Pages → Deploy from branch → main, folder /docs
- [ ] Version 1.0, build 1 (already set)
- [ ] iPhone and iPad (already set; minimum iOS 17)
- [ ] Tested in Release mode on iPhone and an iPad (or iPad simulator)
- [ ] TestFlight with 2–3 musician friends, using their own recordings
- [ ] Product → Archive → Distribute App → App Store Connect
- [ ] Pick the build, answer the questionnaires, add review notes and the sample file, submit
