#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Accelerate/Accelerate.h>
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "jni.h"

typedef struct CameraCtx {
    uint8_t *front;
    uint8_t *back;
    size_t size;
    int width;
    int height;
    int fps;
    int facing;
    volatile int running;
    volatile int closed;
    volatile int refs;
    int64_t version;
    char error[512];
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    void *session;
    void *output;
    void *delegate;
    void *queue;
} CameraCtx;

@interface CameraFrameDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, assign) CameraCtx *ctx;
@end

static void *camera_queue_key = &camera_queue_key;

static void set_error(CameraCtx *ctx, NSString *message) {
    if (!ctx) return;
    pthread_mutex_lock(&ctx->mutex);
    const char *utf8 = message.UTF8String;
    snprintf(ctx->error, sizeof(ctx->error), "%s", utf8 ? utf8 : "camera error");
    ctx->running = 0;
    pthread_cond_broadcast(&ctx->cond);
    pthread_mutex_unlock(&ctx->mutex);
    NSLog(@"[CameraCapture] %@", message);
}

static CameraCtx *ctx_retain(CameraCtx *ctx) {
    __sync_add_and_fetch(&ctx->refs, 1);
    return ctx;
}

static void ctx_destroy(CameraCtx *ctx);

static void ctx_release(CameraCtx *ctx) {
    if (!ctx) return;
    if (__sync_sub_and_fetch(&ctx->refs, 1) == 0) {
        ctx_destroy(ctx);
    }
}

static CameraCtx *ctx_init(int width, int height, int fps, int facing) {
    CameraCtx *ctx = calloc(1, sizeof(CameraCtx));
    if (!ctx) return NULL;
    ctx->width = width;
    ctx->height = height;
    ctx->fps = fps;
    ctx->facing = facing;
    ctx->size = (size_t)width * (size_t)height * 4U;
    ctx->front = malloc(ctx->size);
    ctx->back = malloc(ctx->size);
    if (!ctx->front || !ctx->back) {
        free(ctx->front);
        free(ctx->back);
        free(ctx);
        return NULL;
    }
    memset(ctx->front, 0, ctx->size);
    memset(ctx->back, 0, ctx->size);
    ctx->refs = 1;
    pthread_mutex_init(&ctx->mutex, NULL);
    pthread_cond_init(&ctx->cond, NULL);
    dispatch_queue_t queue = dispatch_queue_create("camera.background.capture", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(queue, camera_queue_key, (void *)1, NULL);
    ctx->queue = (__bridge_retained void *)queue;
    return ctx;
}

static void ctx_destroy(CameraCtx *ctx) {
    if (!ctx) return;
    ctx->closed = 1;
    ctx->running = 0;
    pthread_mutex_lock(&ctx->mutex);
    pthread_cond_broadcast(&ctx->cond);
    pthread_mutex_unlock(&ctx->mutex);

    if (ctx->queue) {
        dispatch_queue_t queue = (__bridge dispatch_queue_t)ctx->queue;
        void (^stopBlock)(void) = ^{
            if (ctx->session) {
                AVCaptureSession *session = (__bridge AVCaptureSession *)ctx->session;
                [session stopRunning];
            }
        };
        if (dispatch_get_specific(camera_queue_key)) {
            stopBlock();
        } else {
            dispatch_sync(queue, stopBlock);
        }
    }
    if (ctx->output) {
        AVCaptureVideoDataOutput *output = (__bridge_transfer AVCaptureVideoDataOutput *)ctx->output;
        (void)output;
        ctx->output = NULL;
    }
    if (ctx->delegate) {
        CameraFrameDelegate *delegate = (__bridge_transfer CameraFrameDelegate *)ctx->delegate;
        (void)delegate;
        ctx->delegate = NULL;
    }
    if (ctx->session) {
        AVCaptureSession *session = (__bridge_transfer AVCaptureSession *)ctx->session;
        (void)session;
        ctx->session = NULL;
    }
    if (ctx->queue) {
        dispatch_queue_t queue = (__bridge_transfer dispatch_queue_t)ctx->queue;
        (void)queue;
        ctx->queue = NULL;
    }
    pthread_mutex_destroy(&ctx->mutex);
    pthread_cond_destroy(&ctx->cond);
    free(ctx->front);
    free(ctx->back);
    free(ctx);
}

static UIInterfaceOrientation current_interface_orientation(void) {
    __block UIInterfaceOrientation result = UIInterfaceOrientationUnknown;
    void (^readOrientation)(void) = ^{
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                result = ((UIWindowScene *)scene).interfaceOrientation;
                break;
            }
        }
        if (result == UIInterfaceOrientationUnknown) {
            result = UIApplication.sharedApplication.statusBarOrientation;
        }
    };
    // Camera setup runs on a background queue, while UIApplication scene
    // properties are main-thread-only. Read them on the main thread.
    if ([NSThread isMainThread]) {
        readOrientation();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readOrientation);
    }
    if (result == UIInterfaceOrientationUnknown) {
        // Minecraft Java Edition launchers run in landscape; this is also the
        // safest default when iOS reports "unknown" during app launch.
        return UIInterfaceOrientationLandscapeRight;
    }
    return result;
}

