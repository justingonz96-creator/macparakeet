# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native SwiftUI app; not web, iOS or Android)

## Users
Justin Gonzalez and a few teammates on Echelon Fitness's video production team. They are not developers. A few times a day, one class at a time, someone takes a recorded Echelon class video (cycling, strength, pilates, rowing and similar; usually 20–45 minutes) and needs closed captions for it, sometimes also German or Spanish subtitles. They finish the video in Adobe Premiere, where captions are placed and baked into the picture.

## Product Purpose
Echo ("Echelon Echo") turns a class video into caption files the team can drop straight into Premiere: accurate words, readable cues timed to the 29.97 fps video, following Echelon's caption rules, with anything doubtful flagged for a quick check. It also translates finished English captions into German and Spanish with the same timing. Success is a class captioned and checked in minutes, with fewer fixes needed in Premiere.

## Positioning
Built for Echelon's own classes: it knows the raw studio files carry the instructor mic on its own channels (so song lyrics stay out of captions), it applies Echelon's house caption layout, it keeps Echelon brand, product and instructor names exact in every language, and everything runs on the editor's Mac without sending class audio or text to a cloud service.

## Operating Context
- Input: raw studio class MP4s (one 4-channel track: channels 1+2 instructor mic, 3+4 music) or finished stereo class videos.
- Output: SRT/VTT caption files imported into Adobe Premiere, where the team fixes remaining mistakes and burns captions into the video.
- Echelon's app overlays force an unusual caption position: lower-centre over the rider, white text on a dark translucent box, two lines. This is why the Echelon preset allows 65 characters per cue across two lines (~32 per line), 17 characters per second target, cues up to 4 s, a 1 s hold after the last word, and 29.97 fps frame alignment.
- Runs on Apple Silicon Macs; speech recognition and the caption/translation AI run locally (Parakeet engines, an Ollama model such as qwen3.8:27b-mlx).

## Capabilities and Constraints
- Transcription engines: Parakeet Unified (default), Parakeet Ultra, v3, Whisper, Cohere, Nemotron. Word timestamps drive cue timing.
- Caption layout: rule-based Echelon layout, optionally refined by a local AI model; one failed AI chunk falls back for that chunk only.
- Caption checker: errors (line over 65 characters, more than 2 lines, empty or overlapping cues) and review items (very short cues, very fast reading, repeat loops, swear words that are usually song lyrics, timing off the frame grid).
- Translation: English captions to German ("du") or Spanish ("tú"), timing kept, protected names from Echo's Vocabulary kept exactly; output needs a native speaker's review.
- Echo is a fork of the open-source MacParakeet app. Features the team does not use (dictation, meetings, transforms, YouTube/social links, feedback) can be hidden but should not be removed, so engine updates from the original project can still be merged.
- Undecided: whether Echo should export video with captions already burned in (would replace a Premiere step).

## Brand Commitments
- Name: Echo (Echelon Echo). Internal Echelon Fitness tool.
- Use Echelon's look: the dark studio feel of Echelon classes, Echelon blue as the accent, the Echelon wordmark. No formal brand book applies.

## Evidence on Hand
- Real class videos on Justin's Mac (e.g. Marc Penna Strength 20, Maribel Maignan Pilates 20, Marc Penna Fusion 30) and their caption files.
- A reference frame of a finished Echelon class with captions in the required position (Marc Penna, Echelon Miami studio).
- German and Spanish sample translations of Strength 20 in ~/Documents/Cluade/echo-translation-samples/.
- No testimonials, metrics or user research exist; do not invent any.

## Product Principles
1. One class, start to finish, in one place: drop a video, watch it work, check, export.
2. Show problems, don't hide them: every doubtful caption is visible and one click from the video moment it belongs to.
3. Echelon's rules are the rules: the house caption layout and protected names win over generic standards.
4. Private by default: class audio and text stay on the Mac unless someone deliberately chooses otherwise.
5. Plain language for non-developers: no jargon in the interface.
