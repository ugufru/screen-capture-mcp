# Screen Capture MCP Server

macOS screen capture MCP server using ScreenCaptureKit. C++20/ObjC++20, macOS 14+.

## Build

```sh
cd cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Binary: `cpp/build/screen-capture-mcp`

## Architecture

- **`mcp_server.{h,cpp}`** — Generic MCP protocol layer: stdio JSON-RPC 2.0 message loop, tool registration, request routing
- **`screen_capture.{h,mm}`** — ScreenCaptureKit wrapper: display enumeration, screen/window capture, PNG encoding
- **`main.cpp`** — Tool definitions and argument handling; wires capture functions to MCP tools
- **`base64.h`** — Base64 encoding for image data

## MCP Tools

- **`list_displays`** — Enumerate displays (index, resolution, main flag)
- **`capture_screen`** — Screenshot a display or sub-region; returns PNG image. Params: `display_index`, `x`, `y`, `width`, `height`
- **`capture_window`** — Screenshot a window by app name (case-insensitive substring). Params: `app_name` (required), `window_title`

## Dependencies

- nlohmann/json v3.11.3 (fetched via CMake FetchContent)
- Frameworks: ScreenCaptureKit, CoreGraphics, Foundation, ImageIO, UniformTypeIdentifiers, AppKit

## Requirements

- macOS 14.0+ (deployment target)
- Screen Recording permission must be granted to the host process
