# SampleBuilder

Builds `shared/sounds/cello` (the recorded cello the app plays with) from the
[University of Iowa Musical Instrument Samples](https://theremin.music.uiowa.edu/MIS.html): the 2012 cello
recordings, bowed, one note per file on each string. They're free to use for any project, without restrictions.

The output is committed, so you only need this to rebuild or change the set.

```
# Download Cello.arco.ff.sul{C,G,D,A}.stereo.zip from
# https://theremin.music.uiowa.edu/MIS-Pitches-2012/MISCello2012.html and unzip them into one folder, then:
swift run -c release SampleBuilder <that folder> ../../shared/sounds/cello
```

For each note it checks the pitch against the file name with ScoreKit's `PitchDetector` and records how far
the take is from A = 440 equal temperament. Takes more than ¾ semitone off are skipped as mislabelled. It
then trims the note to start at the attack, keeps 2.6 s, sets loop points a whole number of cycles apart in
the steady part, balances loudness, and encodes AAC. The app re-pitches each note to the exact target of
the chosen tuning, using the measured offset.

Why not the 2001 set, which has pp, mf and ff? Its notes are recorded as chromatic runs, which can't be
split reliably: bow changes break notes in two, the pitch drifts between strokes, and some file names don't
match their notes. The 2012 set is fortissimo only, so the app plays softer dynamics by turning it down.
