# Use ordered singleton maps for saved query locations

Orbit accepts saved query locations as an ordered array of singleton maps, such as `{ { Work = "~/sql/work" }, { Personal = "~/sql/personal" } }`. The map key is the exact Workspace label and the value is its directory; this preserves explicit display order while keeping each location concise and named, rather than deriving user-facing names from filesystem basenames or using an unordered map.
