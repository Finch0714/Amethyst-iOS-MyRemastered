package com.apple.ios.camera;

public final class NativeCameraCapture {
    static {
        System.loadLibrary("camera_capture");
    }

    private NativeCameraCapture() {
    }

    public static native long init(int width, int height, int fps, int facing);

    public static native void start(long handle);

    public static native void stop(long handle);

    public static native void release(long handle);

    public static native int copyLatest(long handle, byte[] buffer, int sinceVersion);

    public static native int width(long handle);

    public static native int height(long handle);

    public static native String error(long handle);
}