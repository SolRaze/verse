verse

media player for iphone | ios 26 | sideload only | one user
plays most formats | imports youtube / spotify / soundcloud playlists | synced lyrics | carplay now playing

features
vlc engine | audio + video | mp3 | flac | opus | ogg | ape | mkv
synced lyrics | sidecar .lrc | embedded tags | lrclib | cached
word by word lyrics | enhanced lrc tags | lrcmux + netease for word timing | else guessed inside the line
per-line lyrics on lock screen as live activity
lyric studio in create | lyric lines over camera or imported video | split | trim | reorder | ghost of last frame for lining up next take | export mp4
open in verse from files | loose .lrc goes to the track its named after
youtube streaming | sponsorblock
playlist import from youtube | spotify | soundcloud | no api keys
folder-based library | folder tree = organization | play counts | favourites
mini player pill | waveform scrubber from decoded audio | accent colour
widget | lock screen | carplay controls

carplay
now playing screen via avaudiosession.playback | mpnowplayinginfocenter | mpremotecommandcenter
browse ui needs com.apple.developer.carplay-audio | apple grants per app | sideloaded wont get it
video on car screen | airplay video, ios 26 | parked only | car must support mfi
avplayer external playback required | vlc decodes locally so cant qualify
in-car lyrics | optional setting | current line into artist text field | carplay dont render live activities

legal
youtube stream extraction breaks tos | no app store | sideload only | personal use
extraction stops when youtube rotates signature cipher | youtubekit needs bump every few months
free apple id signing lasts 7 days | paid developer program signs for a year

build
need mac with xcode 26+ | xcodegen | apple id (free fine) | iphone on ios 26+
dependencies pure spm | no cocoapods | no workspace

brew install xcodegen
git clone https://github.com/SolRaze/verse && cd verse
xcodegen generate
open Verse.xcodeproj

team + bundle id in project.yml | or change signing in xcode
run from xcode with phone selected | or cli:
xcrun devicectl list devices                      # gives udid
xcodebuild -scheme Verse -destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> ~/Library/Developer/Xcode/DerivedData/Verse-*/Build/Products/Debug-iphoneos/Verse.app

nightly
every build is a nightly | version = last commit date | build number = git rev-list --count HEAD
app name carries it | Verse n
Tools/nightly.sh builds unsigned | wraps .app in payload/ | zips to build/ipa/Verse-n.ipa | copies to phone twice (livecontainer + verse docs)
livecontainer | hit + | pick it from either
skip picker | Tools/nightly.sh --serve | serves ipa off mac | prints livecontainer://install?url=... link
unsigned on purpose | livecontainer signs guests itself | dont burn free profile slot
cost | widget + live activity dont run in livecontainer | those need normal signed install

hooks
git config core.hooksPath Tools/hooks | once per clone
pre-push kicks Tools/nightly.sh in background | push dont wait
log in build/nightly.log | skip with VERSE_NO_NIGHTLY=1

ci
github builds one too | every push | actions tab | Verse-n artifact from run summary
artifacts stick around 30 days | no signing secrets | unsigned | livecontainer signs it
download works from any machine | widget + live activity wont run off that build

structure
- Sources/Core/Player.swift  vlckit engine | audio + video
- Sources/Core/NowPlaying.swift  carplay / lock-screen | live activity lyrics
- Sources/Core/Lyrics.swift  lrc parser | lrclib client | word timing sources | embedded-tag fallback
- Sources/Core/StudioTimeline.swift  studio clips | every edit a pure func
- Sources/Core/StudioComposer.swift  clips + song + lyric layers | preview and export share it
- Sources/Core/AirPlayVideo.swift  avplayer path | video to car screen
- Sources/Core/Artwork.swift  cover art cache | two sizes
- Sources/App/Coordinator.swift  routes between the two engines
- Tools/nightly.sh  build | version | ipa | onto phone
- SPEC.md  full brief | read it first
github issues | whats left to build | whats decided

license mit
