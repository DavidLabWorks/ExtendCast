#include "../InboundSessionRegistry.h"

#include <cassert>
#include <iostream>

int main() {
    InboundSessionRegistry registry;

    registry.open("connection-a", "192.168.1.10", "192.168.1.10");
    registry.open("connection-b", "192.168.1.11", "192.168.1.11");
    registry.open("bonjour-probe", "fe80::1", "fe80::1");

    assert(registry.activeSessionCount() == 0);
    assert(!registry.close("bonjour-probe").wasActive);

    const auto first = registry.identify(
        "connection-a",
        "mac-mini-stable-id",
        "Studio Mac mini"
    );
    assert(first.has_value());
    assert(first->newlyAdmitted);
    assert(first->binding.connectionId == "connection-a");

    const auto second = registry.identify(
        "connection-b",
        "macbook-stable-id",
        "Travel MacBook"
    );
    assert(second.has_value());
    assert(second->newlyAdmitted);
    assert(second->binding.connectionId == "connection-b");
    assert(registry.activeSessionCount() == 2);

    const auto routedA = registry.sessionForConnection("connection-a");
    const auto routedB = registry.sessionForConnection("connection-b");
    assert(routedA.has_value());
    assert(routedB.has_value());
    assert(routedA->connectionId != routedB->connectionId);

    registry.open("connection-a-replacement", "169.254.1.10", "169.254.1.10");
    const auto replacement = registry.identify(
        "connection-a-replacement",
        "mac-mini-stable-id",
        "Studio Mac mini"
    );
    assert(replacement.has_value());
    assert(!replacement->newlyAdmitted);
    assert(replacement->replacedConnectionId == "connection-a");
    assert(!registry.sessionForConnection("connection-a").has_value());
    assert(registry.sessionForConnection("connection-a-replacement")->deviceId
           == "mac-mini-stable-id");
    assert(registry.sessionForConnection("connection-b")->deviceId
           != replacement->binding.deviceId);

    const auto closedA = registry.close("connection-a");
    assert(!closedA.wasActive);
    assert(registry.sessionForConnection("connection-a-replacement").has_value());

    const auto closedReplacement = registry.close("connection-a-replacement");
    assert(closedReplacement.wasActive);
    assert(closedReplacement.deviceId == "mac-mini-stable-id");
    assert(registry.sessionForConnection("connection-b").has_value());
    assert(registry.activeSessionCount() == 1);

    std::cout << "InboundSessionRegistry tests passed\n";
    return 0;
}
