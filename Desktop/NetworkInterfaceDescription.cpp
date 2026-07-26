#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#endif

#include "NetworkInterfaceDescription.h"

#include <QStringList>
#include <vector>

QString detailedNetworkInterfaceDescription(
    const QNetworkInterface& networkInterface
) {
    QStringList descriptions = {
        networkInterface.name(),
        networkInterface.humanReadableName(),
    };

#ifdef _WIN32
    ULONG bufferSize = 0;
    if (GetAdaptersAddresses(
            AF_UNSPEC,
            GAA_FLAG_INCLUDE_ALL_INTERFACES,
            nullptr,
            nullptr,
            &bufferSize
        ) == ERROR_BUFFER_OVERFLOW) {
        std::vector<unsigned char> buffer(bufferSize);
        auto* adapters =
            reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
        if (GetAdaptersAddresses(
                AF_UNSPEC,
                GAA_FLAG_INCLUDE_ALL_INTERFACES,
                nullptr,
                adapters,
                &bufferSize
            ) == NO_ERROR) {
            for (auto* adapter = adapters;
                 adapter != nullptr;
                 adapter = adapter->Next) {
                if (adapter->IfIndex != networkInterface.index()
                    && adapter->Ipv6IfIndex != networkInterface.index()) {
                    continue;
                }
                if (adapter->Description != nullptr) {
                    descriptions.append(
                        QString::fromWCharArray(adapter->Description)
                    );
                }
                break;
            }
        }
    }
#endif

    descriptions.removeAll(QString());
    descriptions.removeDuplicates();
    return descriptions.join(' ');
}
