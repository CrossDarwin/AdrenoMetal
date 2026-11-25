// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#define NB_SHADER_CACHE_XPC
#include "ShaderCacheIOS.h"
#include <atomic>
#include <dlfcn.h>
#include <mach/message.h>
#include <sys/resource.h>
#include <unistd.h>
#include <xpc/xpc.h>

extern "C" void xpc_connection_get_audit_token(xpc_connection_t, audit_token_t *);
extern "C" int csops_audittoken(pid_t, unsigned int, void *, size_t, audit_token_t *);

static xpc_connection_t activePeer;
static std::atomic<bool> stopping;
__attribute__((used)) static const char authorizedAppHash[] = NB_SHADER_CACHE_APP_CDHASH;

static bool authorized(xpc_connection_t peer) {
    if (xpc_connection_get_euid(peer) != getuid()) return false;
    audit_token_t token = {};
    xpc_connection_get_audit_token(peer, &token);
    unsigned char hash[20] = {};
    // CS_OPS_CDHASH; the audit token also binds the query to the peer's PID version.
    const auto pid = static_cast<pid_t>(token.val[5]);
    if (pid <= 0 || csops_audittoken(pid, 5, hash, sizeof hash, &token)) return false;
    char hex[41] = {};
    for (size_t i = 0; i < sizeof hash; ++i) snprintf(hex + 2 * i, 3, "%02x", hash[i]);
    return !strcmp(hex, authorizedAppHash);
}

struct RunContext {
    xpc_connection_t peer;
    uint64_t nextUpdate;
};

static void progress(void *opaque, const NBPrimeCounts &counts,
                     const char *library, const char *function) {
    auto &run = *static_cast<RunContext *>(opaque);
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if ((*library || *function) && now < run.nextUpdate) return;
    run.nextUpdate = now + 250000000;
    xpc_object_t event = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_uint64(event, "completed", counts.completed);
    xpc_dictionary_set_uint64(event, "total", counts.total);
    xpc_dictionary_set_uint64(event, "functions", counts.functions);
    xpc_dictionary_set_uint64(event, "refused", counts.refused);
    xpc_dictionary_set_uint64(event, "skipped", counts.skipped);
    xpc_dictionary_set_uint64(event, "unopened", counts.unopened);
    xpc_dictionary_set_uint64(event, "missing", counts.missing);
    xpc_dictionary_set_uint64(event, "deferred", counts.deferred);
    xpc_dictionary_set_string(event, "library", library);
    xpc_dictionary_set_string(event, "function", function);
    xpc_connection_send_message(run.peer, event);
}

static bool cancelled(void *) {
    return stopping.load(std::memory_order_relaxed);
}

static void respond(xpc_connection_t peer, xpc_object_t request, NBPrimeResult result) {
    if (xpc_object_t reply = xpc_dictionary_create_reply(request)) {
        xpc_dictionary_set_int64(reply, "result", static_cast<int>(result));
        xpc_connection_send_message(peer, reply);
    }
}

static void start(xpc_connection_t peer, xpc_object_t request) {
    activePeer = peer;
    stopping.store(false, std::memory_order_relaxed);
    xpc_object_t event = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_bool(event, "started", true);
    xpc_connection_send_message(peer, event);
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            void *plugin = dlopen("/System/Library/Extensions/NativeAdrenoMetal.bundle/NativeAdrenoMetal",
                                  RTLD_NOW | RTLD_NOLOAD);
            auto run = plugin ? reinterpret_cast<NBPrimeRun>(dlsym(plugin, "native_adreno_run_shader_cache")) : nullptr;
            RunContext context{peer, 0};
            const auto result = run ? run(device, progress, cancelled, &context) : NBPrimeResult::Unavailable;
            if (plugin) dlclose(plugin);
            dispatch_async(dispatch_get_main_queue(), ^{
                respond(peer, request, result);
                // A fresh on-demand process also resets the compiler allocator between runs.
                xpc_connection_send_barrier(peer, ^{ _exit(0); });
            });
        }
    }];
    thread.stackSize = 8u << 20;
    thread.qualityOfService = NSQualityOfServiceUtility;
    [thread start];
}

static void handle(xpc_connection_t peer, xpc_object_t event) {
    if (xpc_get_type(event) == XPC_TYPE_ERROR) {
        if (activePeer == peer) stopping.store(true, std::memory_order_relaxed);
        return;
    }
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    if (!authorized(peer)) {
        respond(peer, event, NBPrimeResult::Unavailable);
        xpc_connection_cancel(peer);
        return;
    }
    const char *command = xpc_dictionary_get_string(event, "command");
    if (!command) return;
    if (!strcmp(command, "stop")) {
        if (activePeer == peer) stopping.store(true, std::memory_order_relaxed);
    } else if (!strcmp(command, "start")) {
        if (activePeer) respond(peer, event, NBPrimeResult::Busy);
        else start(peer, event);
    }
}

int main() {
    @autoreleasepool {
        setpriority(PRIO_PROCESS, 0, 10);
        xpc_connection_t listener = NBShaderCacheConnection(XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (!listener) return 69;
        xpc_connection_set_event_handler(listener, ^(xpc_object_t object) {
            if (xpc_get_type(object) != XPC_TYPE_CONNECTION) return;
            xpc_connection_t peer = static_cast<xpc_connection_t>(object);
            xpc_connection_set_target_queue(peer, dispatch_get_main_queue());
            xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
                handle(peer, event);
                if (event == XPC_ERROR_CONNECTION_INVALID) {
                    // Replacing the handler breaks its reference to the connection.
                    xpc_connection_set_event_handler(peer, ^(xpc_object_t) {});
                }
            });
            xpc_connection_resume(peer);
        });
        xpc_connection_resume(listener);
        dispatch_main();
    }
}
