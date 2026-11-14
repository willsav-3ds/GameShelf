<img src="GameShelf/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="GameShelf icon">

# GameShelf

A themeable game library for macOS. It gathers your DuckStation, PCSX2, Gopher64, Steam and Mac games, plus any decomps and recomps you add, into one window you can drive with a keyboard, mouse or controller.

## Install

```sh
brew tap willsav-3ds/gameshelf
brew trust willsav-3ds/gameshelf
brew install --cask gameshelf
```

Requires macOS 27 on Apple silicon.

## Steam

Installed Steam games appear alongside everything else. Mac games you own but haven't downloaded are listed under "Ready to Install", and choosing one hands it to Steam to install. Rescan afterwards to move it into your library.

## Themes

Fifteen themes are built in, across six layouts: Showcase, Carousel, Grid, Bookshelf, Fan and Cloud. Cloud gathers a collection into one cluster, with the games you've played most drawn biggest. Nine of them have a moving backdrop that reacts to the pointer, including four dark fantasy themes: Blood Moon, Lanternlight, Ashen and Old Cathedral.

Covers tilt under the pointer, and the cover in a game's details can be grabbed and turned.

Everything is adjustable in Settings > Appearance. Themes are JSON files in `~/Library/Application Support/GameShelf/Themes`, so they can be shared and edited by hand.

## Build

Open `GameShelf.xcodeproj` in Xcode and run. Signing is set to a specific development team, so change it to your own in the target's Signing & Capabilities.
