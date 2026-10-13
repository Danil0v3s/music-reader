# Music Reader

A practice companion for cellists: read sheet music from a PDF or a scan, write or correct it note by
note, hear it at any tempo, and check your intonation against it with the microphone.

- `ios/`: the iOS app. Programmatic UIKit (Coordinator + ViewFactory + AppDependencies), XcodeGen
  (`project.yml`), and a local Swift package `ScoreKit` holding everything that isn't UI. Same structure as
  `tesla-mate-viewer`.
- `server/`: the OMR (optical music recognition) server, [Audiveris](https://github.com/Audiveris/audiveris)
  behind a small HTTP API, packaged as a `linux/amd64` Docker image. See [server/README.md](server/README.md).
- `shared/`: files both apps bundle: the Bravura music font (SMuFL, SIL OFL) and sample scores.
- `android/`: not started yet. ScoreKit is UI-free and dependency-free so it can be ported module by module,
  the way `tesla-mate-viewer`'s Android `:core:*` modules mirror its Swift package.

## How it works

```
PDF / camera scan ──► OMR server (Audiveris, Docker) ──► MusicXML ─┐
MusicXML file (MuseScore, Dorico, Sibelius…) ──────────────────────┼─► ScoreKit Score ─┬─► notation (Bravura)
Editor (tap the staff) ────────────────────────────────────────────┘                   ├─► playback + metronome
                                                                                       ├─► intonation practice (mic)
                                                                                       └─► MusicXML / PDF export
```

### ScoreKit (ios/ScoreKit)

The music theory is explicit and tested (`swift test`, 39 tests):

- **Theory**: spelled pitches (C♯ ≠ D♭: different staff position, accidental and, outside equal temperament,
  frequency), intervals named by quality and number, key signatures with modes and scale degrees, clefs
  (bass, tenor, treble, alto; tenor-clef sharps placed low), meters (simple and compound beats), note values
  as exact fractions (dots, tuplets), tempo with beat units and Italian markings, and accidental rules (a sign
  lasts to the barline in its octave; ties carry it over).
- **Tuning**: equal temperament, Pythagorean (built from pure fifths, so sharps sit high and flats low) and
  5-limit just intonation relative to the key's tonic (major thirds 14 ¢ low), with a configurable reference A
  (415–466 Hz). The cello's open strings are tuned in pure fifths down from A.
- **Model and editing**: scores, parts, measures with clef/key/meter/tempo changes, notes and double stops,
  slurs, ties, articulations, cello bowings, fingerings (including thumb), string indications, dynamics and
  hairpins. Measures are checked against the meter (underfull and overfull, pickup bars allowed).
- **MusicXML**: reading and writing `score-partwise` files, keeping one voice of each part's first staff.
- **Layout**: engraving geometry (proportional spacing, line breaking and justification, beams grouped by
  beat, stem directions, ledger lines, accidentals, ties and slurs across lines, marks stacked above the
  staff) plus hit-testing that maps a tap to a bar, an insertion point and a pitch.
- **Playback**: the score unrolled into time (repeats, tempo changes, fermatas, ties merged, articulations
  and dynamics shaping length and loudness), a bowed-string synth, and metronome clicks with a count-in.
- **Intonation**: YIN pitch detection tuned for the cello's range, and per-note assessment (median cents,
  steadiness, wrong-note detection, an overall sharp or flat tendency).
- **OMR client** for the server, and **storage** (JSON per score, plus the original PDF for comparison).

### The app (ios/MusicReader)

- **Library**: import a PDF, image or MusicXML; scan paper with the camera; write a new score.
- **Score**: notation that follows playback; practice tempo (50–125 %); metronome; tap a note to see its
  scale degree, frequency, interval from the previous note, string and fingering; view the original PDF;
  export MusicXML or PDF.
- **Editor**: tap the staff to enter notes. The palette covers note values, dots, triplets, rests,
  accidentals, step and octave moves, ties, slurs, double stops, articulations, bowings, fingerings, strings,
  dynamics and hairpins. A bar menu changes clef, key, meter, tempo and barlines and inserts or deletes bars.
  Undo and redo are included, and bars that don't add up are tinted.
- **Practice**: *Follow me* waits for each note to be played in tune; *With metronome* judges each note in time.
  Notes turn green, amber or red, and a summary says what to work on.
- **Tuner**: strings judged against pure fifths, with a reference drone per string.
- **Settings**: recognition server address and token, reference A, tuning system, intonation tolerance.

## Build and run

```
cd ios && xcodegen generate
xcodebuild -project MusicReader.xcodeproj -scheme MusicReader -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
cd ScoreKit && swift test
```

Debug launch hooks (`Navigation/DevLaunch.swift`) are passed as `SIMCTL_CHILD_*` variables to `xcrun simctl launch`:

| Variable | |
|---|---|
| `MR_DEV_SCREEN` | `score`, `editor`, `practice`, `tuner`, `settings` or `new` (opens the bundled étude) |
| `MR_DEV_SERVER` | Recognition server address, e.g. `http://localhost:8765` |
| `MR_DEV_IMPORT` | A file path to import as if it were opened from Files |
| `MR_DEV_EXPORT_PDF` | Writes the bundled étude, engraved, to this path |
| `MR_DEV_FAKE_MIC=1` | Practice uses a simulated player instead of the microphone (varied intonation), for testing without a cello |

Debug builds only.

## Credits

- Bravura © Steinberg Media Technologies, SIL Open Font License 1.1 (`shared/fonts/Bravura-OFL.txt`).
- Audiveris (AGPL-3.0) runs in the server container. The app talks to it over HTTP only.
- `shared/samples/etude-in-d.musicxml` is an original 12-bar étude written for this project.
