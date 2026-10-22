# OpenStreetMap place names

The files in this folder are extracts of OpenStreetMap data, © OpenStreetMap contributors,
available under the Open Database License (ODbL) 1.0: https://opendatacommons.org/licenses/odbl/1-0/

They were made with `scripts/fetch-basemap.sh`, which queries the Overpass API for
`place=city|town|suburb|village` nodes with a name inside a bounding box, and keeps the
name, place type and population. This folder is the derived database, shared under ODbL.
The app shows "© OpenStreetMap contributors" whenever this map is visible.
