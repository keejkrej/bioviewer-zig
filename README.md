# bioviewer-zig

Pure-Zig microscopy multi-dimensional dataset viewer built on the Native SDK (`../native`), porting `bioviewer-rs` to Zig and integrating `czi-zig` (`../czi-zig`) and `nd2-zig` (`../nd2-zig`).

## Features

- **Multi-format Microscopy Support**:
  - Micro-Manager multi-position / time-lapse / Z-stack / multi-channel TIFF series folders
  - Carl Zeiss `.czi` files (via `czi-zig`, including Zstd0/Zstd1 HiLo-packed decompression and XML channel metadata)
  - Nikon NIS-Elements `.nd2` files (via `nd2-zig`, including v2/v3 chunk map parsing and raw/zlib planes)
- **Channel Compositing & Contrast**:
  - Automatic UTF-16LE Micro-Manager & CZI/ND2 channel classification (`Brightfield`, `DAPI`, `FITC`, `Cy3`, `Cy5`)
  - Per-channel black/white display window (`low`..`high`), brightness gain, and color preset buttons
  - Automatic percentile range calculation (`0.1%..99.9%`) with phase-contrast saturation halo tail suppression
- **Interactive Native SDK GUI**:
  - Folder and position browser sidebar
  - Real-time multi-channel RGBA8 composite viewport with zoom controls (`-`, `100%`, `+`)
  - Time-lapse playback transport (`Prev`, `Play`/`Pause`, `Next`, scrubber slider), Z-slice selector, and keyboard navigation (`Left`/`Right` step time, `Up`/`Down` step position, `Space` toggles play)

## Build & Test

```sh
zig build
zig build test --summary all
```
