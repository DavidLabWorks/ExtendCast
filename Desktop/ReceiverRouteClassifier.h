#pragma once

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <string>
#include <vector>

enum class ReceiverAdvertisedRoute {
    excluded,
    wifi,
    ethernet,
    thunderbolt,
};

inline std::uint64_t preferredBufferedVideoNanosecondsFor(
    ReceiverAdvertisedRoute route
) {
    switch (route) {
    case ReceiverAdvertisedRoute::thunderbolt:
        return 300'000'000;
    case ReceiverAdvertisedRoute::ethernet:
        return 200'000'000;
    case ReceiverAdvertisedRoute::wifi:
    case ReceiverAdvertisedRoute::excluded:
        return 300'000'000;
    }
    return 300'000'000;
}

inline ReceiverAdvertisedRoute classifyReceiverAdvertisedRoute(
    std::string interfaceDescription,
    const std::vector<std::string>& ipv4Addresses,
    bool recognizeWindowsUsb4EthernetAlias
) {
    std::transform(
        interfaceDescription.begin(),
        interfaceDescription.end(),
        interfaceDescription.begin(),
        [](unsigned char character) {
            return static_cast<char>(std::tolower(character));
        }
    );

    const auto contains = [&](const std::string& value) {
        return interfaceDescription.find(value) != std::string::npos;
    };

    if (contains("virtual")
        || contains("vethernet")
        || contains("loopback")
        || contains("hyper-v")
        || contains("vmware")
        || contains("virtualbox")
        || contains("wsl")
        || contains("tailscale")
        || contains("zerotier")
        || contains("wireguard")
        || contains("vpn")
        || contains("mihomo")
        || contains("clash")
        || contains("proxy")) {
        return ReceiverAdvertisedRoute::excluded;
    }
    if (contains("thunderbolt") || contains("usb4")) {
        return ReceiverAdvertisedRoute::thunderbolt;
    }
    if (contains("wi-fi")
        || contains("wifi")
        || contains("wireless")
        || contains("wlan")) {
        return ReceiverAdvertisedRoute::wifi;
    }
    const bool hasLinkLocalAddress = std::any_of(
        ipv4Addresses.begin(),
        ipv4Addresses.end(),
        [](const std::string& address) {
            return address.rfind("169.254.", 0) == 0;
        }
    );
    const bool hasGenericEthernetName =
        contains("ethernet") || contains("\xE4\xBB\xA5\xE5\xA4\xAA\xE7\xBD\x91");
    if (recognizeWindowsUsb4EthernetAlias
        && hasGenericEthernetName
        && hasLinkLocalAddress) {
        return ReceiverAdvertisedRoute::thunderbolt;
    }
    return ReceiverAdvertisedRoute::ethernet;
}
