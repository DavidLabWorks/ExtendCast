#pragma once

#include "VideoPacket.h"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>
#include <utility>

/// How to prepare the decoder before feeding the next access unit.
/// Catch-up to an in-band IDR must Flush — never HardReset a healthy decoder.
enum class VideoDecodeResumeAction {
    Continue,
    Flush,
    HardReset,
};

/// Bounds compressed frames before software decoding. When decoding falls
/// behind, dependent frames are discarded only at a keyframe boundary.
template <typename Packet>
class VideoDecodeQueue {
public:
    struct Item {
        Packet packet;
        VideoDecodeResumeAction resumeAction = VideoDecodeResumeAction::Continue;
    };

    struct EnqueueResult {
        bool scheduleDrain = false;
        bool requestKeyframe = false;
        std::size_t discardedFrames = 0;
    };

    VideoDecodeQueue(
        std::uint64_t maximumBufferedDurationNanoseconds,
        std::size_t maximumPendingFrames
    )
        : m_maximumBufferedDurationNanoseconds(
              maximumBufferedDurationNanoseconds
          )
        , m_maximumPendingFrames(maximumPendingFrames)
    {
    }

    EnqueueResult enqueue(
        Packet packet,
        const video_packet::Header& header
    ) {
        std::lock_guard<std::mutex> lock(m_mutex);
        EnqueueResult result;

        if (m_waitingForKeyframe) {
            if (!header.isKeyframe) {
                return result;
            }
            m_waitingForKeyframe = false;
            const VideoDecodeResumeAction resume = m_hardResetBeforeNextFrame
                ? VideoDecodeResumeAction::HardReset
                : VideoDecodeResumeAction::Flush;
            m_hardResetBeforeNextFrame = false;
            m_pending.clear();
            m_pending.push_back(Entry{
                std::move(packet),
                header,
                resume,
            });
            result.scheduleDrain = markDrainScheduled();
            return result;
        }

        VideoDecodeResumeAction resume = VideoDecodeResumeAction::Continue;
        if (m_hardResetBeforeNextFrame) {
            resume = VideoDecodeResumeAction::HardReset;
            m_hardResetBeforeNextFrame = false;
            m_flushBeforeNextFrame = false;
        } else if (m_flushBeforeNextFrame) {
            resume = VideoDecodeResumeAction::Flush;
            m_flushBeforeNextFrame = false;
        }

        m_pending.push_back(Entry{
            std::move(packet),
            header,
            resume,
        });

        if (backlogExceeded()) {
            const std::size_t newestKeyframeIndex =
                findNewestUsableKeyframe();
            if (newestKeyframeIndex < m_pending.size()) {
                result.discardedFrames = newestKeyframeIndex;
                m_pending.erase(
                    m_pending.begin(),
                    m_pending.begin()
                        + static_cast<std::ptrdiff_t>(newestKeyframeIndex)
                );
                // Skip to an already-buffered IDR without tearing the decoder down.
                m_pending.front().resumeAction = VideoDecodeResumeAction::Flush;
            } else {
                result.discardedFrames = m_pending.size();
                m_pending.clear();
                m_waitingForKeyframe = true;
                m_hardResetBeforeNextFrame = false;
                result.requestKeyframe = true;
            }
        }

        if (!m_pending.empty()) {
            result.scheduleDrain = markDrainScheduled();
        }
        return result;
    }

    std::optional<Item> takeNext() {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_pending.empty()) {
            m_drainScheduled = false;
            return std::nullopt;
        }

        Entry entry = std::move(m_pending.front());
        m_pending.pop_front();
        return Item{
            std::move(entry.packet),
            entry.resumeAction,
        };
    }

    bool waitForKeyframeAfterDecodeError() {
        std::lock_guard<std::mutex> lock(m_mutex);
        const bool shouldRequest = !m_waitingForKeyframe;
        m_pending.clear();
        m_waitingForKeyframe = true;
        m_hardResetBeforeNextFrame = true;
        m_drainScheduled = false;
        return shouldRequest;
    }

    void clearForStreamReset() {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_pending.clear();
        m_waitingForKeyframe = false;
        m_hardResetBeforeNextFrame = true;
        m_flushBeforeNextFrame = false;
        m_drainScheduled = false;
    }

    /// TCP/network catch-up discarded dependent frames up to an IDR that will
    /// arrive next — flush refs without destroying the codec.
    void armFlushBeforeNextFrame() {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_waitingForKeyframe) {
            // Remote-IDR wait already owns the next resume action.
            return;
        }
        m_flushBeforeNextFrame = true;
    }

    /// Network catch-up dropped the buffer and asked the sender for an IDR.
    /// Idempotent while already waiting — repeated TCP catch-up ticks must not
    /// re-arm flush thrash around every backlog probe.
    void waitForRemoteKeyframe() {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_pending.clear();
        m_drainScheduled = false;
        if (m_waitingForKeyframe) {
            return;
        }
        m_waitingForKeyframe = true;
        m_hardResetBeforeNextFrame = false;
        m_flushBeforeNextFrame = false;
    }

private:
    struct Entry {
        Packet packet;
        video_packet::Header header;
        VideoDecodeResumeAction resumeAction = VideoDecodeResumeAction::Continue;
    };

    bool backlogExceeded() const {
        if (m_pending.size() > m_maximumPendingFrames) {
            return true;
        }
        if (m_pending.size() < 2) {
            return false;
        }

        const auto& first = m_pending.front().header;
        const auto& newest = m_pending.back().header;
        if (first.streamId != newest.streamId
            || newest.presentationTimestampNanoseconds
                < first.presentationTimestampNanoseconds) {
            return true;
        }
        return newest.presentationTimestampNanoseconds
                - first.presentationTimestampNanoseconds
            > m_maximumBufferedDurationNanoseconds;
    }

    std::size_t findNewestUsableKeyframe() const {
        if (m_pending.size() < 2) {
            return m_pending.size();
        }

        const std::uint64_t newestStreamId =
            m_pending.back().header.streamId;
        for (std::size_t index = m_pending.size(); index-- > 1;) {
            const auto& header = m_pending[index].header;
            if (header.streamId == newestStreamId && header.isKeyframe) {
                return index;
            }
        }
        return m_pending.size();
    }

    bool markDrainScheduled() {
        if (m_drainScheduled) {
            return false;
        }
        m_drainScheduled = true;
        return true;
    }

    const std::uint64_t m_maximumBufferedDurationNanoseconds;
    const std::size_t m_maximumPendingFrames;
    mutable std::mutex m_mutex;
    std::deque<Entry> m_pending;
    bool m_drainScheduled = false;
    bool m_waitingForKeyframe = false;
    bool m_hardResetBeforeNextFrame = false;
    bool m_flushBeforeNextFrame = false;
};
