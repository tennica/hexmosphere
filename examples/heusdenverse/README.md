# The HeusDenVerSe

A made-up hex map stretched between two real towns, Heusden in the Netherlands and Denver in Colorado, for Hexmosphere's **Open Tiled**. It shows the three things Open Tiled can put on the globe:

- **Tiled maps placed where they really are.** The two town ends, at H3 resolution 8 (hexes about 0.9 km across), are built from OpenStreetMap.
- **A route.** The great circle from Heusden to Denver, 7,810 km, drawn as the chain of cells it crosses at whatever cell size the app shows.
- **A map painted along a route.** A hand-drawn fantasy map (polder, star fort, a very short Atlantic, plains, the Front Range) laid along the route at resolution 3, Hexmosphere's biggest size. Its Heusden column sits on Heusden and its Denver column on Denver. A flat grid can't do that: it's pinned at one point, and the towns are too far apart on a curved globe.

## Opening it

Copy the `map/` folder into Hexmosphere's Documents and pick it from the Open Tiled menu. On iPad or iPhone, use Files › On My iPad › Hexmosphere. On the Mac, use the app's container, `~/Library/Containers/net.tennica.hexmosphere/Data/Documents`.

| File in `map/` | What it is |
| --- | --- |
| `island.geojson` | the fantasy map painted onto cells along the route, with its seven landmarks |
| `bridge.geojson` | the route: its two ends, joined along the great circle |
| `heusden.tmj`, `denver.tmj` | the town ends, from OpenStreetMap (see Licences) |
| `tiles.png` | the tileset the two town maps use |

`flat-island.tmj` beside the scripts is the fantasy map as drawn, a flat Tiled map you can open in Tiled. Hexmosphere doesn't load it from `map/`.

## Rebuilding it

```
./build-tools.sh        # hexdisk, cells, pentagons: small tools on the H3 library in Packages/CH3
python3 -I make.py      # flat-island.tmj and map/tiles.png
python3 -I bridge.py    # map/bridge.geojson
python3 -I ends.py      # map/heusden.tmj, map/denver.tmj
python3 -I strip.py     # map/island.geojson
```

`ends.py` fetches water, rivers, land use and woods for one box around each town from the public Overpass API, once, into `osm/` (not in git). It also reads Natural Earth's urban areas, which `scripts/fetch-basemap.sh` downloads into `Basemap/naturalearth-extra/`. Hand-placed details sit on top: the landmarks and their descriptions, the named main rivers drawn as unbroken chains, and the Front Range west of Denver, which land use doesn't show.

## Licences

- **`map/heusden.tmj` and `map/denver.tmj` are under the [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/), not this repository's Apache-2.0.** They're derived from [OpenStreetMap](https://www.openstreetmap.org/copyright) data, © OpenStreetMap contributors. If you build on them, keep that licence and credit. Each file also carries the credit in its `credit` property.
- Denver's built-up area also uses [Natural Earth](https://www.naturalearthdata.com) urban areas, which are in the public domain.
- Everything else here (the scripts, the tools, `flat-island.tmj`, `island.geojson`, `bridge.geojson` and `tiles.png`) is made up or computed, and is under this repository's Apache-2.0 licence.
