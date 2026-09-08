# Verse — the brief

iphone 17e, ios 26. swift 6, swiftui. sideloaded, one user, thats me. no app store, no accounts,
no analytics, no onboarding. no settings screen for a setting that dont matter.

read `README.md` first. the carplay limits in there are facts, not opinions. if something below
looks like it fights them, the limits win.

## scope

1. play any media file from files app — audio or video, any container, any codec.
2. play youtube without ads.
3. show time synced lyrics from LRCLIB, embedded tags, or a sidecar `.lrc`.
4. put audio on the carplay now playing screen, lyrics drawn into the artwork.

anything off that list is out of scope. no playlists of playlists, no cloud sync, no themes, no
library database past what it takes to find a file again.

## 1. playback engine

**MobileVLCKit** runs everything except one carve out. vlc decodes mp3, aac, alac, flac, opus, ogg,
wav, aiff, wma, ape, m4a, mp4, mkv, avi, mov, webm, hls and the long tail. one engine means one now
playing integration and one set of bugs.

the carve out: **video that can reach the car screen goes thro AVPlayer**
(`Sources/Core/AirPlayVideo.swift`, written already). ios 26 airplay video in the car only works
thro avplayer external playback. vlc decodes locally, so it cant airplay video. thats a wall, not a
preference. routing rule is `AirPlayVideoPlayer.canAirPlay(url)`: avplayer compatible containers
(mp4/m4v/mov/HLS — every extracted youtube stream counts) take the avplayer path with an
`AirPlayButton` in the ui. everything else uses vlc on the phone. dont widen that path.

`Sources/Core/Player.swift` has the wrapper. what it needs:

- `AVAudioSession` category `.playback`, `.mixWithOthers` off, activated on first play. background
  audio mode in Info.plist. without it theres no carplay and no lock screen playback.
- `@Published` state: current item, position, duration, isPlaying. poll vlcs time thro its
  delegate, not a timer, where you can.
- video renders into a `UIViewRepresentable` host on the phone only. dont route it to an external
  screen.
- seek, rate, next/prev driven from `MPRemoteCommandCenter` too, not just the ui. wheel buttons go
  thro the remote command center.

## 2. files

- `UIDocumentPickerViewController` (`.open`, multiple) for import. keep **security scoped
  bookmarks**, not paths. paths go stale and the app loses access after a relaunch — thats the bug
  that keeps coming back. resolve the bookmark and `startAccessingSecurityScopedResource()` before
  every play, stop after.
- set `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` in Info.plist so files can drop
  into the apps Documents folder from files.app or a mac.
- register `CFBundleDocumentTypes` broadly (`public.audio`, `public.movie`, `public.data`) so
  "Open in Verse" shows in the share sheet.
- persistence is one `Codable` array in a json file. not core data, not swiftdata, not sqlite. its
  a small personal library, it fits in memory.

## 3. lyrics

`Sources/Core/Lyrics.swift` is written — lrc parser and LRCLIB client. wire it up.

order for a track, first hit wins:
1. sidecar file: same basename, `.lrc`, next to the media file.
2. embedded tags: ID3 `SYLT` (synced) or `USLT` (unsynced), vorbis comment `LYRICS`. read thro
   `AVAsset.metadata` where you can.
3. LRCLIB: `GET https://lrclib.net/api/get` with `artist_name`, `track_name`, `album_name`,
   `duration` (seconds, integer). gives `syncedLyrics` (lrc text) and `plainLyrics`. 404 means no
   match, so fall back to `GET /api/search?q=` and take the best duration match. no auth, no key.
   send a real `User-Agent`, LRCLIB asks for one and they run it for free.
4. nothing. show plain lyrics if theres any, else an empty state. dont fake timings.

cache resolved lyrics on disk keyed by the tracks stable id, so the car aint waiting on network.

i drop `.lrc` files in directly too. treat that import as "attach to the track whose basename
matches". if nothing matches, keep it unattached and let me pick.

## 4. youtube

- extraction is **YouTubeKit** (`github.com/alexeichhorn/YouTubeKit`, spm). ask for streams, take
  highest bitrate audio only for the car, or a muxed/adaptive video stream for the phone.
- ads: extraction pulls the media stream direct, so pre roll and mid roll never enter the pipeline.
  no ad blocking code to write — it falls out of not using the youtube player.
- **sponsorblock** for in video sponsor reads:
  `GET https://sponsor.ajay.app/api/skipSegments?videoID=<id>&category=sponsor&category=selfpromo&category=interaction`
  gives segments as `[[start, end], ...]` in seconds. when position enters a segment, seek to its
  end. thats the whole feature.
- input: paste a url, or take a share sheet extension from the youtube app (Info.plist url types +
  share extension optional, start with paste).
- extraction fails often. surface the error. never crash, never show a blank player like nothings
  wrong.

