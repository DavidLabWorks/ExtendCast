#include "../VideoDecodeQueue.h"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

video_packet::Header header(
    std::uint64_t sequence,
    std::uint64_t milliseconds,
    bool isKeyframe = false
) {
    return video_packet::Header{
        7,
        sequence,
        milliseconds * 1'000'000,
        isKeyframe,
    };
}

} // namespace

int main() {
    {
        VideoDecodeQueue<int> queue(500'000'000, 100);
        bool requestedKeyframe = false;
        for (std::uint64_t sequence = 0; sequence <= 30; ++sequence) {
            const auto result = queue.enqueue(
                static_cast<int>(sequence),
                header(sequence, sequence * 20, sequence == 0 || sequence == 20)
            );
            requestedKeyframe = requestedKeyframe || result.requestKeyframe;
        }

        const auto next = queue.takeNext();
        assert(next.has_value());
        assert(next->packet == 20);
        assert(next->resumeAction == VideoDecodeResumeAction::Flush);
        assert(!requestedKeyframe);
    }

    {
        VideoDecodeQueue<int> queue(200'000'000, 100);
        int keyframeRequests = 0;
        for (std::uint64_t sequence = 0; sequence <= 20; ++sequence) {
            const auto result = queue.enqueue(
                static_cast<int>(sequence),
                header(sequence, sequence * 20, sequence == 0)
            );
            if (result.requestKeyframe) {
                keyframeRequests++;
            }
        }

        assert(keyframeRequests == 1);
        assert(!queue.takeNext().has_value());

        const auto ignored = queue.enqueue(21, header(21, 420));
        assert(!ignored.scheduleDrain);
        assert(!ignored.requestKeyframe);

        const auto recovered = queue.enqueue(22, header(22, 440, true));
        assert(recovered.scheduleDrain);
        assert(!recovered.requestKeyframe);
        const auto next = queue.takeNext();
        assert(next.has_value());
        assert(next->packet == 22);
        assert(next->resumeAction == VideoDecodeResumeAction::Flush);
    }

    {
        VideoDecodeQueue<int> queue(500'000'000, 100);
        assert(queue.waitForKeyframeAfterDecodeError());
        assert(!queue.waitForKeyframeAfterDecodeError());

        const auto ignored = queue.enqueue(1, header(1, 20));
        assert(!ignored.scheduleDrain);
        const auto recovered = queue.enqueue(2, header(2, 40, true));
        assert(recovered.scheduleDrain);
        const auto next = queue.takeNext();
        assert(next.has_value());
        assert(next->resumeAction == VideoDecodeResumeAction::HardReset);
    }

    {
        VideoDecodeQueue<int> queue(500'000'000, 100);
        const auto first = queue.enqueue(1, header(1, 20, true));
        const auto second = queue.enqueue(2, header(2, 40));
        assert(first.scheduleDrain);
        assert(!second.scheduleDrain);
        assert(queue.takeNext().has_value());
        assert(queue.takeNext().has_value());
        assert(!queue.takeNext().has_value());

        queue.clearForStreamReset();
        const auto afterReset = queue.enqueue(3, header(3, 60, true));
        assert(afterReset.scheduleDrain);
        const auto resetItem = queue.takeNext();
        assert(resetItem.has_value());
        assert(resetItem->resumeAction == VideoDecodeResumeAction::HardReset);
    }

    {
        // clearForStreamReset must clear drainScheduled so the next enqueue
        // can schedule a drain even if a prior drain flag was left set.
        VideoDecodeQueue<int> queue(500'000'000, 100);
        assert(queue.enqueue(1, header(1, 0, true)).scheduleDrain);
        assert(queue.takeNext().has_value());
        queue.clearForStreamReset();
        const auto after = queue.enqueue(2, header(2, 20, true));
        assert(after.scheduleDrain);
        assert(queue.takeNext().has_value());
    }

    std::cout << "Video decode queue tests passed\n";
}
