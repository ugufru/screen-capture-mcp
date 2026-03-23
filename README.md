# Screen Capture MCP Server

A macOS-native MCP server that gives AI agents the ability to capture screenshots. Built with C++20/ObjC++20 using ScreenCaptureKit. Designed for Claude Code feedback loops while cross-developing applications.

## Features

| Tool | Description |
|------|-------------|
| **`list_displays`** | Discover available displays with index, resolution, and main display flag |
| **`capture_screen`** | Capture a full display or sub-region, returned as a base64 PNG that Claude can see directly |
| **`capture_window`** | Capture a specific application window by name, returned as a base64 PNG |

## Prerequisites

- **macOS 14+** (Sonoma or later)
- **Xcode Command Line Tools** — `xcode-select --install`
- **CMake** — `brew install cmake`

## Build

```bash
make build
```

This runs CMake and compiles the native binary to `cpp/build/screen-capture-mcp`.

Other targets: `make clean`, `make rebuild`.

## Configuration

### Claude Code (project-scoped)

The repo includes `.mcp.json` — just clone and build:

```json
{
  "mcpServers": {
    "screen-capture": {
      "command": "./cpp/build/screen-capture-mcp"
    }
  }
}
```

### Claude Code (global)

To make the server available in all sessions regardless of working directory:

```bash
claude mcp add --transport stdio --scope user screen-capture /path/to/screen-capture-mcp/cpp/build/screen-capture-mcp
```

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "screen-capture": {
      "command": "/path/to/screen-capture-mcp/cpp/build/screen-capture-mcp"
    }
  }
}
```

### Screen Recording Permission

On first use, macOS will prompt for screen recording access. The terminal app running the MCP server (Terminal, iTerm2, etc.) must be granted permission in **System Settings > Privacy & Security > Screen Recording**.

## Tool Reference

### `list_displays`

No parameters. Returns an array of displays with `index`, `display_id`, `name`, `width`, `height`, and `is_main` fields.

### `capture_screen`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `display_index` | integer | `0` | Display index from `list_displays` |
| `x` | integer | — | Region X offset (optional) |
| `y` | integer | — | Region Y offset (optional) |
| `width` | integer | — | Region width (optional) |
| `height` | integer | — | Region height (optional) |

Returns a base64-encoded PNG image inline that Claude can see directly. When `x`/`y`/`width`/`height` are provided, captures only that sub-region of the display.

### `capture_window`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `app_name` | string | *(required)* | Application name (case-insensitive substring match) |
| `window_title` | string | — | Window title filter (case-insensitive substring, optional) |

Returns a base64-encoded PNG of the matched window.

## Usage Examples

### Discover displays

> "What displays are connected to this machine?"

Claude calls `list_displays` and returns a list of displays with their resolutions and which is the main display.

### Capture a screenshot

> "Take a screenshot of my main display"

Claude calls `capture_screen` with `display_index=0` and receives a PNG image it can see and describe.

### Capture a region

> "Screenshot the top-left 800x600 corner of my screen"

Claude calls `capture_screen` with `x=0`, `y=0`, `width=800`, `height=600`.

### Capture an app window

> "Show me what Safari looks like right now"

Claude calls `capture_window` with `app_name="Safari"` and receives a PNG of the Safari window.

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

## License

BSD 2-Clause. See [LICENSE](LICENSE).
