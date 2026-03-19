# Screen Capture MCP

A macOS-native MCP server that gives AI agents the ability to capture screenshots. Built with C++20/ObjC++20 using ScreenCaptureKit. Designed for claude-code feedback loops while cross-developing applications.

## Tools

- **`list_displays`** — Enumerate displays (index, resolution, main flag)
- **`capture_screen`** — Screenshot a display or sub-region; returns PNG image. Params: `display_index`, `x`, `y`, `width`, `height`
- **`capture_window`** — Screenshot a window by app name (case-insensitive substring). Params: `app_name` (required), `window_title`

## Build

```sh
cd cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Binary: `cpp/build/screen-capture-mcp`

## Setup

Add to your `.mcp.json`:

```json
{
  "mcpServers": {
    "screen-capture": {
      "command": "/path/to/cpp/build/screen-capture-mcp",
      "args": []
    }
  }
}
```

**Requires macOS 14.0+** and Screen Recording permission granted to the host process (System Settings > Privacy & Security > Screen Recording).

## Architecture

- **`main.mm`** — Tool definitions, argument handling, and the threading setup that wires everything together
- **`mcp_server.{h,cpp}`** — Generic MCP protocol layer: stdio JSON-RPC 2.0 message loop, tool registration, request routing
- **`screen_capture.{h,mm}`** — ScreenCaptureKit wrapper: display enumeration, screen/window capture, PNG encoding
- **`base64.h`** — Base64 encoding for image data

### Dependencies

- [nlohmann/json](https://github.com/nlohmann/json) v3.11.3 (fetched automatically via CMake FetchContent)
- Apple frameworks: ScreenCaptureKit, CoreGraphics, Foundation, ImageIO, UniformTypeIdentifiers, AppKit

## Implementation Notes

Getting ScreenCaptureKit to work correctly in a CLI tool required solving two interacting concurrency problems:

### Problem 1: Main run loop required

ScreenCaptureKit uses XPC internally to communicate with `replayd`. XPC replies are delivered through the main run loop. A naive single-threaded design (read stdin, call ScreenCaptureKit, write stdout) deadlocks because the main thread is blocked reading stdin and can never service the run loop.

**Solution:** The MCP stdin/stdout message loop runs on a background dispatch queue. The main thread runs `[NSApp run]` to keep the run loop (and main dispatch queue) alive for XPC and AppKit callbacks.

### Problem 2: ScreenCaptureKit object lifetimes

`SCShareableContent` is populated from XPC response data. After the completion handler returns, the framework releases the internal arrays (displays, windows) on the XPC thread. Code that stores a pointer to `SCShareableContent` and accesses `.displays` or `.windows` later hits a use-after-free — the objects are deallocated out from under you.

This manifests as a `SIGSEGV` in `objc_msgSend` when accessing `content.displays`, with the XPC thread's stack showing `__RELEASE_OBJECTS_IN_THE_ARRAY__` and `[SCWindow .cxx_destruct]`.

**Solution:** All data extraction from ScreenCaptureKit objects happens inside the completion handler, before it returns. C++ value types (`std::string`, `std::vector<DisplayInfo>`, etc.) are populated within the callback and passed out via `__block` variables. By the time the semaphore is signaled and the calling thread resumes, all ObjC object access is complete.

### Problem 3: NSScreen requires the main thread

`[NSScreen screens]` is an AppKit call that must run on the main thread. Since the completion handler runs on ScreenCaptureKit's internal XPC queue (not the main thread), calling `[NSScreen screens]` directly from the callback would crash.

**Solution:** Inside the completion handler, `dispatch_sync(dispatch_get_main_queue(), ...)` is used to fetch NSScreen info safely. This works because the XPC queue is not the main queue, so `dispatch_sync` to main won't deadlock — and the main thread's run loop is active (via `[NSApp run]`), so it can service the dispatch.

### The threading model

```
Main thread:          [NSApp run]  — services run loop, main dispatch queue
Background thread:    server.run() — reads stdin, dispatches tool handlers
XPC thread (system):  completion handlers fire here
                      -> extracts all data from SCKit objects
                      -> dispatch_sync to main for NSScreen
                      -> signals semaphore
Background thread:    semaphore unblocks, returns C++ data to MCP response
```
