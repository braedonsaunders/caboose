// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Explicitly invoked private diagnostic; this is not a product GPU driver.
#import <UIKit/UIKit.h>
#import <Network/Network.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <dispatch/dispatch.h>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <cstdio>
#include <dlfcn.h>
#include <sys/socket.h>
#include <unistd.h>
#include "device_fixture.h"
#include "graceful_close.h"

namespace {
NSData* parseHex(NSString* value, NSUInteger length) {
    if (![value isKindOfClass:NSString.class] || value.length != length * 2) return nil;
    NSMutableData* data = [NSMutableData dataWithLength:length];
    auto* out = static_cast<uint8_t*>(data.mutableBytes);
    for (NSUInteger i = 0; i < length; ++i) {
        unsigned v = 0;
        for (NSUInteger j = 0; j < 2; ++j) {
            unichar c = [value characterAtIndex:2 * i + j];
            unsigned n = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : 255;
            if (n > 15) return nil;
            v = v * 16 + n;
        }
        out[i] = static_cast<uint8_t>(v);
    }
    return data;
}
bool parseNumber(NSString* value, uint64_t* result) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return false;
    uint64_t n = 0;
    for (NSUInteger i = 0; i < value.length; ++i) {
        unichar c = [value characterAtIndex:i];
        if (c < '0' || c > '9' || n > (UINT64_MAX - (c - '0')) / 10) return false;
        n = n * 10 + (c - '0');
    }
    *result = n;
    return n != 0;
}
struct StartGroupGuard {
    dispatch_group_t group;
    ~StartGroupGuard() { dispatch_group_leave(group); }
};
void* resolveVulkan(const char* name) { return dlsym(RTLD_DEFAULT, name); }
bool certMatches(sec_trust_t trust, NSData* pin) {
    SecTrustRef ref = sec_trust_copy_ref(trust);
    if (!ref) return false;
    CFArrayRef chain = SecTrustCopyCertificateChain(ref);
    CFRelease(ref);
    if (!chain || CFArrayGetCount(chain) == 0) { if (chain) CFRelease(chain); return false; }
    SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
    CFDataRef der = SecCertificateCopyData(cert);
    CFRelease(chain);
    if (!der) return false;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), digest);
    CFRelease(der);
    const auto* expected = static_cast<const uint8_t*>(pin.bytes);
    unsigned diff = 0;
    for (size_t i = 0; i < sizeof(digest); ++i) diff |= digest[i] ^ expected[i];
    return diff == 0;
}
}

@interface DiagnosticRunner : NSObject
- (instancetype)initWithReport:(void (^)(NSString*))report;
- (void)start;
- (void)stop;
@end

