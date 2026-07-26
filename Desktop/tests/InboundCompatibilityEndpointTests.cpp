#include "../InboundCompatibilityEndpoint.h"

#include <cassert>
#include <iostream>

int main() {
    const auto manualEndpoint =
        InboundCompatibilityEndpoint::manual("192.168.1.50", 51820);
    assert(manualEndpoint.origin == InboundConnectionOrigin::manual);
    assert(manualEndpoint.host == "192.168.1.50");
    assert(manualEndpoint.port == 51820);

    const auto adbEndpoint = InboundCompatibilityEndpoint::adb(51821);
    assert(adbEndpoint.origin == InboundConnectionOrigin::adb);
    assert(adbEndpoint.host == "localhost");
    assert(adbEndpoint.port == 51821);

    std::cout << "InboundCompatibilityEndpoint tests passed\n";
    return 0;
}
