<img src="icon.png" width="80" align="right" alt="">

# Flappy Hats

Flappy Bird 1.1.0 for iOS 6 with a shop: hats and skins you unlock with your best score or buy with points, and flap, point and game over sounds you record yourself. Comes as two apps, Flappy Hats and the 60fps Flappy Hats 60FPS, next to the original.

## Features

- A SHOP button on the title screen opens HATS, SKINS and SOUND tabs: 37 hats and 49 skins, each previewed on the bird. Press and hold the cat ears or the cat skin for 11 colours.
- Score Rewards unlock with your best score (5 to 200). The rest are for sale: every game earns points equal to your score, and premium hats go up to 2000.
- Your Flappy Bird best score carries over on first launch, so rewards unlock right away.
- Record your own flap, point and game over sounds (up to 2 seconds, trimmed and levelled), each with its own volume up to 200%.
- An optional tick on every flap, at KeyTick's strength and length if you have KeyTick.
- Installs as its own app, Flappy Hats, next to the original. No ads, no crash on death when Game Center is signed in, and pressing home doesn't restart the game.
- Flappy Hats 60FPS is the same mod on the 60fps game (home screen name Hats 60FPS). On first launch it starts with your Flappy Hats points, items and sounds; after that each app keeps its own.

## How to use

1. Open Flappy Hats and tap SHOP on the title screen.
2. In HATS or SKINS, tap an item to preview it, then tap EQUIP or BUY. DEFAULT at the top is the stock look.
3. Press and hold the cat ears or the cat skin to pick one of its colours.
4. Score Rewards unlock as your best score goes up. Every game adds your score to your points.
5. In SOUND, pick FLAP, POINT or GAME OVER, then hold HOLD TO RECORD (up to 2 seconds). Tap PLAY to hear it and USE to keep it. RESET goes back to the stock sound.
6. Drag VOLUME to set that sound's loudness, from 0 to 200%. On FLAP, VIBRATE turns the flap tick on or off.

## Requirements

- Jailbroken iOS 6 (tested on an iPhone 5 with iOS 6.1.2)
- Cydia Substrate and UIKit Tools (Cydia installs them for you)

## Install

In Cydia, add `https://mbucc9000.github.io/slopkit/` and install **Flappy Hats** or **Flappy Hats 60FPS**. Or download the `.deb` from [Releases](../../releases) and install it with `dpkg -i`.

## Building

Build `FlappyHats.dylib` with [Theos](https://theos.dev) (iOS 6.1 SDK), then `py -3 build_app_deb.py` bakes it into the stock Flappy Bird 1.1.0 IPA and makes the `.deb` (Python 3 + Pillow). For Flappy Hats 60FPS, run it on the 60fps IPA from [Flappy60](https://github.com/mbucc9000/Flappy60) with `FH_ICONS_DIR=icon60 FH_LABEL="Hats 60FPS"`. The same dylib works in both.

## License

MIT.
