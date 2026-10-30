// SPDX-License-Identifier: AGPL-3.0-or-later
#include "protected_mapping.h"
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <memory>
#include <system_error>
#include <thread>
using caboose::coherent::ProtectedMapping;
int main() {
    std::unique_ptr<ProtectedMapping> mapping;
    try { mapping = std::make_unique<ProtectedMapping>(4096); }
    catch (const std::system_error& e) {
        if (e.code().value() == EPERM || e.code().value() == EACCES ||
            e.code().value() == ENOSYS || e.code().value() == EINVAL) {
            std::printf("UNSUPPORTED: %s\n", e.what()); return 77;
        }
        throw;
    }
    auto* bytes = static_cast<unsigned char*>(mapping->data());
    bytes[0] = 17;
    std::atomic<bool> entered{false};
    std::thread writer;
    bool stable = true;
    {
        ProtectedMapping::Frozen frozen(*mapping);
        writer = std::thread([&] { entered.store(true); bytes[0] = 23; });
        while (!entered.load()) std::this_thread::yield();
        // This is a read-only snapshot cut. Writing through data() here would
        // fault and deadlock the cut owner as surely as an application writer.
        for (unsigned i=0;i<100000;++i)
            if (*static_cast<volatile unsigned char*>(mapping->data()) != 17) stable = false;
    }
    writer.join();
    if (!stable || mapping->lost() || bytes[0] != 23) return 1;
    std::puts("protected ordinary CPU store cut: PASS");
}
