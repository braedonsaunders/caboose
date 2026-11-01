// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// shader_store_test VECTORS_JSON: the phone's persistent SPIR-V store and its wire forms,
// against guest/gpu/gfxstream/shader-cache/vectors.json.
#undef NDEBUG
#include "shader_store.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

using namespace caboose::gpuv2;

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
    for (size_t i = 0; i < out.size(); ++i) out[i] = static_cast<uint8_t>(std::stoi(hex.substr(2 * i, 2), nullptr, 16));
    return out;
}

std::vector<uint8_t> pattern(size_t length) {
    std::vector<uint8_t> bytes(length);
    for (size_t i = 0; i < length; ++i) bytes[i] = static_cast<uint8_t>(i % 251);
    return bytes;
}

// A module-shaped word sequence: SPIR-V magic, then distinct words.
std::vector<uint32_t> module(uint32_t seed, size_t words) {
    std::vector<uint32_t> code(words);
    code[0] = 0x07230203;
    for (size_t i = 1; i < words; ++i) code[i] = seed * 2654435761u + static_cast<uint32_t>(i);
    return code;
}

size_t fileCount(const std::string& dir) {
    std::string command = "ls -A '" + dir + "' | wc -l";
    FILE* p = popen(command.c_str(), "r");
    size_t n = 0;
    assert(p && fscanf(p, "%zu", &n) == 1);
    pclose(p);
    return n;
}

}  // namespace

