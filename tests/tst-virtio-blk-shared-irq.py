#!/usr/bin/env python3
"""Host-boundary regression: compile unchanged production IRQ setup/ack bodies.

Run from any directory: python3 tests/tst-virtio-blk-shared-irq.py
Optional CXX and CXXFLAGS (e.g. -fsanitize=address,undefined).
No OSv scheduler, interrupt controller, DMA or guest execution is modeled.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'drivers/virtio-blk.cc').read_text()


def between(text, start, end):
    assert text.count(start) == 1 and text.count(end) == 1
    return text.split(start, 1)[1].split(end, 1)[0]


ack = 'bool blk::ack_irq()' + between(source, 'bool blk::ack_irq()', 'blk::blk(')
setup = 'auto threads =' + between(source, 'auto threads =', '    // Step 8')
factory = 'struct interrupt_factory {' + between(
    (root / 'drivers/virtio-device.hh').read_text(),
    'struct interrupt_factory {', '// Defines virtio transport abstraction')
pci_register = 'void virtio_pci_device::register_interrupt' + between(
    (root / 'drivers/virtio-pci-device.cc').read_text(),
    'void virtio_pci_device::register_interrupt',
    'virtio_legacy_pci_device::virtio_legacy_pci_device')
mmio_register = 'void mmio_device::register_interrupt' + between(
    (root / 'drivers/virtio-mmio.cc').read_text(),
    'void mmio_device::register_interrupt', 'bool mmio_device::parse_config()')

boundary = r'''
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>
#define CONF_drivers_pci 1
#define CONF_drivers_mmio 1
#define virtio_e(...) std::fprintf(stderr, __VA_ARGS__)
namespace sched {
struct thread {
    unsigned wakes = 0;
    bool started = false;
    struct attr { attr& name(std::string) { return *this; } };
    static std::vector<std::unique_ptr<thread>> owned;
    static thread* make(std::function<void()>, attr) {
        owned.emplace_back(new thread);
        return owned.back().get();
    }
    void start() { started = true; }
    static void pin(thread* t, int) { assert(t && t->started); }
    void wake_with_irq_disabled() { assert(started); ++wakes; }
};
std::vector<std::unique_ptr<thread>> thread::owned;
std::vector<int> cpus;
}
struct queue {
    unsigned disables = 0;
    void set_use_indirect(bool) {}
    void disable_interrupts() { ++disables; }
};
namespace pci { struct device { bool msix = false; bool is_msix() { return msix; } }; }
namespace gic { enum irq_type { IRQ_TYPE_EDGE }; }
struct irq {
    std::function<bool()> ack;
    std::function<void()> handler;
    irq(std::function<bool()> a, std::function<void()> h): ack(a), handler(h) {}
    virtual ~irq() = default;
    void fire() { if (ack()) handler(); }
};
struct pci_interrupt : irq {
    pci_interrupt(pci::device&, std::function<bool()> a, std::function<void()> h): irq(a,h) {}
};
struct spi_interrupt : irq {
    spi_interrupt(gic::irq_type, unsigned, std::function<bool()> a, std::function<void()> h): irq(a,h) {}
};
struct gsi_edge_interrupt : irq {
    gsi_edge_interrupt(unsigned, std::function<void()> h): irq([] { return true; },h) {}
};
struct msix_binding { unsigned entry; std::function<void()> handler; sched::thread* thread; };
struct interrupt_manager {
    std::vector<msix_binding> bindings;
    bool easy_register(const std::vector<msix_binding>& b) { bindings = b; return true; }
};
'''
fixture = r'''
struct virtio_device {
    unsigned status = 0, reads = 0;
    virtual ~virtio_device() = default;
    virtual void register_interrupt(interrupt_factory) = 0;
    unsigned read_and_ack_isr() { ++reads; return std::exchange(status, 0); }
    unsigned get_irq() { return 17; }
};
struct virtio_pci_device : virtio_device {
    pci::device pci_dev;
    pci::device* _dev = &pci_dev;
    interrupt_manager _msi;
    std::unique_ptr<pci_interrupt> _irq;
    void register_interrupt(interrupt_factory) override;
};
struct mmio_device : virtio_device {
#ifdef __aarch64__
    std::unique_ptr<spi_interrupt> _irq;
#else
    std::unique_ptr<gsi_edge_interrupt> _irq;
#endif
    void register_interrupt(interrupt_factory) override;
};
struct blk {
    virtio_device& _dev;
    int _num_queues;
    std::vector<queue> queues;
    blk(virtio_device& dev, int n): _dev(dev), _num_queues(n), queues(n) {}
    queue* get_virt_queue(int n) { return &queues.at(n); }
    void req_done(int) {}
    bool ack_irq();
    void setup();
};
'''
checks = r'''
static unsigned failures = 0;
static void check(bool ok, const char* label, int n, int q) {
    if (!ok) {
        std::printf("FAIL %s queues=%d q=%d\n", label, n, q);
        ++failures;
    }
}
// Invoke at registration time too: every thread must already be initialized
// and started, even before DRIVER_OK. Initial status zero must wake nobody.
struct early_pci : virtio_pci_device {
    void register_interrupt(interrupt_factory f) override {
        virtio_pci_device::register_interrupt(f);
        if (_irq) _irq->fire();
    }
};
struct early_mmio : mmio_device {
    void register_interrupt(interrupt_factory f) override {
        mmio_device::register_interrupt(f);
        _irq->fire();
    }
};
template<class Device> static void shared(const char* label, int n, unsigned initial) {
    sched::thread::owned.clear();
    sched::cpus.resize(n);
    Device dev;
    dev.status = initial;
    blk driver(dev, n);
    driver.setup();
    // Constructor-local threads vector/factory are now dead. Callbacks must
    // own their captures, not borrow their storage.
    for (int q = 0; q < n; ++q) {
        check(sched::thread::owned[q]->wakes == initial, "registration init/spurious", n, q);
    }
    check(dev.reads == 1, "registration ack", n, 0);
    for (unsigned status : {1u, 2u, 3u}) {
        // Status here is the transport's returned value, not raw MMIO bits.
        // PCI accepts any nonzero ISR; MMIO filters config-only beforehand.
        dev.status = status;
        dev._irq->fire();
        check(dev.status == 0, "ack clears status", n, 0);
        for (int q = 0; q < n; ++q) {
            check(sched::thread::owned[q]->wakes == initial + status, label, n, q);
        }
        std::vector<unsigned> before;
        for (auto& t : sched::thread::owned) before.push_back(t->wakes);
        dev._irq->fire();
        for (int q = 0; q < n; ++q) {
            check(sched::thread::owned[q]->wakes == before[q], "spurious", n, q);
        }
    }
    check(dev.reads == 7, "one ack per IRQ", n, 0);
}
static void msix(int n) {
    sched::thread::owned.clear();
    sched::cpus.resize(n);
    early_pci dev;
    dev.pci_dev.msix = true;
    blk driver(dev, n);
    driver.setup();
    check(!dev._irq && dev._msi.bindings.size() == unsigned(n), "MSI-X registration", n, 0);
    for (int target = 0; target < n; ++target) {
        for (auto& t : sched::thread::owned) t->wakes = 0;
        auto& b = dev._msi.bindings[target];
        check(b.entry == unsigned(target), "MSI-X entry", n, target);
        b.handler();
        b.thread->wake_with_irq_disabled();
        for (int q = 0; q < n; ++q) {
            check(sched::thread::owned[q]->wakes == unsigned(q == target), "MSI-X only target", n, q);
            check(driver.queues[q].disables == unsigned(q <= target), "MSI-X mask only target", n, q);
        }
    }
    check(dev.reads == 0, "MSI-X no shared ack", n, 0);
}
int main() {
    for (int n : {1, 2, 4, 64}) {
        for (unsigned initial : {0u, 1u}) {
            shared<early_pci>("PCI INTx wake all", n, initial);
            shared<early_mmio>("MMIO wake all", n, initial);
        }
        msix(n);
    }
    if (failures) return 1;
    std::puts("PASS shared IRQ queues=1,2,4,64; init/spurious; post-scope lifetime; dedicated MSI-X");
}
'''
with tempfile.TemporaryDirectory(prefix='virtio-shared-irq-') as tmp:
    cpp = Path(tmp) / 'test.cc'
    cpp.write_text(boundary + factory + fixture + pci_register + mmio_register
                   + ack + '\nvoid blk::setup() {\n' + setup + '\n}\n' + checks)
    failed = False
    for arch in ('x64', 'aarch64'):
        exe = Path(tmp) / arch
        cmd = shlex.split(os.environ.get('CXX', 'g++')) + [
            '-std=c++17', '-O1', '-g', '-Wall', '-Wextra', '-Werror']
        cmd += shlex.split(os.environ.get('CXXFLAGS', ''))
        if arch == 'aarch64':
            cmd += ['-D__aarch64__']  # Select ARM callback, still a host binary.
        cmd += [str(cpp), '-o', str(exe)]
        print('BUILD', arch, shlex.join(cmd), flush=True)
        subprocess.run(cmd, check=True)
        result = subprocess.run([str(exe)], check=False)
        print('RESULT', arch, result.returncode, flush=True)
        failed |= result.returncode != 0
    raise SystemExit(int(failed))
