// SPDX-License-Identifier: MIT
// test_shader_cache VECTORS_JSON: the guest's shader cache decisions and wire forms, hashed
// with Mesa's BLAKE3, against the vectors the phone's store is tested with.
#include "shader_cache.h"

extern "C" {
#include "blake3.h"
}

#include <cassert>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using namespace caboose::shader_cache;

namespace {

std::string vectorHex(const std::string& json, const char* name) {
    const std::string marker = std::string("\"") + name + "\": \"";
    const size_t start = json.find(marker);
    assert(start != std::string::npos);
    const size_t from = start + marker.size();
    return json.substr(from, json.find('"', from) - from);
}

std::vector<uint8_t> fromHex(const std::string& hex) {
    std::vector<uint8_t> out(hex.size() / 2);
    for (size_t i = 0; i < out.size(); ++i) out[i] = uint8_t(std::stoi(hex.substr(2 * i, 2), nullptr, 16));
    return out;
}

std::vector<uint8_t> pattern(size_t length) {
    std::vector<uint8_t> bytes(length);
    for (size_t i = 0; i < length; ++i) bytes[i] = uint8_t(i % 251);
    return bytes;
}

void blake3(const void* data, size_t size, Key* key) {
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, data, size);
    blake3_hasher_finalize(&hasher, key->data(), key->size());
}

Key keyOf(const std::vector<uint8_t>& bytes) {
    Key key;
    blake3(bytes.data(), bytes.size(), &key);
    return key;
}

std::vector<uint8_t> concat(std::initializer_list<Key> keys) {
    std::vector<uint8_t> out;
    for (const Key& key : keys) out.insert(out.end(), key.begin(), key.end());
    return out;
}

}  // namespace

int main(int argc, char** argv) {
    assert(argc == 2);
    std::ifstream file(argv[1]);
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string json = buffer.str();
    assert(!json.empty());

    // The same keys as the phone's store.
    for (auto [name, length] : {std::pair{"blake3_0", 0}, {"blake3_1024", 1024}, {"blake3_8192", 8192}}) {
        const Key key = keyOf(pattern(length));
        assert(std::vector<uint8_t>(key.begin(), key.end()) == fromHex(vectorHex(json, name)));
    }
    const auto m1024 = pattern(1024), m8192 = pattern(8192), small = pattern(252);
    const Key k1024 = keyOf(m1024), k8192 = keyOf(m8192);

    // Wire forms.
    uint8_t packet[kInventoryPacketBytes];
    encodeInventoryRequest(packet);
    assert(std::vector<uint8_t>(packet, packet + sizeof(packet)) == fromHex(vectorHex(json, "inventory_packet")));
    const auto reply = fromHex(vectorHex(json, "inventory_reply_1024_8192"));
    assert(inventoryCount(reply.data()) == 2);
    assert(std::vector<uint8_t>(reply.begin() + 8, reply.end()) == concat({k1024, k8192}));
    assert(inventoryCount(fromHex(vectorHex(json, "inventory_reply_empty")).data()) == 0);
    uint8_t head[8] = {};
    putLe32(head, kInventoryMaxKeys + 1);
    assert(inventoryCount(head) == -1);
    putLe32(head, 1); putLe32(head + 4, 1);
    assert(inventoryCount(head) == -1);
    uint8_t token[kTokenBytes];
    encodeToken(token, k1024, 1024);
    assert(std::vector<uint8_t>(token, token + sizeof(token)) == fromHex(vectorHex(json, "token_1024")));

    // Decisions.
    int loads = 0;
    std::vector<uint8_t> inventory = concat({k1024});
    auto load = [&](std::vector<uint8_t>* keys) { ++loads; *keys = inventory; return true; };
    {
        Known known;
        // Too small, or not whole words: always code, and the phone is not asked.
        assert(!substitute(known, small.data(), small.size(), true, blake3, load, token));
        assert(!substitute(known, m1024.data(), 1022, true, blake3, load, token));
        assert(loads == 0);
        // A module the phone holds becomes its token; the inventory is asked for once.
        assert(substitute(known, m1024.data(), m1024.size(), true, blake3, load, token));
        assert(std::vector<uint8_t>(token, token + sizeof(token)) == fromHex(vectorHex(json, "token_1024")));
        // One it does not hold is sent, then named by token on one stream.
        assert(!substitute(known, m8192.data(), m8192.size(), true, blake3, load, token));
        assert(substitute(known, m8192.data(), m8192.size(), true, blake3, load, token));
        assert(loads == 1 && known.size() == 2);
        // A new executor (perhaps another phone) is asked again.
        known.reset();
        inventory.clear();
        assert(!substitute(known, m1024.data(), m1024.size(), true, blake3, load, token));
        assert(loads == 2);
    }
    {
        // With more than one device stream, only what the inventory listed is named.
        Known known;
        inventory = concat({k1024});
        assert(!substitute(known, m8192.data(), m8192.size(), false, blake3, load, token));
        assert(!substitute(known, m8192.data(), m8192.size(), false, blake3, load, token));
        assert(substitute(known, m1024.data(), m1024.size(), false, blake3, load, token));
    }
    {
        // A phone that cannot answer leaves the process sending code, without asking again.
        Known known;
        int failed = 0;
        auto refuse = [&](std::vector<uint8_t>*) { ++failed; return false; };
        assert(!substitute(known, m1024.data(), m1024.size(), true, blake3, refuse, token));
        assert(!substitute(known, m1024.data(), m1024.size(), true, blake3, refuse, token));
        assert(failed == 1);
        // A malformed inventory counts as no answer.
        Known ragged;
        auto partial = [&](std::vector<uint8_t>* keys) { keys->assign(31, 0); return true; };
        assert(ragged.ensure(partial) == Known::State::unavailable);
        // An executor change during the request discards its answer.
        Known racing;
        auto changing = [&](std::vector<uint8_t>* keys) { *keys = concat({k1024}); racing.reset(); return true; };
        assert(racing.ensure(changing) == Known::State::unknown);
        assert(!racing.contains(k1024));
    }
    std::puts("test_shader_cache: ok");
    return 0;
}
