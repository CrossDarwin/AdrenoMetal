// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>
#define NB_SHADER_CACHE_XPC
#include "ShaderCacheIOS.h"

@interface NBShaderCacheController : UIViewController
- (void)updateProgress:(xpc_object_t)event;
@end

@implementation NBShaderCacheController {
    UILabel *_status;
    UILabel *_counts;
    UILabel *_function;
    UIProgressView *_progress;
    UIButton *_start;
    UIButton *_stop;
    BOOL _running;
    BOOL _stopRequested;
    BOOL _workerStarted;
    unsigned _connectionID;
    unsigned _restartRetries;
    unsigned _interruptions;
    xpc_connection_t _worker;
}

- (UILabel *)label:(UIFontTextStyle)style {
    UILabel *label = [UILabel new];
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Shader Cache";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _status = [self label:UIFontTextStyleHeadline];
    _status.text = @"就绪";
    _counts = [self label:UIFontTextStyleSubheadline];
    _function = [self label:UIFontTextStyleFootnote];
    _function.textColor = UIColor.secondaryLabelColor;
    _function.numberOfLines = 3;
    _progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];

    UIButtonConfiguration *start = [UIButtonConfiguration filledButtonConfiguration];
    start.title = @"开始预编译";
    start.image = [UIImage systemImageNamed:@"play.fill"];
    start.imagePadding = 8;
    _start = [UIButton buttonWithConfiguration:start primaryAction:nil];
    [_start addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    UIButtonConfiguration *stop = [UIButtonConfiguration tintedButtonConfiguration];
    stop.title = @"停止";
    stop.image = [UIImage systemImageNamed:@"stop.fill"];
    stop.imagePadding = 8;
    _stop = [UIButton buttonWithConfiguration:stop primaryAction:nil];
    [_stop addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    _stop.enabled = NO;
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[_start, _stop]];
    buttons.spacing = 12;
    buttons.axis = UILayoutConstraintAxisVertical;
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[_status, _progress, _counts, _function, buttons]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 14;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [self.view addSubview:content];
    NSLayoutConstraint *width = [content.widthAnchor constraintEqualToAnchor:safe.widthAnchor multiplier:0.8];
    width.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [content.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [content.topAnchor constraintEqualToAnchor:safe.topAnchor constant:28],
        [content.widthAnchor constraintLessThanOrEqualToConstant:540],
        [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],
        width,
    ]];
}

- (void)updateProgress:(xpc_object_t)event {
    const auto count = [&](const char *key) { return (unsigned)xpc_dictionary_get_uint64(event, key); };
    const unsigned completed = count("completed"), total = count("total");
    _progress.progress = total ? (float)completed / total : 0;
    _counts.text = [NSString stringWithFormat:@"通过库 %u / %u    已编译函数 %u\n失败 %u    跳过 %u    库读取失败 %u\n清单缺失 %u    未安装应用条目 %u",
        completed, total, count("functions"), count("refused"), count("skipped"),
        count("unopened"), count("missing"), count("deferred")];
    const char *path = xpc_dictionary_get_string(event, "library");
    const char *function = xpc_dictionary_get_string(event, "function");
    NSString *library = path ? [NSString stringWithUTF8String:path].lastPathComponent : @"";
    NSString *operation = function ? [NSString stringWithUTF8String:function] : @"";
    _function.text = operation.length ? [NSString stringWithFormat:@"%@\n%@", library, operation] : library;
}

- (void)stop {
    if (!_running) return;
    _stopRequested = YES;
    if (!_worker) {
        [self finish:NBPrimeResult::Stopped];
        return;
    }
    xpc_object_t request = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(request, "command", "stop");
    xpc_connection_send_message(_worker, request);
    _stop.enabled = NO;
    _status.text = @"正在停止";
}

- (void)start {
    if (_running) return;
    _running = YES;
    _stopRequested = NO;
    _restartRetries = 0;
    _interruptions = 0;
    _start.enabled = NO;
    _stop.enabled = YES;
    _status.text = @"正在预编译";
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    [self connectWorker];
}