@implementation DiagnosticRunner {
    void (^_report)(NSString*);
    nw_connection_t _connection;
    dispatch_queue_t _networkQueue;
    dispatch_group_t _workers;
    caboose_gpu_diagnostic* _diagnostic;
    int _decoderFd;
    int _bridgeFd;
    std::atomic_bool _stopping;
    std::atomic_bool _started;
    std::atomic_bool _authStarted;
    std::atomic_bool _finishing;
    std::atomic_int _decoderResult;
    std::recursive_mutex _stateMutex;
    std::mutex _closeMutex;
    caboose::gpuv2::diagnostic::GracefulClose _closeState;
    NSData* _session;
    NSData* _token;
    NSData* _pin;
    uint64_t _generation;
    uint64_t _process;
}
- (instancetype)initWithReport:(void (^)(NSString*))report {
    if ((self = [super init])) {
        _report = [report copy];
        _networkQueue = dispatch_queue_create("org.caboose.gpu-diagnostic.network", DISPATCH_QUEUE_SERIAL);
        _workers = dispatch_group_create();
        // The explicit start is queued immediately after construction. Keep
        // cleanup fenced even if Stop is pressed before that work begins.
        dispatch_group_enter(_workers);
        _decoderFd = _bridgeFd = -1;
        _stopping = false; _started = false; _authStarted = false; _finishing = false; _decoderResult = 0;
    }
    return self;
}
- (void)report:(NSString*)text {
    // Report only static messages, numeric errors, session and executor identity.
    // Never pass endpoint, token, certificate bytes or stream contents here.
    std::fprintf(stderr, "GPU diagnostic: %s\n", text.UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{ self->_report(text); });
}
- (void)abort:(NSString*)reason {
    if (_stopping.exchange(true)) return;
    {
        std::lock_guard<std::mutex> lock(_closeMutex);
        _closeState.cancel();
    }
    [self report:reason];
    std::lock_guard<std::recursive_mutex> stateLock(_stateMutex);
    if (_connection) nw_connection_cancel(_connection);
    if (_bridgeFd >= 0) shutdown(_bridgeFd, SHUT_RDWR);
    if (_decoderFd >= 0) shutdown(_decoderFd, SHUT_RDWR);
    if (_diagnostic) {
        int error = caboose_gpu_diagnostic_stop(_diagnostic);
        if (error) [self report:[NSString stringWithFormat:@"Stop failed: %d", error]];
    }
    if (_finishing.exchange(true)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Do not close/reuse descriptors until every running bridge/decoder task exits.
        dispatch_group_wait(self->_workers, DISPATCH_TIME_FOREVER);
        if (self->_connection) {
            nw_connection_set_state_changed_handler(self->_connection, nullptr);
            self->_connection = nullptr;
        }
        if (self->_decoderFd >= 0) { close(self->_decoderFd); self->_decoderFd = -1; }
        if (self->_bridgeFd >= 0) { close(self->_bridgeFd); self->_bridgeFd = -1; }
        if (self->_diagnostic) {
            int error = caboose_gpu_diagnostic_finish(self->_diagnostic);
            if (error) [self report:[NSString stringWithFormat:@"Cleanup failed: %d", error]];
            else { self->_diagnostic = nullptr; [self report:@"Decoder cleanup completed. Verify the guest oracle separately."]; }
        }
    });
}
- (void)noteInputEof {
    {
        std::lock_guard<std::mutex> lock(_closeMutex);
        _closeState.inputEof();
    }
    if (!_stopping.load()) shutdown(_bridgeFd, SHUT_WR);
}
- (void)sendFinalAfterOutputDrained {
    using caboose::gpuv2::diagnostic::CloseAction;
    {
        std::lock_guard<std::mutex> lock(_closeMutex);
        if (_closeState.outputEof() != CloseAction::send_final) return;
    }
    if (_stopping.load()) return;
    dispatch_group_enter(_workers);
    nw_connection_send(_connection, nullptr, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        CloseAction action;
        {
            std::lock_guard<std::mutex> lock(self->_closeMutex);
            action = self->_closeState.finalSendComplete(error != nil);
        }
        if (action == CloseAction::fail) [self abort:@"TLS final send failed."];
        else if (!self->_stopping.load())
            [self report:@"Decoder output drained; TLS final send queued. Check the guest oracle; this is not delivery confirmation."];
        dispatch_group_leave(self->_workers);
    });
}
- (void)stop { [self abort:@"Diagnostic stopped by operator; check guest oracle and teardown independently."]; }
- (void)receiveFromBroker {
    if (_stopping.load()) return;
    dispatch_group_enter(_workers);
    nw_connection_receive(_connection, 1, 16384, ^(dispatch_data_t data, nw_content_context_t context, bool complete, nw_error_t error) {
        (void)context;
        const bool hadError = error != nil;
        const int errorCode = error ? nw_error_get_error_code(error) : 0;
        const bool hasData = data && dispatch_data_get_size(data) != 0;
        if (!hasData) {
            if (error) [self abort:[NSString stringWithFormat:@"TLS receive failed: %d", errorCode]];
            else if (complete) [self noteInputEof];
            else [self abort:@"TLS receive returned no data without EOF."];
            dispatch_group_leave(self->_workers); return;
        }
        // Network.framework can deliver bytes with EOF or an error. Write all
        // bytes before acting on the terminal indication.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __block int sendError = 0;
            dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void* bytes, size_t size) {
                (void)region; (void)offset;
                const auto* p = static_cast<const uint8_t*>(bytes);
                while (size && !self->_stopping.load()) {
                    ssize_t n = send(self->_bridgeFd, p, size, 0);
                    if (n < 0 && errno == EINTR) continue;
                    if (n <= 0) { sendError = n == 0 ? EPIPE : errno; return false; }
                    p += n; size -= static_cast<size_t>(n);
                }
                return !self->_stopping.load();
            });
            if (sendError) [self abort:[NSString stringWithFormat:@"Decoder input failed: %d", sendError]];
            else if (hadError) {
                [self report:[NSString stringWithFormat:@"TLS receive failed after data: %d", errorCode]];
                [self noteInputEof];
            } else if (complete) [self noteInputEof];
            else if (!self->_stopping.load()) [self receiveFromBroker];
            dispatch_group_leave(self->_workers);
        });
    });
}
- (void)beginBridge {
    std::lock_guard<std::recursive_mutex> stateLock(_stateMutex);
    if (_stopping.load()) return;
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) { [self abort:@"Could not create local decoder stream."]; return; }
    _decoderFd = sockets[0]; _bridgeFd = sockets[1];
    int yes = 1;
    if (setsockopt(_bridgeFd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) != 0) { [self abort:@"Could not configure local decoder stream."]; return; }
    // Register both workers before either can finish and initiate cleanup.
    dispatch_group_enter(_workers);
    dispatch_group_enter(_workers);
    [self receiveFromBroker];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = caboose_gpu_diagnostic_run(self->_diagnostic, self->_decoderFd, 10000);
        self->_decoderResult.store(result);
        // Preserve any decoder replies already queued to the bridge before
        // teardown; the output worker reports EOF after forwarding them.
        shutdown(self->_decoderFd, SHUT_WR);
        if (result && result != ECONNRESET && result != ECANCELED)
            [self abort:[NSString stringWithFormat:@"Decoder stream failed: %d", result]];
        dispatch_group_leave(self->_workers);
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint8_t buffer[16384];
        while (!self->_stopping.load()) {
            ssize_t n = recv(self->_bridgeFd, buffer, sizeof(buffer), 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) {
                if (n < 0 && !self->_stopping.load())
                    [self abort:[NSString stringWithFormat:@"Decoder output receive failed: %d", errno]];
                else if (!self->_stopping.load()) {
                    const int result = self->_decoderResult.load();
                    [self report:[NSString stringWithFormat:@"Decoder stream ended: %d. Check guest oracle independently.", result]];
                    [self sendFinalAfterOutputDrained];
                }
                break;
            }
            NSData* chunk = [NSData dataWithBytes:buffer length:(NSUInteger)n];
            dispatch_data_t data = dispatch_data_create(chunk.bytes, chunk.length, self->_networkQueue, ^{ (void)chunk; });
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block bool failed = false;
            nw_connection_send(self->_connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
                failed = error != nil;
                dispatch_semaphore_signal(done);
            });
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC)) != 0 || failed) {
                [self abort:@"TLS output failed or timed out."]; break;
            }
        }
        dispatch_group_leave(self->_workers);
    });
}
- (void)authenticate {
    if (_stopping.load() || _authStarted.exchange(true)) return;
    uint8_t record[64] = {'C','B','G','T','L','S','0','1'};
    std::memcpy(record + 8, _session.bytes, 16);
    for (int i = 0; i < 8; ++i) record[24 + i] = static_cast<uint8_t>(_generation >> (56 - 8 * i));
    std::memcpy(record + 32, _token.bytes, 32);
    NSData* bytes = [NSData dataWithBytes:record length:sizeof(record)];
    std::memset(record, 0, sizeof(record));
    dispatch_data_t data = dispatch_data_create(bytes.bytes, bytes.length, _networkQueue, ^{ (void)bytes; });
    dispatch_group_enter(_workers);
    nw_connection_send(_connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        if (error || self->_stopping.load()) {
            if (error) [self abort:[NSString stringWithFormat:@"TLS authentication send failed: %d", nw_error_get_error_code(error)]];
            dispatch_group_leave(self->_workers); return;
        }
        dispatch_group_enter(self->_workers);
        nw_connection_receive(self->_connection, 1, 1, ^(dispatch_data_t reply, nw_content_context_t context, bool complete, nw_error_t err) {
            (void)context;
            __block uint8_t ack = 0xff; __block size_t count = 0;
            if (reply) dispatch_data_apply(reply, ^bool(dispatch_data_t region, size_t offset, const void* p, size_t n) {
                (void)region; (void)offset;
                if (n == 1 && count == 0) { ack = *static_cast<const uint8_t*>(p); count = 1; return true; }
                count += n; return false;
            });
            if (err || complete || count != 1 || ack != 0) [self abort:@"Broker authentication rejected or incomplete."];
            else if (!self->_stopping.load()) {
                self->_token = nil;
                [self report:@"Broker authenticated; starting real decoder stream."];
                [self beginBridge];
            }
            dispatch_group_leave(self->_workers);
        });
        dispatch_group_leave(self->_workers);
    });
}
- (void)start {
    if (_started.exchange(true)) { [self report:@"Restart the diagnostic app for another attempt."]; return; }
    StartGroupGuard startGuard{_workers};
    if (_stopping.load()) return;
    NSDictionary* env = NSProcessInfo.processInfo.environment;
    NSString* host = env[@"CABOOSE_GPU_HOST"];
    NSString* port = env[@"CABOOSE_GPU_PORT"];
    _pin = parseHex(env[@"CABOOSE_GPU_CERT_SHA256"], 32);
    _token = parseHex(env[@"CABOOSE_GPU_TOKEN"], 32);
    _session = parseHex(env[@"CABOOSE_GPU_SESSION"], 16);
    uint64_t portNumber = 0;
    if (!host.length || !parseNumber(port, &portNumber) || portNumber > 65535 || !_pin || !_token || !_session ||
        !parseNumber(env[@"CABOOSE_GPU_GENERATION"], &_generation) || !parseNumber(env[@"CABOOSE_GPU_PROCESS"], &_process)) {
        [self abort:@"Missing or invalid private diagnostic configuration."]; return;
    }
    std::lock_guard<std::recursive_mutex> stateLock(_stateMutex);
    if (_stopping.load()) return;
    auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(resolveVulkan("vkGetInstanceProcAddr"));
    if (!get || get != &vkGetInstanceProcAddr || !resolveVulkan("vkCreateInstance") || !resolveVulkan("vkDestroyInstance")) {
        [self abort:@"The shared MoltenVK loader exports are unavailable."]; return;
    }
    int result = caboose_gpu_diagnostic_start(static_cast<const uint8_t*>(_session.bytes), _generation,
                                               _process, get, resolveVulkan, &_diagnostic);
    if (result) { [self abort:[NSString stringWithFormat:@"Decoder initialization failed: %d", result]]; return; }
    if (_stopping.load()) return;
    caboose_gpu_device_info info{};
    result = caboose_gpu_diagnostic_device_info(_diagnostic, &info);
    if (result) { [self abort:[NSString stringWithFormat:@"Executor identity failed: %d", result]]; return; }
    NSString* device = [NSString stringWithUTF8String:info.device_name];
    NSString* driver = [NSString stringWithUTF8String:info.driver_info];
    if (!device || !driver) { [self abort:@"Executor identity is not valid UTF-8."]; return; }
    [self report:[NSString stringWithFormat:@"Executor %@ (%@), Vulkan driver %u; session %@, generation %llu, process %llu.",
                  device, driver, info.driver_version, env[@"CABOOSE_GPU_SESSION"], _generation, _process]];
    NSData* pin = _pin;
    nw_parameters_t params = nw_parameters_create_secure_tcp(^(nw_protocol_options_t options) {
        sec_protocol_options_t security = nw_tls_copy_sec_protocol_options(options);
        sec_protocol_options_set_min_tls_protocol_version(security, tls_protocol_version_TLSv13);
        sec_protocol_options_set_max_tls_protocol_version(security, tls_protocol_version_TLSv13);
        sec_protocol_options_set_verify_block(security, ^(sec_protocol_metadata_t metadata, sec_trust_t trust, sec_protocol_verify_complete_t complete) {
            (void)metadata; complete(certMatches(trust, pin));
        }, self->_networkQueue);
    }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    if (!params) { [self abort:@"Could not configure pinned TLS."]; return; }
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, port.UTF8String);
    if (!endpoint) { [self abort:@"Could not configure broker endpoint."]; return; }
    _connection = nw_connection_create(endpoint, params);
    if (!_connection) { [self abort:@"Could not create broker connection."]; return; }
    nw_connection_set_queue(_connection, _networkQueue);
    // Network.framework guarantees cancelled is the final state callback and
    // all outstanding sends/receives finish before it. Hold one group entry
    // until then so cleanup cannot invalidate stream state early.
    dispatch_group_enter(_workers);
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (state == nw_connection_state_ready) [self authenticate];
        else if (state == nw_connection_state_failed) [self abort:[NSString stringWithFormat:@"Pinned TLS connection failed: %d", error ? nw_error_get_error_code(error) : 0]];
        else if (state == nw_connection_state_cancelled) dispatch_group_leave(self->_workers);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), _networkQueue, ^{ [self abort:@"Diagnostic deadline expired."]; });
    nw_connection_start(_connection);
}
@end

