#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>

struct ReceiverSessionBinding {
    std::string connectionId;
    std::string deviceId;
    std::string displayName;
    std::string peerAddress;
};

struct ReceiverIdentificationResult {
    ReceiverSessionBinding binding;
    std::optional<std::string> replacedConnectionId;
    bool newlyAdmitted = false;
};

struct ReceiverCloseResult {
    std::string connectionId;
    std::string deviceId;
    bool wasActive = false;
};

class ReceiverSessionRegistry {
public:
    void open(
        const std::string& connectionId,
        const std::string& peerAddress,
        const std::string& fallbackDisplayName
    ) {
        PendingConnection pending;
        pending.peerAddress = peerAddress;
        pending.fallbackDisplayName = fallbackDisplayName;
        m_pendingByConnection[connectionId] = std::move(pending);
    }

    std::optional<ReceiverIdentificationResult> identify(
        const std::string& connectionId,
        const std::string& deviceId,
        const std::string& displayName
    ) {
        const auto pending = m_pendingByConnection.find(connectionId);
        if (pending == m_pendingByConnection.end() || deviceId.empty()) {
            return std::nullopt;
        }

        ReceiverSessionBinding binding;
        binding.connectionId = connectionId;
        binding.deviceId = deviceId;
        binding.displayName =
            displayName.empty() ? pending->second.fallbackDisplayName : displayName;
        binding.peerAddress = pending->second.peerAddress;

        ReceiverIdentificationResult result;
        result.binding = binding;

        const auto active = m_activeByDevice.find(deviceId);
        if (active != m_activeByDevice.end()) {
            if (active->second.connectionId != connectionId) {
                result.replacedConnectionId = active->second.connectionId;
                m_deviceByConnection.erase(active->second.connectionId);
            }
        } else {
            result.newlyAdmitted = true;
        }

        m_activeByDevice[deviceId] = binding;
        m_deviceByConnection[connectionId] = deviceId;
        return result;
    }

    std::optional<ReceiverSessionBinding> sessionForConnection(
        const std::string& connectionId
    ) const {
        const auto device = m_deviceByConnection.find(connectionId);
        if (device == m_deviceByConnection.end()) {
            return std::nullopt;
        }
        const auto active = m_activeByDevice.find(device->second);
        if (active == m_activeByDevice.end()
            || active->second.connectionId != connectionId) {
            return std::nullopt;
        }
        return active->second;
    }

    std::optional<ReceiverSessionBinding> sessionForDevice(
        const std::string& deviceId
    ) const {
        const auto active = m_activeByDevice.find(deviceId);
        if (active == m_activeByDevice.end()) {
            return std::nullopt;
        }
        return active->second;
    }

    ReceiverCloseResult close(const std::string& connectionId) {
        ReceiverCloseResult result;
        result.connectionId = connectionId;
        m_pendingByConnection.erase(connectionId);

        const auto device = m_deviceByConnection.find(connectionId);
        if (device == m_deviceByConnection.end()) {
            return result;
        }

        result.deviceId = device->second;
        m_deviceByConnection.erase(device);

        const auto active = m_activeByDevice.find(result.deviceId);
        if (active != m_activeByDevice.end()
            && active->second.connectionId == connectionId) {
            m_activeByDevice.erase(active);
            result.wasActive = true;
        }
        return result;
    }

    void clear() {
        m_pendingByConnection.clear();
        m_deviceByConnection.clear();
        m_activeByDevice.clear();
    }

    std::size_t activeSessionCount() const {
        return m_activeByDevice.size();
    }

private:
    struct PendingConnection {
        std::string peerAddress;
        std::string fallbackDisplayName;
    };

    std::unordered_map<std::string, PendingConnection> m_pendingByConnection;
    std::unordered_map<std::string, std::string> m_deviceByConnection;
    std::unordered_map<std::string, ReceiverSessionBinding> m_activeByDevice;
};
