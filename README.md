# Nightlume

**Apple Silicon-optimized Moonlight game streaming client**

Nightlume is an open source fork of [Moonlight PC](https://moonlight-stream.org) built exclusively for Apple Silicon Macs, featuring hardware-accelerated video decoding via VideoToolbox and Metal rendering optimizations.

---

## Features

- **Hardware-accelerated VideoToolbox decoding** - H.264, HEVC, and AV1 codec support
- **Optimized Metal renderer** - Apple Silicon-specific rendering pipeline
- **Native CoreAudio** - Low-latency audio with proper buffer management
- **HDR streaming support** - Full HDR passthrough on supported displays
- **YUV 4:4:4 support** - Enhanced color accuracy (Sunshine only)
- **7.1 surround sound** - Full spatial audio support
- **Gamepad support** - Force feedback and motion controls for up to 16 players
- **10-point multitouch** - Touch input passthrough (Sunshine only)

---

## Nightlume Enhancements

This fork includes Apple Silicon-specific improvements over upstream Moonlight:

### Video & Rendering
- **Enhanced Metal renderer** - Optimized shader pipeline in `vt_metal.mm`
- **MetalFX integration** - Apple's native upscaling technology
- **Improved overlay system** - Better performance overlay rendering
- **Frame pacing improvements** - Smoother playback with enhanced pacer

### Audio
- **Native CoreAudio renderer** - Bypasses SDL for lower latency
- **Proper buffer management** - Optimized for Apple Silicon audio subsystem

### System Integration
- **macOS Performance Manager** - QoS tuning, power management, thermal optimization
- **XPC Helper Service** - Privileged operations via launchd
- **Debug logging infrastructure** - Comprehensive macOS-specific diagnostics

### Files Modified
Key areas of modification from upstream:
- `app/streaming/macos/` - Performance infrastructure and helper protocol
- `app/streaming/video/vt_metal.mm` - Metal renderer optimizations
- `app/streaming/audio/renderers/coreaudio.mm` - Native audio renderer
- `app/helper/` - XPC helper service
- `app/shaders/vt_renderer.metal` - Metal shader enhancements

---

## Requirements

- **macOS 13+** (Ventura or later)
- **Apple Silicon Mac** (M1, M2, M3 series)
- **Xcode 14+** for building from source
- **Qt 6.7+** SDK

## Building

```bash
# Clone with submodules
git clone --recursive https://github.com/YOUR_USERNAME/nightlume.git
cd nightlume

# Build
qmake6 moonlight-qt.pro
make release

# Create DMG (optional)
scripts/generate-dmg.sh
```

### Build Requirements
- Qt 6.7 SDK or later
- Xcode 14 or later
- [create-dmg](https://github.com/sindresorhus/create-dmg) (only for distributable DMGs)

---

## Upstream

Based on [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt) - open source client for NVIDIA GameStream and [Sunshine](https://github.com/LizardByte/Sunshine).

## License

GPLv3 - See [LICENSE](LICENSE) for details.
