#include "../ReceiverRouteClassifier.h"

#include <cassert>
#include <iostream>

int main() {
    assert(preferredBufferedVideoNanosecondsFor(
        ReceiverAdvertisedRoute::thunderbolt
    ) == 300'000'000);
    assert(preferredBufferedVideoNanosecondsFor(
        ReceiverAdvertisedRoute::ethernet
    ) == 200'000'000);
    assert(preferredBufferedVideoNanosecondsFor(
        ReceiverAdvertisedRoute::wifi
    ) == 300'000'000);
    assert(preferredBufferedVideoNanosecondsFor(
        ReceiverAdvertisedRoute::excluded
    ) == 300'000'000);

    assert(classifyReceiverAdvertisedRoute(
        "Wi-Fi Intel Wireless",
        {"192.168.31.235"},
        true
    ) == ReceiverAdvertisedRoute::wifi);

    assert(classifyReceiverAdvertisedRoute(
        "Ethernet Realtek PCIe",
        {"192.168.31.120"},
        true
    ) == ReceiverAdvertisedRoute::ethernet);

    assert(classifyReceiverAdvertisedRoute(
        "Ethernet 2",
        {"169.254.204.111"},
        true
    ) == ReceiverAdvertisedRoute::thunderbolt);

    assert(classifyReceiverAdvertisedRoute(
        "USB4 Peer Network",
        {"169.254.204.111"},
        true
    ) == ReceiverAdvertisedRoute::thunderbolt);

    assert(classifyReceiverAdvertisedRoute(
        "vEthernet (Default Switch)",
        {"172.20.16.1"},
        true
    ) == ReceiverAdvertisedRoute::excluded);

    assert(classifyReceiverAdvertisedRoute(
        "Ethernet 2",
        {"169.254.204.111"},
        false
    ) == ReceiverAdvertisedRoute::ethernet);

    std::cout << "ReceiverRouteClassifier tests passed\n";
    return 0;
}