@interface DiagnosticApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation DiagnosticApp {
    UILabel* _label;
    DiagnosticRunner* _runner;
}
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController* controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    _label = [[UILabel alloc] initWithFrame:CGRectMake(24, 120, self.window.bounds.size.width - 48, 240)];
    _label.numberOfLines = 0; _label.text = @"Private GPU diagnostic. Start only for an authorized broker session.";
    [controller.view addSubview:_label];
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(24, 380, 240, 48); [button setTitle:@"Start diagnostic" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(startDiagnostic) forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:button];
    UIButton* stop = [UIButton buttonWithType:UIButtonTypeSystem];
    stop.frame = CGRectMake(24, 440, 240, 48); [stop setTitle:@"Stop diagnostic" forState:UIControlStateNormal];
    [stop addTarget:self action:@selector(stopDiagnostic) forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:stop];
    self.window.rootViewController = controller; [self.window makeKeyAndVisible];
    return YES;
}
- (void)stopDiagnostic {
    if (_runner) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self->_runner stop]; });
}
- (void)startDiagnostic {
    if (!_runner) {
        __weak DiagnosticApp* weakSelf = self;
        _runner = [[DiagnosticRunner alloc] initWithReport:^(NSString* text) {
            DiagnosticApp* strongSelf = weakSelf;
            if (strongSelf) strongSelf->_label.text = text;
        }];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self->_runner start]; });
}
@end
int main(int argc, char* argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(DiagnosticApp.class)); }
}
