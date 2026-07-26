#pragma once

#include <cstdint>
#include <string>
#include <utility>

enum class InboundConnectionOrigin {
    manual,
    adb,
};

/// Explicit fallback endpoint for receiving from a Remote Sender.
///
/// Compatibility endpoints are never populated by discovery. Normal Receiver
/// operation advertises its listener and waits for the Sender to connect.
struct InboundCompatibilityEndpoint {
    std::string host;
    std::uint16_t port = 0;
    InboundConnectionOrigin origin = InboundConnectionOrigin::manual;

    static InboundCompatibilityEndpoint manual(
        std::string host,
        std::uint16_t port
    ) {
        return {
            std::move(host),
            port,
            InboundConnectionOrigin::manual,
        };
    }

    static InboundCompatibilityEndpoint adb(std::uint16_t localPort) {
        return {
            "localhost",
            localPort,
            InboundConnectionOrigin::adb,
        };
    }
};
