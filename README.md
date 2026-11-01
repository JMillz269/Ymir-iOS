# Ymir-iOS

[![iOS build](https://github.com/JMillz269/Ymir-iOS/actions/workflows/ios.yaml/badge.svg)](https://github.com/JMillz269/Ymir-iOS/actions/workflows/ios.yaml)

A work-in-progress Sega Saturn emulator ported to iOS. This port is supported by myself and I am not affiliated with the original developer. AI was used to create this app with a lot of oversight by myself. This was my "play with AI" app and think it did pretty well honestly.

<img width="330" height="717" alt="Image (5)" src="https://github.com/user-attachments/assets/b9054d6b-9659-47a2-8e26-4c7399183b94" /> 
<img width="330" height="717" alt="Image (4)" src="https://github.com/user-attachments/assets/fdcb54f0-9398-4c12-b709-c3f746000a71" />
<br>
<img width="717" height="330" alt="Image (3)" src="https://github.com/user-attachments/assets/c06c52fa-be3e-4f1d-9d7c-7e1adf09dd38" />
<br>

## Features

- Retains all original features from Ymir (upstream)
- iOS Dynamic Recompiler with JIT (Supports StikDebug/StosDebug with the Universal.js script)
- Interpreter
- Can emulate SH-2 Cache for higher Accuracy
- New iOS Metal Renderer
- Draw Polygons and Sprites on GPU
- Direct Display
- Skip Native Drawing (helpful when using upscaling)
- Deinterlacing
- Transparent Meshes
- Video Sync
- Frame Delay
- Frame Pacing (use Sega Saturn frame pacing or display's)
- Reduce Latency Toggle
- Option to use Full Refresh Rate (for devices that support Pro Motion 120fps)
- Keep Registers in CPU Registers
- Link Blocks Directly
- Skip Idle Waiting
- Multithreaded VDP1, VDP2, Deinterlacer, Sound Chip
- Boost Emulator Thread Priority
- Optional Performance Log for debugging
- Scaling Options (different game Aspect Ratios)
- Upscaling Internal Resolution up to 4x
- MetalFX Upscaling (Spatial and Temporal)
- MetalFX Picture Filters (Sharp Pixels, Sharpening, Scanlines, Aperture Grille)
- Supports LiveContainer
- Save States
- Built-in Convert games to CHD via Settings or long press on game
- I think that's about it! Tons of options :) 



## Support the original Ymir Dev!

If you enjoy this project and want to help the original dev keep developing them, consider supporting them:
- [Patreon](https://www.patreon.com/StrikerX3) for ongoing support
