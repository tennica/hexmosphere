# Hexmosphere

A Mac, iPad and iPhone app that draws where your photos and videos were taken as [H3](https://h3geo.org) hexagons, shaded by how many photos fall in each.

**Whole Library…** reads the location, date and accuracy of every photo and video from the Photos library's own metadata. No image is opened or downloaded, so even a large library with originals in iCloud takes seconds. It needs Photos access, either Full or Limited to a chosen set, and never changes the library. Everything stays on the device unless you export it (see Exporting to Tiled).

Tapping or clicking a hexagon shows its details and previews of up to 24 of its photos, newest first. The previews come from PhotoKit under the same Photos access, with no further permission. They're kept in memory only, never saved, and never downloaded from iCloud: a photo whose preview isn't on the device shows a cloud placeholder. Tap a preview to see it larger: PhotoKit renders it at 1024 pixels on the long side, never the original, under the same rules. On iPad and iPhone, iOS's occasional "select more photos?" prompt under Limited access is turned off.

A new take on the 2015–2018 [SCUPPERfoundation/hexmosphere](https://github.com/SCUPPERfoundation/hexmosphere), which used DGGRID and a MapKit demo client.

## Cell sizes

Odd H3 resolutions only, so each choice is about 7× finer across (49× in area) than the one before:

| H3 resolution | Across (flat to flat) | Scale |
| --- | --- | --- |
| 3 | about 120 km | region |
| 5 | about 17 km | metro area |
| 7 | about 2.4 km | town; the default |
| 9 | about 350 m | neighbourhood |
| 11 | about 50 m | building |

The sizes come out of a hexagon map prototype for [solstone](https://github.com/solpbc/solstone-journal/issues/397). In those tests, resolution 10 with a one-ring lookup matched a 50 m place rule, 11 was borderline, and 12 broke down. Resolutions 3 and 5 are for libraries spread across countries or continents, where finer cells are smaller than a pixel when the map is zoomed out far enough to show them all.

A photo whose reported horizontal accuracy is coarser than the cell's edge is left out at that size and counted in the summary, so it can't land in a cell more or less at random. At resolution 11 that cut-off is about 29 m. Shading uses a log scale, so a few very busy cells don't wash out the rest.

## Build

Hexmosphere builds on an Apple silicon Mac. The steps below start from a Mac with nothing installed.

### 1. Xcode

Install Xcode from the App Store (it targets macOS 15, and iOS and iPadOS 17, or later), then point the command-line tools at it and finish its first-run setup:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS     # only for the iPad and iPhone app
```

`xcode-select -p` should then print `/Applications/Xcode.app/Contents/Developer`. Until it's switched, it points at the Command Line Tools, and `xcodebuild` can't find Xcode.

### 2. XcodeGen and Rust

```bash
brew install xcodegen
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh    # rustup, from rustup.rs
rustup target add aarch64-apple-darwin aarch64-apple-ios
```

The Rust toolchain has to come from [rustup](https://rustup.rs): Homebrew's `rust` can't add the iOS target. If both are installed, the build script uses rustup's.

### 3. The h3o library and the Xcode project

```bash
Packages/h3o-ffi/build-xcframework.sh    # builds CH3O.xcframework for the Mac and iOS
xcodegen generate                        # writes Hexmosphere.xcodeproj from project.yml
```

Both H3 backends are always built in, so the Rust part is needed even if you only use H3 C. Run `xcodegen generate` again after adding or removing source files.

### 4. Map data (optional)

The repository carries a small base map. Roads and streets are fetched separately and bundled by the next build; see [Base map](#base-map):

```bash
scripts/fetch-basemap.sh roads                                          # world roads, 5.8 MB
scripts/fetch-basemap.sh streets colorado 36.99 -109.06 41.01 -102.04   # a region's streets
scripts/fetch-basemap.sh extract california north-america/us/california  # a big region's, from one download
```

### 5. The Mac app

```bash
xcodebuild -project Hexmosphere.xcodeproj -scheme Hexmosphere -derivedDataPath build build
open build/Build/Products/Debug/Hexmosphere.app
```

It's signed to run locally, with no Apple ID needed.

### 6. The iPad and iPhone app

One target, `HexmosphereiOS`, builds for both. Its bundle ID includes your team ID (`net.tennica.hexmosphere.ios.<team ID>`), because Apple lets only one team register a given bundle ID; that way anyone can build their own copy without changing the project. It needs three things:

1. **An Apple ID in Xcode.** Xcode → Settings → Accounts → **+**. A free Apple ID works; Xcode makes it a "Personal Team".
2. **The device**, plugged in, unlocked and trusting this Mac, with **Developer Mode** on: Settings → Privacy & Security → Developer Mode, then restart and confirm. The switch only appears after Xcode has seen the device.
3. **Two values for the commands below:**
   - **The device's name**, as `xcrun devicectl list devices` shows it (the Name column, for example `rose`). Its UDID from the Identifier column works too.
   - **Your team ID**, ten letters and digits. It's the `OU` of your "Apple Development" signing certificate, which Xcode creates when you add the Apple ID. This lists one line per certificate:

     ```bash
     security find-certificate -a -c "Apple Development" -p |
       awk '/BEGIN/{c=""} {c=c $0 "\n"} /END/{cmd="openssl x509 -noout -subject"; printf "%s", c | cmd; close(cmd)}'
     ```

     A line looks like `CN=Apple Development: you@example.com (AB12CD34EF), OU=8XY9ZW7V6U, …`. The team ID is the `OU`, **not** the code in brackets after your email. With more than one Apple ID in Xcode there's a line for each; pick the one for the account you signed in with.

Then build and install, putting your device's name and team ID in place of `rose` and `8XY9ZW7V6U`:

```bash
xcodebuild -project Hexmosphere.xcodeproj -scheme HexmosphereiOS -configuration Release \
  -destination 'platform=iOS,name=rose' -derivedDataPath build \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=8XY9ZW7V6U build
xcrun devicectl device install app --device rose build/Build/Products/Release-iphoneos/HexmosphereiOS.app
```

- `-allowProvisioningUpdates` lets Xcode register the device with your team and make the signing profile. The first build for a new device or team does this, and Xcode may ask for your keychain password.
- `DEVELOPMENT_TEAM` is passed on the command line because the project leaves it blank, so it isn't tied to one person's account. Builds signed by different teams are different apps on the device, each with its own Photos permission; to update one app from two Macs, sign in to Xcode with the same Apple ID on both.
- A Release build is worth it: Debug leaves the H3 C library unoptimised.
- On first launch the device may refuse an app from an unknown developer. Trust it in Settings → General → VPN & Device Management.

With a free Apple ID ("Personal Team"), an installed build stops launching after about 7 days until it's rebuilt and reinstalled.

Earlier versions could also read individual photos chosen with the Photos picker, or files from a folder, without Photos library access. That code was removed once both apps moved to the whole library; it's in the git history.

## Base map

The map is entirely offline. It covers Apple's map completely, roads and labels included, and draws a bundled base map (about 5 MB, plus roads and streets you fetch) on a plain background:

- **Natural Earth** (public domain): coastlines, country borders, state and province lines, lakes, and about 7,300 world cities
- **OpenStreetMap place names** (ODbL, © OpenStreetMap contributors): cities, towns, suburbs and villages for chosen regions. The United States is included. Smaller places are labelled as you zoom in.

There's no switch to Apple's map: for street detail, fetch a region's OpenStreetMap streets (below). Earlier versions had an Apple map toggle, but it fetched tiles from Apple for whatever area was on screen, so Apple could infer which places you were looking at. With the offline map, a Mac check found no tile requests after launch, but MapKit may still contact Apple, for example at startup.

### Land as H3 cells

The land is drawn as H3 hexagons on an ocean-blue background. `scripts/build-land-cells.sh [resolution]` fills Natural Earth's 1:50m land polygons with H3 cells using the vendored H3 C library, then compacts them: groups of seven merge into their parent wherever possible. It writes `Basemap/h3/land-r<res>.cells`, a list of little-endian uint64 cell indexes.

The committed file is resolution 5. Its 569,665 cells (about 144 million km², close to Earth's land area) compact to 37,531, about 300 KB. Coastlines stay at resolution 5 (about 15 km across) while continental interiors use cells up to resolution 0. Antarctica wraps all 360° and reaches the pole, which H3's polygon fill can't handle, so the script cuts it into 30° wedges first.

With land cells present, the Natural Earth coastline isn't drawn, since the hexagon edges are the coast.

### More detail: caching larger Natural Earth sets

The repository carries only the small set above. To build with more, cache a whole Natural Earth scale first:

```bash
scripts/fetch-basemap.sh naturalearth 50m    # all 45 layers, about 57 MB
scripts/fetch-basemap.sh naturalearth 10m    # all 129 layers, about 1 GB
scripts/fetch-basemap.sh naturalearth 110m   # all 32 layers, about 19 MB
```

The layers download once into `~/Library/Caches/hexmosphere/naturalearth/<version>/<scale>`. Set `HEXMOSPHERE_CACHE` to put the cache somewhere else. They're then cloned into `Basemap/naturalearth-extra/`, which is gitignored; on APFS that clone costs no extra space. The next build bundles whatever is there.

For each layer, the app uses the finest scale it finds, 10m before 50m before 110m. It draws the layers it has a style for, from bottom to top:

- glaciers and ice shelves
- dry lake beds
- urban areas
- lakes
- rivers
- tropics and polar circles
- coastlines
- state lines
- maritime and disputed borders
- land borders

Other cached layers, such as country polygons, graticules and region labels, are left out. So is the ocean: it's one world-sized polygon of about 61,000 points at 1:50m, and the coastline already shows where land ends. Each drawn layer is split into regional chunks on an 8×8 grid, so MapKit only draws the shapes near each tile. With the 50m set the app is about 60 MB. The base map loads in the background, so the window doesn't wait for it.

### More places

The United States' places come with its streets from one Geofabrik extract (`scripts/fetch-basemap.sh extract us north-america/us`, a 12 GB download; see [Streets](#streets)). To add OpenStreetMap places for another region (one Overpass API query, with retries if the public server is busy):

```bash
scripts/fetch-basemap.sh places <name> <south> <west> <north> <east>
# e.g. scripts/fetch-basemap.sh places newmexico 31.3 -109.1 37.0 -103.0
```

Running the script with no arguments re-downloads the committed Natural Earth layers above.

### Roads

Roads aren't in the repository. To draw them, fetch Natural Earth's 1:10m roads before building:

```bash
scripts/fetch-basemap.sh roads    # 56,600 roads; about 50 MB cached, 5.8 MB bundled
```

This writes every road to `Basemap/roads/roads.bin` (gitignored), keeping only its kind, its line, and the zoom level Natural Earth suggests showing it from. Each map tile draws only the roads meant for its zoom: highways when zoomed out, smaller roads as you zoom in. Until the roads have proved affordable on every device, a line under the summary shows how long they took to load and the slowest tile draw so far.

### Streets

For street-level detail in a region, fetch its OpenStreetMap streets (ODbL), from motorways down to residential streets:

```bash
scripts/fetch-basemap.sh streets colorado 36.99 -109.06 41.01 -102.04
# 303,876 streets, 3.9 million points: about 400 MB cached, 18 MB bundled
```

The script asks the Overpass API for one 1° square at a time, caching each answer in `~/Library/Caches/hexmosphere/osm`. For a big region, one Geofabrik extract filtered locally with [osmium](https://osmcode.org/osmium-tool/) (`brew install osmium-tool`) is quicker and kinder to the public servers; it brings the region's place names too:

```bash
scripts/fetch-basemap.sh extract california north-america/us/california
# 1,247,338 streets, 12.4 million points: a 1.3 GB download, 59 MB bundled
```

Either way the result is `Basemap/streets/streets-<name>.tiles` (gitignored), cut into 1° squares at three levels: a simplified overview of the main roads, the main streets, and residential streets (format in `scripts/write-streets.py`). The app reads only the files' indexes at launch, then each square the first time a tile needs it, keeping a few million points in memory and letting go of the least recently drawn; so memory stays about the same however many regions are bundled. With California and Colorado on the iPad simulator, the indexes load in under 30 ms and the slowest tile draws in about 50 ms (on an iPhone 11, 116 ms and 122 ms). With the whole United States (`scripts/fetch-basemap.sh extract us north-america/us`: a 12 GB download, 14.3 million streets, an 814 MB file), the index loads in about 20 ms, memory stays under 200 MB, and the slowest tile draws in under 10 ms on the simulator; the app is then about 820 MB. Wide views stay quick because the main roads are joined end to end before simplifying (OpenStreetMap splits a road at every bridge and junction): the widest eastern-US tile went from 155,000 pieces in 239 ms to 3,700 in 18 ms. Each street class appears from a zoom level that suits it. Map zoom levels aren't H3 resolutions: zoom 14, when residential streets appear, shows about 8 km across an iPad at Denver's latitude, where a 2.4 km (resolution 7) hexagon is about 300 points wide. Motorways appear from zoom 5, primary and secondary roads from 8–9, tertiary from 11. Inside a region with streets, Natural Earth's coarse roads give way to them from zoom 10.

## Exporting to Tiled

**Export Tiled…** saves the hexagons in view as a map for [Tiled](https://www.mapeditor.org), the open-source map editor whose files many game engines and WorkAdventure read. It writes a folder holding `hexmosphere.tmj` (Tiled's JSON format) and its tile image, `hexes.png`:

- **photo count**: a hexagonal tile layer, shaded by photo count as on screen.
- **places**: one point object per hexagon, of class `h3cell`, with its H3 index, centre latitude and longitude, photo and day counts, and first and last dates. The name is left blank for you to fill in: this is where a place database starts.

H3's local I/J grid (`cellToLocalIj`) lays the cells out, so cells that are neighbours in H3 are neighbours in Tiled. That grid points a different way in each part of the world, so the export turns it to north up: a hex grid only turns cleanly in 60° steps, and Tiled's pointy-topped and flat-topped hexagons differ by 30°, so the app measures the cells' grid positions against the map and picks the step and hexagon kind that come closest. The result is within 15° of north (Denver comes out flat-topped, about 5° off). The map's properties record the H3 resolution, library, origin cell, centre and the turn left over. Only cells near enough to the centre for H3 to place are exported; the app says how many were left out. Both H3 libraries give identical coordinates (25,096 cells compared over seven places and five resolutions).

The export holds where and when you took photos, at the chosen cell size, and leaves the device only when you save it. It doesn't include Photos library identifiers. On the Mac, saving it uses the sandbox's user-selected read-write file access.

What comes after naming places in Tiled, turning them into an Inform 7 story's rooms, regions and exits, is written up in [docs/inform.md](docs/inform.md). [inform-federation](https://github.com/SCUPPERfoundation/inform-federation) builds the rooms and exits, and goes on to make planets for the game Federation.

## H3 backend (switch in the app)

Both H3 implementations are built in, and the **h3o / H3 C** switch in the toolbar picks one:

| Choice | Library |
| --- | --- |
| `h3o` (default) | [h3o](https://github.com/HydroniumLabs/h3o) 0.8.0: an independent, pure-Rust implementation, through `Packages/h3o-ffi` |
| `H3 C` | [Uber's H3](https://github.com/uber/h3) C library 4.5.0, the reference implementation, in `Packages/CH3` |

They agree. A comparison on 100,000 random points at resolutions 7, 9 and 11 found no differing cells and no differing outline vertex counts, with vertex differences below 10⁻¹² degrees. Average edge lengths match at every resolution from 0 to 15, to within a millionth of a metre. The summary line names the library in use.

An earlier version of this project vendored H3 C 4.1.0. Its average edge lengths were the older table, about 13% smaller, which H3 replaced in March 2023 ([uber/h3#749](https://github.com/uber/h3/pull/749)). h3o already had the current values.

Building needs the Rust part either way (see [Build](#build), step 3).

## Where I Am

**Where I Am** in the toolbar outlines the hexagon you're in, at the chosen cell size, and
the summary says how many days and photos you have there. When it first finds you, the map
zooms to show about a dozen hexagons around you (at least about 5 km across), then leaves
the view to you while the outline follows. It asks for your location only
when you turn it on, and only while the app is in use. While it's on, the app holds the last
fix in memory, to place you again if you change the cell size; turning it off forgets it.
Your position is never written to disk, never in a Tiled export, and never sent anywhere. As with photos, a fix less precise than the cell is wide places you in no hexagon,
so the smallest size waits for a good fix. **Demo Drive** (the car) runs Where I Am along a route instead of your location, for trying it anywhere: Highway 1 from San Francisco to Santa Monica at 200× real time, Trail Ridge Road at 20×, Sunset Boulevard at 15×, Pikes Peak Highway at 10×, Bay to Breakers at 20×, the Powell–Hyde cable car and Lombard Street's crooked block at 5×, or a loop round San Francisco sketched by hand. The map follows the drive. The routes are real roads from the fetched OpenStreetMap streets, made by `scripts/demo-route.py` into `Basemap/routes`. The older iPad build (`ios/`) doesn't have it.

## Layout

- `Sources/Hexmosphere`: the app, shared by Mac, iPad and iPhone (SwiftUI; on an iPhone the toolbar packs into icons):
  - `ContentView.swift`: toolbar, summary panel and export
  - `LibraryLocations.swift`: reading the Photos library's metadata
  - `H3Grid.swift`: H3 wrappers for both backends, cell sizes, binning
  - `HexMapView.swift`: MapKit, with one multipolygon per shade level and region
  - `HereTracker.swift`: Where I Am, Core Location turned into the hexagon you're in
  - `Basemap.swift`, `Roads.swift`, `Streets.swift`: the offline base map, roads and streets
  - `Thumbnails.swift`: photo previews for a selected hexagon, and one photo larger
  - `TiledExport.swift`, `TiledLayout.swift`: the Tiled export and its north-up hex layout
- `Packages/h3o-ffi`: a small Rust crate exposing four h3o functions to C, built into `CH3O.xcframework` (Mac and iOS)
- `Packages/CH3`: Uber's H3 v4.5.0 C library, vendored unchanged as a SwiftPM C target (Apache-2.0; `LICENSE-h3`). `include/h3api.h` is generated from `h3api.h.in` with the version filled in. Source: the v4.5.0 release tarball, sha256 `0da8a392a6ff77e76b60e6a331a49497d0935b6b7b6899da7a3e2786139b0441`.
- `Basemap/`: the offline base map data, drawn by `Basemap.swift` and `Roads.swift`:
  - `naturalearth/`: public domain
  - `osm/`: OpenStreetMap places, ODbL, with its own `LICENSE.md`
  - `h3/`: the land as compacted H3 cells
  - `naturalearth-extra/`, `roads/`, `streets/`: fetched locally, gitignored (streets are OpenStreetMap data, ODbL)
- `scripts/fetch-basemap.sh`: fetches all of the base map data (`scripts/write-streets.py` writes the streets); `scripts/demo-route.py` makes a Demo Drive route from them; `scripts/build-land-cells.sh` with `tools/landcells.c` builds the land cells
- `tools/make-icon.swift`: draws the app icon (a cell and its six neighbours in rainbow colours, inside a circle) into `Sources/Hexmosphere/Assets.xcassets`; the command is at the top of the file
- `ios/`: an experimental Objective-C build for iOS 12 devices (for example, the iPad mini 3), compiled with `clang` because current Xcode won't target iOS 12. It reads the whole Photos library with permission, since iOS 12 has no limited picker. It's unsigned and not maintained.
- `docs/inform.md`: hexagons as Inform 7 rooms, H3 sizes as regions, neighbours as compass exits (rooms and exits built in inform-federation)
- `project.yml`: the XcodeGen project (targets `Hexmosphere` for macOS and `HexmosphereiOS` for iPad and iPhone)

## Ideas for later

- Workout routes from HealthKit, and a trail of where you've been, kept on the device
- A time filter by year or month
- A RealityKit globe view

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