- (void)connectWorker {
    const unsigned connectionID = ++_connectionID;
    _workerStarted = NO;
    _worker = NBShaderCacheConnection(0);
    if (!_worker) {
        [self finish:NBPrimeResult::Unavailable];
        return;
    }
    xpc_connection_set_event_handler(_worker, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_DICTIONARY || !self->_running ||
            self->_connectionID != connectionID) return;
        self->_workerStarted = YES;
        if (xpc_dictionary_get_bool(event, "started")) return;
        self->_restartRetries = 0;
        if (!self->_stopRequested) self->_status.text = @"正在预编译";
        [self updateProgress:event];
    });
    xpc_connection_resume(_worker);
    xpc_object_t request = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(request, "command", "start");
    xpc_connection_send_message_with_reply(_worker, request, dispatch_get_main_queue(), ^(xpc_object_t reply) {
        if (!self->_running || self->_connectionID != connectionID) return;
        const auto result = xpc_get_type(reply) == XPC_TYPE_DICTIONARY
            ? static_cast<NBPrimeResult>(xpc_dictionary_get_int64(reply, "result"))
            : NBPrimeResult::Unavailable;
        const bool rotate = result == NBPrimeResult::MemoryLimit || result == NBPrimeResult::NextBatch;
        const bool disconnected = xpc_get_type(reply) == XPC_TYPE_ERROR;
        if (self->_stopRequested && (rotate || disconnected)) {
            [self finish:NBPrimeResult::Stopped];
        } else if (rotate) {
            self->_restartRetries = 12;
            self->_interruptions = 0;
            [self reconnectWorker:@"已保存进度，正在启动新的编译进程"];
        } else if (disconnected && self->_workerStarted) {
            if (++self->_interruptions > 4) {
                [self finish:NBPrimeResult::WorkerInterrupted];
            } else {
                self->_restartRetries = 12;
                [self reconnectWorker:@"编译进程中断，正在从检查点恢复"];
            }
        } else if ((result == NBPrimeResult::Busy || disconnected) && self->_restartRetries) {
            --self->_restartRetries;
            [self reconnectWorker:self->_status.text];
        } else [self finish:result];
    });
}

- (void)reconnectWorker:(NSString *)status {
    xpc_connection_cancel(_worker);
    _worker = nil;
    _status.text = status;
    const unsigned connectionID = ++_connectionID;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self->_running && self->_connectionID == connectionID) [self connectWorker];
    });
}

- (void)finish:(NBPrimeResult)result {
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    if (_worker) {
        xpc_connection_cancel(_worker);
        _worker = nil;
    }
    _running = NO;
    _start.enabled = YES;
    _stop.enabled = NO;
    switch (result) {
        case NBPrimeResult::Complete: _status.text = @"已完成"; break;
        case NBPrimeResult::Incomplete: _status.text = @"部分库未完成"; break;
        case NBPrimeResult::Stopped: _status.text = @"已停止"; break;
        case NBPrimeResult::Unavailable: _status.text = @"无法连接系统预编译服务"; break;
        case NBPrimeResult::CacheUnavailable: _status.text = @"无法打开系统着色器缓存"; break;
        case NBPrimeResult::Busy: _status.text = @"已有预编译在运行"; break;
        case NBPrimeResult::MemoryLimit: _status.text = @"已暂停，可继续预编译"; break;
        case NBPrimeResult::PublicationFailed: _status.text = @"缓存发布失败"; break;
        case NBPrimeResult::MemoryLimitNoProgress: _status.text = @"达到内存限制，本批未推进"; break;
        case NBPrimeResult::NextBatch: _status.text = @"已保存进度"; break;
        case NBPrimeResult::WorkerInterrupted: _status.text = @"编译进程多次中断，已保存的进度可继续"; break;
    }
}
@end

@interface NBShaderCacheApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) NBShaderCacheController *controller;
@end

@implementation NBShaderCacheApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)app;
    (void)options;
    self.controller = [NBShaderCacheController new];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:self.controller];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)app {
    (void)app;
    [self.controller stop];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(NBShaderCacheApp.class));
    }
}