static AVCaptureVideoOrientation camera_video_orientation(void) {
    switch (current_interface_orientation()) {
        case UIInterfaceOrientationPortrait:
            return AVCaptureVideoOrientationPortrait;
        case UIInterfaceOrientationPortraitUpsideDown:
            return AVCaptureVideoOrientationPortraitUpsideDown;
        case UIInterfaceOrientationLandscapeLeft:
            return AVCaptureVideoOrientationLandscapeLeft;
        case UIInterfaceOrientationLandscapeRight:
            return AVCaptureVideoOrientationLandscapeRight;
        default:
            return AVCaptureVideoOrientationLandscapeRight;
    }
}

static BOOL setup_session(CameraCtx *ctx) {
    if (ctx->session) return YES;

    AVCaptureDevicePosition position = ctx->facing == 1
        ? AVCaptureDevicePositionFront
        : AVCaptureDevicePositionBack;
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                              mediaType:AVMediaTypeVideo
                               position:position];
    AVCaptureDevice *device = discovery.devices.firstObject;
    if (!device) {
        device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    if (!device) {
        set_error(ctx, @"No camera device found");
        return NO;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) {
        set_error(ctx, [NSString stringWithFormat:@"Could not open camera: %@", error.localizedDescription]);
        return NO;
    }

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    if (![session canAddInput:input]) {
        set_error(ctx, @"Camera input is not supported by this session");
        return NO;
    }
    [session addInput:input];

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };

    CameraFrameDelegate *delegate = [[CameraFrameDelegate alloc] init];
    delegate.ctx = ctx;
    dispatch_queue_t queue = (__bridge dispatch_queue_t)ctx->queue;
    [output setSampleBufferDelegate:delegate queue:queue];

    if (![session canAddOutput:output]) {
        set_error(ctx, @"Camera output is not supported by this session");
        return NO;
    }
    [session addOutput:output];

    if (ctx->width >= 1280 && [session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
        session.sessionPreset = AVCaptureSessionPreset1280x720;
    } else if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
        session.sessionPreset = AVCaptureSessionPreset640x480;
    } else if ([session canSetSessionPreset:AVCaptureSessionPresetHigh]) {
        session.sessionPreset = AVCaptureSessionPresetHigh;
    }

    AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
    if (connection && connection.isVideoOrientationSupported) {
        connection.videoOrientation = camera_video_orientation();
    }

    ctx->session = (__bridge_retained void *)session;
    ctx->output = (__bridge_retained void *)output;
    ctx->delegate = (__bridge_retained void *)delegate;
    return YES;
}

