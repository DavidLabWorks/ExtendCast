#include "../LatestValueMailbox.h"

#include <cassert>
#include <iostream>

int main() {
    LatestValueMailbox<int> mailbox;

    for (int produced = 1; produced <= 600; ++produced) {
        mailbox.replace(produced);
        assert(mailbox.pendingCount() == 1);

        // Simulate a renderer that can only consume 45 of every 60 frames.
        if (produced % 4 != 0) {
            const auto displayed = mailbox.take();
            assert(displayed.has_value());
            assert(*displayed == produced);
        }
    }

    const auto latest = mailbox.take();
    assert(latest.has_value());
    assert(*latest == 600);
    assert(mailbox.pendingCount() == 0);

    std::cout << "LatestValueMailbox tests passed\n";
    return 0;
}
