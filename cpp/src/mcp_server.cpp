#include "mcp_server.h"

#include <cstdio>
#include <iostream>
#include <sstream>
#include <stdexcept>

McpServer::McpServer(const std::string& name, const std::string& version)
    : name_(name), version_(version) {}

void McpServer::add_tool(const std::string& name,
                         const std::string& description,
                         const json& input_schema, ToolHandler handler) {
    tools_[name] = {name, description, input_schema, std::move(handler)};
}

json McpServer::read_message() {
    // Support both Content-Length framing (LSP-style) and bare NDJSON.
    // Detect mode by peeking at the first non-whitespace byte:
    //   '{' → NDJSON line
    //   'C'  → Content-Length header

    // Skip blank lines / whitespace between messages
    int ch;
    while ((ch = std::cin.peek()) != EOF) {
        if (ch == '{' || ch == 'C') break;
        std::cin.get();  // consume whitespace / newlines
    }
    if (ch == EOF) {
        throw std::runtime_error("EOF");
    }

    if (ch == '{') {
        // NDJSON mode: read one line of JSON
        ndjson_mode_ = true;
        std::string line;
        if (!std::getline(std::cin, line)) {
            throw std::runtime_error("EOF reading NDJSON line");
        }
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        return json::parse(line);
    }

    // Content-Length framing mode
    std::string line;
    int content_length = -1;

    while (std::getline(std::cin, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line.empty()) {
            break;
        }
        if (line.rfind("Content-Length:", 0) == 0) {
            content_length = std::stoi(line.substr(15));
        }
    }

    if (content_length < 0) {
        throw std::runtime_error("No Content-Length header");
    }

    std::string body(content_length, '\0');
    std::cin.read(body.data(), content_length);

    if (std::cin.gcount() != content_length) {
        throw std::runtime_error("Incomplete message body");
    }

    return json::parse(body);
}

void McpServer::write_message(const json& msg) {
    std::string body = msg.dump();
    if (ndjson_mode_) {
        std::cout << body << "\n";
    } else {
        std::cout << "Content-Length: " << body.size() << "\r\n"
                  << "\r\n"
                  << body;
    }
    std::cout.flush();
}

json McpServer::make_response(const json& id, const json& result) {
    return {{"jsonrpc", "2.0"}, {"id", id}, {"result", result}};
}

json McpServer::make_error(const json& id, int code,
                           const std::string& message) {
    return {{"jsonrpc", "2.0"},
            {"id", id},
            {"error", {{"code", code}, {"message", message}}}};
}

void McpServer::handle(const json& msg) {
    std::string method = msg.value("method", "");
    json id = msg.contains("id") ? msg["id"] : json(nullptr);

    // ── initialize ───────────────────────────────────────────────────
    if (method == "initialize") {
        json result = {
            {"protocolVersion", "2024-11-05"},
            {"capabilities",
             {{"tools", {{"listChanged", false}}}}},
            {"serverInfo", {{"name", name_}, {"version", version_}}}};
        write_message(make_response(id, result));
        return;
    }

    // ── notifications (no response needed) ───────────────────────────
    if (id.is_null()) {
        return;  // notifications like "notifications/initialized"
    }

    // ── tools/list ───────────────────────────────────────────────────
    if (method == "tools/list") {
        json tool_list = json::array();
        for (auto& [name, tool] : tools_) {
            tool_list.push_back(
                {{"name", tool.name},
                 {"description", tool.description},
                 {"inputSchema", tool.input_schema}});
        }
        write_message(make_response(id, {{"tools", tool_list}}));
        return;
    }

    // ── tools/call ───────────────────────────────────────────────────
    if (method == "tools/call") {
        std::string tool_name = msg["params"]["name"];
        json arguments = msg["params"].value("arguments", json::object());

        auto it = tools_.find(tool_name);
        if (it == tools_.end()) {
            write_message(
                make_error(id, -32601, "Unknown tool: " + tool_name));
            return;
        }

        try {
            json content = it->second.handler(arguments);
            write_message(make_response(id, {{"content", content}}));
        } catch (const std::exception& e) {
            json error_content = json::array();
            error_content.push_back(
                {{"type", "text"}, {"text", std::string(e.what())}});
            write_message(
                make_response(id, {{"content", error_content},
                                   {"isError", true}}));
        }
        return;
    }

    // ── unknown method ───────────────────────────────────────────────
    write_message(make_error(id, -32601, "Method not found: " + method));
}

void McpServer::run() {
    // Unbuffer stderr for logging
    std::cerr << "screen-capture-mcp: server starting" << std::endl;

    while (std::cin.good()) {
        try {
            json msg = read_message();
            handle(msg);
        } catch (const std::exception& e) {
            // EOF or parse error — exit gracefully
            std::cerr << "screen-capture-mcp: " << e.what() << std::endl;
            break;
        }
    }
}