## 4b. video on the car screen

limits are in the readme. implementation is done (`AirPlayVideo.swift`). whats left is ui:

- when the item passes `canAirPlay`, show `AirPlayButton` on the player screen. tapping it lists
  the cars display *if the head unit supports airplay video in the car*. the system decides, we
  just show the picker.
- `isExternal` publishes when video moved to the car. dim the phone surface, show a "playing on car
  display" placeholder.
- parked only is the systems job. write no speed checks.
- dont build toward the ios 27 carplay video app entitlement (browse ui on the car). it needs
  apples per app approval, and a sideloaded youtube extractor wont get it.

## 5. carplay — the subtle part

`Sources/Core/NowPlaying.swift` is written. two jobs:

**a. now playing info.** title, artist, album, duration, elapsed time, playback rate. keep
`MPNowPlayingInfoPropertyElapsedPlaybackTime` right on every state change or the cars scrubber
drifts. register handlers on `MPRemoteCommandCenter` for play, pause, toggle, next, previous,
changePlaybackPosition, skipForward/Backward.

**b. lyrics drawn into the artwork.** on each lyric line change, render a `UIImage` with the
previous / current / next lines (current one emphasized) and republish `nowPlayingInfo` with a
fresh `MPMediaItemArtwork` around it. car shows it big.

rough edges — test in the real car, not the simulator:
- some head units cache artwork hard and wont refresh per line. if mine does, push the current
  lyric line into `MPMediaItemPropertyArtist` or `AlbumTitle` instead. text fields update reliable
  where images sometimes dont.
- dont republish faster than lines change. lrc lines are seconds apart, thats fine. dont run this
  off a 60Hz display link.
- fall back to real album art as soon as lyrics aint there.

theres no `CPTemplateApplicationSceneDelegate` here. if you start writing one, you wandered onto
the entitlement path. stop.

## 6. widget, live activity, lock screen

three surfaces, three different capabilities. dont mix them up.

**widget — no video, ever.** a widget is a static swiftui snapshot the system renders ahead of
time. no process running while you look at it, no render loop, no `AVPlayer`. cant route around it.

**widget — audio control, yes.** `Sources/Widget/VerseWidget.swift` is written. the intents conform
to **`AudioPlaybackIntent`**, not `AppIntent`. thats the whole feature: a plain widget intent runs
in the widget extension, which has no background audio entitlement and cant activate an
`AVAudioSession`, so the button would do nothing. `AudioPlaybackIntent` makes the system launch the
*app* in the background to do it, audio allowed. "simplify" these to `AppIntent` and the widget
quietly dies.

left to wire:
- set `PlaybackBridge.shared.player` when the app builds its `Player`.
- call `PlaybackSnapshot.write(...)` on track change and play/pause. **not per lyric line.** widget
  timeline reloads are budgeted at a few dozen a day, and per line reloads get throttled to nothing
  inside one song.
- create the app group `group.com.sol.verse` on both the app and widget app ids. missing group
  means the container url is nil, and the widget renders empty with no error.

**live activity — where per line lyrics go.** activitykit, updated from the app thro
`activity.update()` while background audio keeps the app alive. lands on the lock screen, and the
dynamic island if the device has one. built — `LyricActivity.swift` has the attributes,
`NowPlaying` starts/updates/ends it (orphan cleanup on launch, foreground resume for the background
start case), `VerseWidget`s `LyricLiveActivity` renders it.

**lock screen now playing — done, free.** `NowPlaying.swift` publishes the lyric artwork image to
`MPNowPlayingInfoCenter`, so the lock screen gets the same synced lyrics the car does.

**carplay dont show third party widgets.** the dashboard is apples, no public api. the now playing
screen stays the whole carplay surface.

## verification

this is a driving app and i cant debug it at 70mph, so:

- `Tests/LyricsTests.swift`: lrc parser round trip — timestamps `[mm:ss.xx]` and `[mm:ss.xxx]`,
  multiple timestamps on one line, metadata tags (`[ar:]`, `[ti:]`, `[offset:]`), blank lines, out
  of order lines, and `lineIndex(at:)` boundaries at 0, exactly on a timestamp, and past the last
  line. placeholder text, not real lyrics.
- a `demo()` that plays a local file, prints now playing dict transitions, asserts elapsed time
  tracks position.
- manual: plug into the car. check play/pause from the wheel, scrubber accuracy, and whether
  artwork refreshes per line on that head unit.

## conventions

- a dependency gets added only if it deletes more code than it costs. list is final: MobileVLCKit,
  YouTubeKit. everything else is foundation/avfoundation/mediaplayer/swiftui.
- mark deliberate shortcuts with a `TODO(later):` comment naming the ceiling and the upgrade path.
- fewest files that work. dont scaffold for a future that might not come.
