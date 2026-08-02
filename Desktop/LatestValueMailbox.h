#pragma once

#include <cstddef>
#include <mutex>
#include <optional>
#include <utility>

// A capacity-one handoff for real-time state. Producers never wait for a slow
// consumer: an obsolete pending value is replaced by the newest one.
template <typename Value>
class LatestValueMailbox {
public:
    void replace(Value value) {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_pending = std::move(value);
    }

    std::optional<Value> take() {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!m_pending.has_value()) {
            return std::nullopt;
        }
        auto value = std::move(m_pending);
        m_pending.reset();
        return value;
    }

    void clear() {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_pending.reset();
    }

    std::size_t pendingCount() const {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_pending.has_value() ? 1 : 0;
    }

private:
    mutable std::mutex m_mutex;
    std::optional<Value> m_pending;
};
