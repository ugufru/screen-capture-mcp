#pragma once
#include <functional>
#include <nlohmann/json.hpp>
#include <string>
#include <unordered_map>

using json = nlohmann::json;
using ToolHandler = std::function<json(const json& arguments)>;

class McpServer {
  public:
    McpServer(const std::string& name, const std::string& version);

    // Register a tool with its handler and schema
    void add_tool(const std::string& name, const std::string& description,
                  const json& input_schema, ToolHandler handler);

    // Run the stdio event loop (blocks)
    void run();

  private:
    std::string name_;
    std::string version_;
    bool ndjson_mode_ = false;  // auto-detected from first message

    struct Tool {
        std::string name;
        std::string description;
        json input_schema;
        ToolHandler handler;
    };
    std::unordered_map<std::string, Tool> tools_;

    // Read one JSON-RPC message from stdin
    json read_message();

    // Write one JSON-RPC message to stdout
    void write_message(const json& msg);

    // Handle a single incoming message
    void handle(const json& msg);

    // Build JSON-RPC response helpers
    json make_response(const json& id, const json& result);
    json make_error(const json& id, int code, const std::string& message);
};