int main(int argc, char** argv) {
    assert(argc == 2);
    std::ifstream file(argv[1]);
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string json = buffer.str();
    assert(!json.empty());

    // Keys are BLAKE3-256, exactly as the guest's Mesa computes them.
    for (auto [name, length] : {std::pair{"blake3_0", 0}, {"blake3_1024", 1024}, {"blake3_8192", 8192}}) {
        const auto input = pattern(length);
        assert(shaderKeyHex(shaderKeyOf(input.data(), input.size())) == vectorHex(json, name));
    }
    const auto in1024 = pattern(1024), in8192 = pattern(8192);
    const ShaderKey k1024 = shaderKeyOf(in1024.data(), in1024.size());
    const ShaderKey k8192 = shaderKeyOf(in8192.data(), in8192.size());
    ShaderKey parsedKey;
    assert(shaderKeyFromHex(vectorHex(json, "blake3_1024").c_str(), 64, &parsedKey) && parsedKey == k1024);
    assert(!shaderKeyFromHex("zz", 2, &parsedKey));

    // Token.
    uint8_t token[kShaderTokenBytes];
    writeShaderToken(token, k1024, 1024);
    assert(fromHex(vectorHex(json, "token_1024")) == std::vector<uint8_t>(token, token + sizeof(token)));
    uint32_t realSize = 0;
    assert(parseShaderToken(token, sizeof(token), &parsedKey, &realSize) && parsedKey == k1024 && realSize == 1024);
    assert(!parseShaderToken(token, sizeof(token) - 4, nullptr, nullptr));
    uint8_t bad[kShaderTokenBytes];
    std::memcpy(bad, token, sizeof(bad)); bad[0] ^= 1;
    assert(!parseShaderToken(bad, sizeof(bad), nullptr, nullptr));     // magic
    std::memcpy(bad, token, sizeof(bad)); bad[4] = 2;
    assert(!parseShaderToken(bad, sizeof(bad), nullptr, nullptr));     // version
    std::memcpy(bad, token, sizeof(bad)); bad[12] = 1;
    assert(!parseShaderToken(bad, sizeof(bad), nullptr, nullptr));     // reserved
    writeShaderToken(bad, k1024, 100);
    assert(!parseShaderToken(bad, sizeof(bad), nullptr, nullptr));     // below the minimum
    writeShaderToken(bad, k1024, 1026);
    assert(!parseShaderToken(bad, sizeof(bad), nullptr, nullptr));     // not whole words
    const auto spirv = module(1, 12);
    assert(!parseShaderToken(spirv.data(), kShaderTokenBytes, nullptr, nullptr));  // real SPIR-V

    // Inventory packet and reply.
    const auto packet = fromHex(vectorHex(json, "inventory_packet"));
    assert(parseShaderInventoryPacket(packet.data(), packet.size()));
    auto badPacket = packet; badPacket[8] = 2;
    assert(!parseShaderInventoryPacket(badPacket.data(), badPacket.size()));
    assert(!parseShaderInventoryPacket(packet.data(), packet.size() - 1));
    assert(encodeShaderInventoryReply({}) == fromHex(vectorHex(json, "inventory_reply_empty")));
    assert(encodeShaderInventoryReply({k1024, k8192}) == fromHex(vectorHex(json, "inventory_reply_1024_8192")));

    // The store.
    char templ[] = "/tmp/caboose-shader-store-XXXXXX";
    assert(mkdtemp(templ));
    const std::string root = templ;
    const std::string dir = root + "/realm/shaders";
    {
        auto store = ShaderStore::open(dir);
        assert(store && store->inventory().empty());
        const auto a = module(1, 1024), b = module(2, 2048), tiny = module(3, 16);
        store->insert(a.data(), a.size() * 4);
        store->insert(a.data(), a.size() * 4);      // held already
        store->insert(b.data(), b.size() * 4);
        store->insert(tiny.data(), tiny.size() * 4);  // too small to cache
        assert(store->inventory().size() == 2);
        std::vector<uint32_t> out;
        assert(store->resolve(shaderKeyOf(a.data(), a.size() * 4), a.size() * 4, &out) && out == a);
        assert(!store->resolve(shaderKeyOf(a.data(), a.size() * 4), b.size() * 4, &out));  // wrong size
        assert(!store->resolve(shaderKeyOf(tiny.data(), tiny.size() * 4), tiny.size() * 4, &out));
        const auto s = store->stats();
        assert(s.entries == 2 && s.inserted == 2 && s.insertSkipped == 1 && s.resolved == 1 && s.unresolved == 2);
        assert(fileCount(dir) == 2);
    }
    {
        // Reopened: the entries persist; an interrupted write and a stray file are removed.
        std::ofstream(dir + "/.tmp-1-1") << "partial";
        std::ofstream(dir + "/" + std::string(64, 'a') + ".spv") << "short";
        auto store = ShaderStore::open(dir);
        assert(store->inventory().size() == 2 && fileCount(dir) == 2);
        // A damaged file fails verification and leaves the inventory.
        const auto a = module(1, 1024);
        const ShaderKey ka = shaderKeyOf(a.data(), a.size() * 4);
        {
            std::fstream f(dir + "/" + shaderKeyHex(ka) + ".spv", std::ios::in | std::ios::out | std::ios::binary);
            f.seekp(100); f.put('x');
        }
        std::vector<uint32_t> out;
        assert(!store->resolve(ka, a.size() * 4, &out));
        assert(store->inventory().size() == 1 && fileCount(dir) == 1);
    }
    {
        // The budget applies at open, keeping the most recently used.
        auto store = ShaderStore::open(dir);
        for (uint32_t seed = 10; seed < 14; ++seed) {
            const auto m = module(seed, 1024);
            store->insert(m.data(), m.size() * 4);
            usleep(10000);
        }
        std::vector<uint32_t> out;
        const auto oldest = module(10, 1024);
        assert(store->resolve(shaderKeyOf(oldest.data(), 4096), 4096, &out));  // now the most recent
        assert(store->inventory().size() == 5);
        auto limited = ShaderStore::open(dir, ShaderStoreLimits{3 * 4096 + 100, 100});
        assert(limited->inventory().size() == 3 && limited->stats().evictedAtOpen == 2);
        assert(limited->resolve(shaderKeyOf(oldest.data(), 4096), 4096, &out));
        auto counted = ShaderStore::open(dir, ShaderStoreLimits{1ull << 30, 2});
        assert(counted->inventory().size() == 2);
    }
    {
        // The decoder hooks, through the process-wide store of the current root.
        assert(setShaderStoreRoot("relative") != 0);
        assert(setShaderStoreRoot((root + "/other").c_str()) == 0);
        const auto m = module(20, 512);
        const ShaderKey key = shaderKeyOf(m.data(), m.size() * 4);
        writeShaderToken(token, key, static_cast<uint32_t>(m.size() * 4));
        std::vector<uint32_t> out;
        assert(resolveShaderCode(m.data(), m.size() * 4, &out) == ShaderCodeSource::literal);
        assert(resolveShaderCode(token, sizeof(token), &out) == ShaderCodeSource::unresolved);
        rememberShaderCode(m.data(), m.size() * 4);
        assert(resolveShaderCode(token, sizeof(token), &out) == ShaderCodeSource::resolved && out == m);
        // A different computer's root does not see it.
        assert(setShaderStoreRoot((root + "/third").c_str()) == 0);
        assert(resolveShaderCode(token, sizeof(token), &out) == ShaderCodeSource::unresolved);
        assert(currentShaderStore()->inventory().empty());
    }
    std::system(("rm -rf '" + root + "'").c_str());
    std::puts("shader_store_test: ok");
    return 0;
}
