# Hexmosphere

A Mac, iPad and iPhone app that draws where your photos and videos were taken as [H3](https://h3geo.org) hexagons, shaded by how many photos fall in each.

**Whole Library…** reads the location, date and accuracy of every photo and video from the Photos library's own metadata. No image is opened or downloaded, so even a large library with originals in iCloud takes seconds. It needs Photos access, either Full or Limited to a chosen set, and never changes the library. Everything stays on the device unless you export it (see Exporting to Tiled).

Tapping or clicking a hexagon shows its details and previews of up to 24 of its photos, newest first. The previews come from PhotoKit under the same Photos access, with no further permission. They're kept in memory only, never saved, and never downloaded from iCloud: a photo whose preview isn't on the device shows a cloud placeholder. On iPad and iPhone, iOS's occasional "select more photos?" prompt under Limited access is turned off.

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

Needs Xcode (macOS 15 / iPadOS 17 or later as targets), [XcodeGen](https://github.com/yonaskolb/XcodeGen) and, for the default h3o backend, a [rustup](https://rustup.rs) toolchain with the iOS target.

```bash
# 1. The h3o library (always needed; both backends are built in)
rustup target add aarch64-apple-ios
Packages/h3o-ffi/build-xcframework.sh

# 2. The Xcode project
xcodegen generate

# 3. The Mac app (signed to run locally)
xcodebuild -project Hexmosphere.xcodeproj -scheme Hexmosphere -derivedDataPath build build
open build/Build/Products/Debug/Hexmosphere.app

# 4. The iPad and iPhone app (one target; needs your Apple team ID, Developer Mode on the device, and its UDID)
xcodebuild -project Hexmosphere.xcodeproj -scheme HexmosphereiPad -derivedDataPath build \
  -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<team ID> build
xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/HexmosphereiPad.app
```

With a free Apple ID ("Personal Team"), an installed iPad or iPhone build stops launching after about 7 days until it's rebuilt and reinstalled.

Earlier versions could also read individual photos chosen with the Photos picker, or files from a folder, without Photos library access. That code was removed once both apps moved to the whole library; it's in the git history.

If the originals live only in iCloud ("Optimize Storage"), Photos has to download each one first, and that can be slow. In that case, exporting with location and using **Open Files…** works too.

## Base map

The map is entirely offline. It covers Apple's map completely, roads and labels included, and draws a bundled base map (about 5 MB, plus roads and streets you fetch) on a plain background:

- **Natural Earth** (public domain): coastlines, country borders, state and province lines, lakes, and about 7,300 world cities
- **OpenStreetMap place names** (ODbL, © OpenStreetMap contributors): cities, towns, suburbs and villages for chosen regions. Colorado is included. Smaller places are labelled as you zoom in.

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

To add OpenStreetMap places for another region (one Overpass API query, with retries if the public server is busy):

```bash
scripts/fetch-basemap.sh places <name> <south> <west> <north> <east>
# e.g. scripts/fetch-basemap.sh places newmexico 31.3 -109.1 37.0 -103.0
```

Running the script with no arguments re-downloads the committed set: the Natural Earth layers above and the Colorado places.

### Roads

Roads aren't in the repository. To draw them, fetch Natural Earth's 1:10m roads before building:

```bash
scripts/fetch-basemap.sh roads    # 56,600 roads; about 50 MB cached, 5.8 MB bundled
```

This writes every road to `Basemap/roads/roads.bin` (gitignored), keeping only its kind, its line, and the zoom level Natural Earth suggests showing it from. Each map tile draws only the roads meant for its zoom: highways when zoomed out, smaller roads as you zoom in. Until the roads have proved affordable on every device, the summary line shows how long they took to load and the slowest tile draw so far.

### Streets

For street-level detail in a region, fetch its OpenStreetMap streets (ODbL), from motorways down to residential streets:

```bash
scripts/fetch-basemap.sh streets colorado 36.99 -109.06 41.01 -102.04
# 303,876 streets, 3.9 million points: about 400 MB cached, 33 MB bundled
```

The script asks the Overpass API for one 1° square at a time, caching each answer in `~/Library/Caches/hexmosphere/osm`, and writes `Basemap/streets/streets-<name>.bin` (gitignored) in the roads format. Each street class appears from a zoom level that suits it. Map zoom levels aren't H3 resolutions: zoom 14, when residential streets appear, shows about 8 km across an iPad at Denver's latitude, where a 2.4 km (resolution 7) hexagon is about 300 points wide. Motorways appear from zoom 5, primary and secondary roads from 8–9, tertiary from 11. Inside a region with streets, Natural Earth's coarse roads give way to them from zoom 10.

## Exporting to Tiled

**Export Tiled…** saves the hexagons in view as a map for [Tiled](https://www.mapeditor.org), the open-source map editor whose files many game engines and WorkAdventure read. It writes a folder holding `hexmosphere.tmj` (Tiled's JSON format) and its tile image, `hexes.png`:

- **photo count**: a hexagonal tile layer (pointy-top, rows staggered), shaded by photo count as on screen.
- **places**: one point object per hexagon, of class `h3cell`, with its H3 index, centre latitude and longitude, photo and day counts, and first and last dates. The name is left blank for you to fill in: this is where a place database starts.

H3's local I/J grid (`cellToLocalIj`) lays the cells out, so cells that are neighbours in H3 are neighbours in Tiled. That grid points a different way in each part of the world, so the export turns it to north up: a hex grid only turns cleanly in 60° steps, and Tiled's pointy-topped and flat-topped hexagons differ by 30°, so the app measures the cells' grid positions against the map and picks the step and hexagon kind that come closest. The result is within 15° of north (Denver comes out flat-topped, about 5° off). The map's properties record the H3 resolution, library, origin cell, centre and the turn left over. Only cells near enough to the centre for H3 to place are exported; the app says how many were left out. Both H3 libraries give identical coordinates (25,096 cells compared over seven places and five resolutions).

The export holds where and when you took photos, at the chosen cell size, and leaves the device only when you save it. It doesn't include Photos library identifiers. On the Mac, saving it uses the sandbox's user-selected read-write file access.

## H3 backend (switch in the app)

Both H3 implementations are built in, and the **h3o / H3 C** switch in the toolbar picks one:

| Choice | Library |
| --- | --- |
| `h3o` (default) | [h3o](https://github.com/HydroniumLabs/h3o) 0.8.0: an independent, pure-Rust implementation, through `Packages/h3o-ffi` |
| `H3 C` | [Uber's H3](https://github.com/uber/h3) C library 4.5.0, the reference implementation, in `Packages/CH3` |

They agree. A comparison on 100,000 random points at resolutions 7, 9 and 11 found no differing cells and no differing outline vertex counts, with vertex differences below 10⁻¹² degrees. Average edge lengths match at every resolution from 0 to 15, to within a millionth of a metre. The summary line names the library in use.

An earlier version of this project vendored H3 C 4.1.0. Its average edge lengths were the older table, about 13% smaller, which H3 replaced in March 2023 ([uber/h3#749](https://github.com/uber/h3/pull/749)). h3o already had the current values.

Building needs the Rust part either way: `Packages/h3o-ffi/build-xcframework.sh`, with a rustup toolchain that has `aarch64-apple-ios`.

## Layout

- `Sources/Hexmosphere`: the app, shared by Mac, iPad and iPhone (SwiftUI; on an iPhone the toolbar packs into icons):
  - `H3Grid.swift`: H3 wrappers for both backends, cell sizes, binning
  - `HexMapView.swift`: MapKit, with one multipolygon per shade level
  - `ContentView.swift`: controls and summary
- `Packages/h3o-ffi`: a small Rust crate exposing three h3o functions to C, built into `CH3O.xcframework` (Mac and iOS)
- `Packages/CH3`: Uber's H3 v4.5.0 C library, vendored unchanged as a SwiftPM C target (Apache-2.0; `LICENSE-h3`). `include/h3api.h` is generated from `h3api.h.in` with the version filled in. Source: the v4.5.0 release tarball, sha256 `0da8a392a6ff77e76b60e6a331a49497d0935b6b7b6899da7a3e2786139b0441`.
- `ios/`: an experimental Objective-C build for iOS 12 devices (for example, the iPad mini 3), compiled with `clang` because current Xcode won't target iOS 12. It reads the whole Photos library with permission, since iOS 12 has no limited picker. It's unsigned and not maintained.
- `Basemap/`: the offline base map data, fetched by `scripts/fetch-basemap.sh` and drawn by `Sources/Hexmosphere/Basemap.swift`:
  - `naturalearth/`: public domain
  - `naturalearth-extra/`: local caches only, gitignored
  - `osm/`: ODbL, with its own `LICENSE.md`
- `tools/landcells.c`: the land-filling tool, built and run by `scripts/build-land-cells.sh`
- `project.yml`: the XcodeGen project (targets `Hexmosphere` for macOS and `HexmosphereiPad` for iPad and iPhone, keeping its original name and bundle ID)

## Ideas for later

- Workout routes from HealthKit (iPad), and Core Location visit monitoring going forward
- A time filter by year or month
- A RealityKit globe view
- Tapping a cell to show its photos

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