static void start_capture(CameraCtx *ctx) {
    if (ctx->closed || !ctx->running) return;
    if (!setup_session(ctx)) {
        ctx->running = 0;
        return;
    }
    AVCaptureSession *session = (__bridge AVCaptureSession *)ctx->session;
    [session startRunning];
}

static void begin_capture(CameraCtx *ctx) {
    if (ctx->closed || !ctx->running) return;
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        start_capture(ctx);
        return;
    }
    if (status == AVAuthorizationStatusNotDetermined) {
        ctx_retain(ctx);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async((__bridge dispatch_queue_t)ctx->queue, ^{
                if (granted && !ctx->closed && ctx->running) {
                    start_capture(ctx);
                } else if (!ctx->closed) {
                    set_error(ctx, @"Camera permission denied");
                }
                ctx_release(ctx);
            });
        }];
        return;
    }
    set_error(ctx, @"Camera permission denied");
}

@implementation CameraFrameDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    (void)output;
    (void)connection;
    CameraCtx *ctx = self.ctx;
    if (!ctx || ctx->closed || !ctx->running) return;

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA) return;

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t srcWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t srcHeight = CVPixelBufferGetHeight(pixelBuffer);
    size_t srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if (!base || srcWidth == 0 || srcHeight == 0) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }

    double targetAspect = (double)ctx->width / (double)ctx->height;
    double sourceAspect = (double)srcWidth / (double)srcHeight;
    size_t cropWidth;
    size_t cropHeight;
    size_t cropX;
    size_t cropY;
    if (sourceAspect > targetAspect) {
        cropHeight = srcHeight;
        cropWidth = (size_t)llround((double)srcHeight * targetAspect);
        cropWidth = MIN(cropWidth, srcWidth);
        cropX = (srcWidth - cropWidth) / 2;
        cropY = 0;
    } else {
        cropWidth = srcWidth;
        cropHeight = (size_t)llround((double)srcWidth / targetAspect);
        cropHeight = MIN(cropHeight, srcHeight);
        cropX = 0;
        cropY = (srcHeight - cropHeight) / 2;
    }

    vImage_Buffer source = {
        .data = base + cropY * srcRowBytes + cropX * 4,
        .height = cropHeight,
        .width = cropWidth,
        .rowBytes = srcRowBytes
    };
    vImage_Buffer destination = {
        .data = ctx->back,
        .height = (vImagePixelCount)ctx->height,
        .width = (vImagePixelCount)ctx->width,
        .rowBytes = (size_t)ctx->width * 4U
    };
    vImage_Error scaleError = vImageScale_ARGB8888(&source, &destination, kvImageNoFlags);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (scaleError != kvImageNoError) {
        return;
    }

    uint8_t *pixels = ctx->back;
    for (size_t index = 0; index < ctx->size; index += 4) {
        uint8_t blue = pixels[index];
        uint8_t red = pixels[index + 2];
        pixels[index] = red;
        pixels[index + 2] = blue;
    }

    pthread_mutex_lock(&ctx->mutex);
    if (ctx->closed) {
        pthread_mutex_unlock(&ctx->mutex);
        return;
    }
    uint8_t *oldFront = ctx->front;
    ctx->front = ctx->back;
    ctx->back = oldFront;
    ctx->version++;
    pthread_cond_broadcast(&ctx->cond);
    pthread_mutex_unlock(&ctx->mutex);
}

@end

#pragma mark - JNI

JNIEXPORT jlong JNICALL Java_com_apple_ios_camera_NativeCameraCapture_init(
    JNIEnv *env, jclass clazz, jint width, jint height, jint fps, jint facing) {
    (void)env;
    (void)clazz;
    if (width < 16 || height < 16 || width > 4096 || height > 4096) {
        return 0;
    }
    CameraCtx *ctx = ctx_init((int)width, (int)height, (int)fps, (int)facing);
    return (jlong)(intptr_t)ctx;
}

