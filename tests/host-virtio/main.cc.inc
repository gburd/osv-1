int main() {
    // Both producer and consumer are production methods, as is the ring.
    // One FLUSH consumes both direct descriptors. The second submission
    // waits holding its production mutex before we expose a completion.
    alarm(5);
    virtio::virtio_driver driver;
    virtio::vring ring(&driver, 2, 0);
    virtio::blk blk;
    blk.ring = &ring;
    bio first, second;
    assert(blk.make_request(&first) == 0);
    auto* avail = reinterpret_cast<virtio::vring_avail*>(ring.get_avail_addr());
    auto* used = reinterpret_cast<virtio::vring_used*>(ring.get_used_addr());
    std::thread producer([&] { assert(blk.make_request(&second) == 0); });
    while (!sched::producer_waiting.load()) std::this_thread::yield();
    used->_used_elements[0] = {avail->_ring[0], 1};
    used->_idx.store(1, std::memory_order_release);
    std::thread consumer([&] {
        sched::consumer = true;
        try { blk.req_done(0); } catch (sched::finished&) {}
    });
    producer.join();
    consumer.join();
    assert(first.done);
    used->_used_elements[1] = {avail->_ring[1], 1};
    used->_idx.store(2, std::memory_order_release);
    sched::waits = 0;
    std::thread consumer2([&] {
        sched::consumer = true;
        try { blk.req_done(0); } catch (sched::finished&) {}
    });
    consumer2.join();
    ring.get_buf_gc();
    assert(second.done);
    assert(ring.effective_avail_ring_count() == 2);
    std::cout << "PASS: tiny full ring make_request and fallback consumer; all reclaimed\n";
}
