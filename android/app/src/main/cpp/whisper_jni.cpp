#include <jni.h>
#include <android/log.h>
#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "whisper.h"

namespace {
constexpr const char *kTag = "NuviWhisper";

struct Engine {
    explicit Engine(whisper_context *value) : context(value) {}
    ~Engine() { if (context != nullptr) whisper_free(context); }
    whisper_context *context;
    std::mutex mutex;
    std::atomic<bool> cancelled{false};
};

bool abortWhisper(void *data) {
    return static_cast<Engine *>(data)->cancelled.load(std::memory_order_relaxed);
}

void throwIllegalState(JNIEnv *env, const char *message) {
    jclass type = env->FindClass("java/lang/IllegalStateException");
    if (type != nullptr) env->ThrowNew(type, message);
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_app_nuvi_android_infrastructure_whisper_WhisperNativeEngine_nativeCreate(
        JNIEnv *env, jobject, jstring modelPath) {
    if (modelPath == nullptr) {
        throwIllegalState(env, "Model path is required");
        return 0;
    }
    const char *chars = env->GetStringUTFChars(modelPath, nullptr);
    if (chars == nullptr) return 0;
    whisper_context_params params = whisper_context_default_params();
    params.use_gpu = false;
    whisper_context *context = whisper_init_from_file_with_params(chars, params);
    env->ReleaseStringUTFChars(modelPath, chars);
    if (context == nullptr) {
        throwIllegalState(env, "Unable to load the Whisper model");
        return 0;
    }
    return reinterpret_cast<jlong>(new Engine(context));
}

extern "C" JNIEXPORT jstring JNICALL
Java_app_nuvi_android_infrastructure_whisper_WhisperNativeEngine_nativeTranscribe(
        JNIEnv *env, jobject, jlong handle, jfloatArray pcm, jint threads, jstring language) {
    auto *engine = reinterpret_cast<Engine *>(handle);
    if (engine == nullptr || pcm == nullptr) {
        throwIllegalState(env, "Whisper engine is closed or audio is missing");
        return nullptr;
    }
    const jsize count = env->GetArrayLength(pcm);
    std::vector<float> samples(static_cast<size_t>(count));
    env->GetFloatArrayRegion(pcm, 0, count, samples.data());
    if (env->ExceptionCheck()) return nullptr;

    const char *languageChars = language == nullptr ? nullptr : env->GetStringUTFChars(language, nullptr);
    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = std::clamp(static_cast<int>(threads), 1, 8);
    params.translate = false;
    params.no_context = true;
    params.single_segment = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.language = languageChars == nullptr ? "es" : languageChars;
    params.abort_callback = abortWhisper;
    params.abort_callback_user_data = engine;

    std::string result;
    {
        std::lock_guard<std::mutex> lock(engine->mutex);
        if (whisper_full(engine->context, params, samples.data(), count) != 0) {
            if (languageChars != nullptr) env->ReleaseStringUTFChars(language, languageChars);
            throwIllegalState(env, "Whisper transcription failed");
            return nullptr;
        }
        const int segments = whisper_full_n_segments(engine->context);
        for (int i = 0; i < segments; ++i) {
            const char *text = whisper_full_get_segment_text(engine->context, i);
            if (text != nullptr) result += text;
        }
    }
    if (languageChars != nullptr) env->ReleaseStringUTFChars(language, languageChars);
    return env->NewStringUTF(result.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_app_nuvi_android_infrastructure_whisper_WhisperNativeEngine_nativeCancel(
        JNIEnv *, jobject, jlong handle) {
    auto *engine = reinterpret_cast<Engine *>(handle);
    if (engine != nullptr) engine->cancelled.store(true, std::memory_order_relaxed);
}

extern "C" JNIEXPORT void JNICALL
Java_app_nuvi_android_infrastructure_whisper_WhisperNativeEngine_nativeResetCancellation(
        JNIEnv *, jobject, jlong handle) {
    auto *engine = reinterpret_cast<Engine *>(handle);
    if (engine != nullptr) engine->cancelled.store(false, std::memory_order_relaxed);
}

extern "C" JNIEXPORT void JNICALL
Java_app_nuvi_android_infrastructure_whisper_WhisperNativeEngine_nativeDestroy(
        JNIEnv *, jobject, jlong handle) {
    delete reinterpret_cast<Engine *>(handle);
}