JNIEXPORT void JNICALL Java_com_apple_ios_camera_NativeCameraCapture_start(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    CameraCtx *ctx = (CameraCtx *)(intptr_t)handle;
    if (!ctx || ctx->closed) return;

    pthread_mutex_lock(&ctx->mutex);
    ctx->running = 1;
    pthread_mutex_unlock(&ctx->mutex);

    ctx_retain(ctx);
    dispatch_async((__bridge dispatch_queue_t)ctx->queue, ^{
        begin_capture(ctx);
        ctx_release(ctx);
    });
}

JNIEXPORT void JNICALL Java_com_apple_ios_camera_NativeCameraCapture_stop(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    CameraCtx *ctx = (CameraCtx *)(intptr_t)handle;
    if (!ctx || ctx->closed) return;

    pthread_mutex_lock(&ctx->mutex);
    ctx->running = 0;
    pthread_cond_broadcast(&ctx->cond);
    pthread_mutex_unlock(&ctx->mutex);

    ctx_retain(ctx);
    dispatch_async((__bridge dispatch_queue_t)ctx->queue, ^{
        if (ctx->session) {
            AVCaptureSession *session = (__bridge AVCaptureSession *)ctx->session;
            [session stopRunning];
        }
        ctx_release(ctx);
    });
}

JNIEXPORT void JNICALL Java_com_apple_ios_camera_NativeCameraCapture_release(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    CameraCtx *ctx = (CameraCtx *)(intptr_t)handle;
    if (ctx) {
        ctx_release(ctx);
    }
}

JNIEXPORT jint JNICALL Java_com_apple_ios_camera_NativeCameraCapture_copyLatest(
    JNIEnv *env, jclass clazz, jlong handle, jbyteArray buffer, jint sinceVersion) {
    (void)clazz;
    CameraCtx *ctx = (CameraCtx *)(intptr_t)handle;
    if (!ctx || !buffer || ctx->closed) return -1;

    pthread_mutex_lock(&ctx->mutex);
    while (ctx->running && ctx->version <= (int64_t)sinceVersion) {
        pthread_cond_wait(&ctx->cond, &ctx->mutex);
    }
    if (!ctx->running) {
        pthread_mutex_unlock(&ctx->mutex);
        return -1;
    }
    int64_t newVersion = ctx->version;
    jsize length = (*env)->GetArrayLength(env, buffer);
    if ((size_t)length < ctx->size) {
        pthread_mutex_unlock(&ctx->mutex);
        return -1;
    }
    jbyte *elements = (*env)->GetByteArrayElements(env, buffer, NULL);
    if (!elements) {
        pthread_mutex_unlock(&ctx->mutex);
        return -1;
    }
    memcpy(elements, ctx->front, ctx->size);
    (*env)->ReleaseByteArrayElements(env, buffer, elements, 0);
    pthread_mutex_unlock(&ctx->mutex);
    return (jint)newVersion;
}

JNIEXPORT jint JNICALL Java_com_apple_ios_camera_NativeCameraCapture_width(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    CameraCtx *ctx = (CameraCtx *)(intptr_t)handle;
    return ctx ? ctx->width : 0;
}

JNIEXPORT jint JNICALL Java_com_apple_ios_camera_NativeCameraCapture_height(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    CameraCtx *ctx = (CameraCtx *)(intptr_t)handle;
    return ctx ? ctx->height : 0;
}

JNIEXPORT jstring JNICALL Java_com_apple_ios_camera_NativeCameraCapture_error(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)clazz;
    CameraCtx *ctx = (CameraCtx *)(intptr_t)handle;
    if (!ctx) return (*env)->NewStringUTF(env, "");
    char copy[512];
    pthread_mutex_lock(&ctx->mutex);
    memcpy(copy, ctx->error, sizeof(copy));
    copy[sizeof(copy) - 1] = '\0';
    pthread_mutex_unlock(&ctx->mutex);
    return (*env)->NewStringUTF(env, copy);
}