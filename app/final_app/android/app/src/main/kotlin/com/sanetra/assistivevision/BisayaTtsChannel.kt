package com.sanetra.assistivevision

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/**
 * Instant offline PCM clip-concatenation player for Bisaya (`ceb-PH`) currency speech.
 * Replaces the slow 10-13s neural MMS ONNX path with pre-normalized 16 kHz WAV clips
 * streamed through Android AudioTrack with immediate hardware interruption.
 */
class BisayaTtsChannel(
    private val context: Context,
    private val channelName: String = "vision_assistant/bisaya_tts",
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "BisayaAudio"
        private const val ASSET_DIR = "assets/audio/bisaya"
        private const val SAMPLE_RATE = 16000
        private const val SEGMENT_GAP_SAMPLES = 320 // 20 ms silence between clips
    }

    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val audioExecutor = Executors.newSingleThreadExecutor()

    private val clipCache = ConcurrentHashMap<String, ShortArray>()
    private val activeUtteranceSeq = AtomicLong(0)
    private val isSpeaking = AtomicBoolean(false)
    @Volatile
    private var currentAudioTrack: AudioTrack? = null
    @Volatile
    private var initialized = false

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                val t0 = System.nanoTime()
                audioExecutor.execute {
                    try {
                        val count = ensureClipAssetsLoaded()
                        val loadMs = (System.nanoTime() - t0) / 1_000_000.0
                        val heapMb = Debug.getNativeHeapAllocatedSize() / (1024.0 * 1024.0)
                        Log.i(
                            TAG,
                            "[BISAYA-AUDIO] Clip cache ready: clips=$count loadMs=${"%.2f".format(loadMs)} " +
                                "nativeHeapMb=${"%.1f".format(heapMb)}",
                        )
                        mainHandler.post {
                            result.success(
                                mapOf(
                                    "status" to "initialized",
                                    "engine" to "recorded_pcm_clips",
                                    "clipsLoaded" to count,
                                    "loadTimeMs" to loadMs,
                                    "sampleRate" to SAMPLE_RATE,
                                ),
                            )
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "[BISAYA-AUDIO] Init failed", e)
                        mainHandler.post { result.error("BISAYA_INIT_FAILED", e.message, null) }
                    }
                }
            }
            "speak" -> {
                val reqStartNs = System.nanoTime()
                val text = call.argument<String>("text") ?: ""
                @Suppress("UNCHECKED_CAST")
                val clips = call.argument<List<String>>("clips") ?: resolveFallbackClips(text)
                if (clips.isEmpty()) {
                    result.success(0)
                    return
                }
                val utteranceId = activeUtteranceSeq.incrementAndGet()
                stopAudioTrackOnly()
                audioExecutor.execute {
                    playClipSequence(utteranceId, clips, reqStartNs)
                }
                result.success(1)
            }
            "stop" -> {
                val cancelStartNs = System.nanoTime()
                val prevId = activeUtteranceSeq.get()
                activeUtteranceSeq.incrementAndGet()
                val wasSpeaking = isSpeaking.getAndSet(false)
                stopAudioTrackOnly()
                val cancelMs = (System.nanoTime() - cancelStartNs) / 1_000_000.0
                if (wasSpeaking) {
                    Log.i(TAG, "[BISAYA-AUDIO] Interrupted utt=$prevId in ${"%.2f".format(cancelMs)}ms")
                    mainHandler.post {
                        channel?.invokeMethod("onCancel", mapOf("utteranceId" to prevId, "cancelMs" to cancelMs))
                    }
                }
                result.success(1)
            }
            "dispose" -> {
                activeUtteranceSeq.incrementAndGet()
                stopAudioTrackOnly()
                clipCache.clear()
                initialized = false
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun resolveFallbackClips(text: String): List<String> {
        val norm = text.trim().lowercase()
        return when {
            norm == "bisaya" || norm == "bisaya." -> listOf("confirm_bisaya")
            norm.startsWith("walay kwarta") -> listOf("prompt_empty")
            norm.startsWith("dili klaro") -> listOf("warn_overlap")
            norm.startsWith("nagkasumpaki") -> listOf("warn_conflict")
            else -> listOf("confirm_bisaya")
        }
    }

    private fun ensureClipAssetsLoaded(): Int {
        if (initialized && clipCache.isNotEmpty()) return clipCache.size
        val loader = FlutterInjector.instance().flutterLoader()
        val assetDirKey = loader.getLookupKeyForAsset(ASSET_DIR).trimEnd('/')
        val files = context.assets.list(assetDirKey) ?: emptyArray()
        for (name in files) {
            if (!name.endsWith(".wav")) continue
            val clipId = name.removeSuffix(".wav")
            if (!clipCache.containsKey(clipId)) {
                context.assets.open("$assetDirKey/$name").use { input ->
                    val bytes = input.readBytes()
                    clipCache[clipId] = parseWavPcm16(bytes)
                }
            }
        }
        initialized = clipCache.isNotEmpty()
        return clipCache.size
    }

    private fun parseWavPcm16(wavBytes: ByteArray): ShortArray {
        var pos = 12
        var dataStart = 44
        var dataLen = max(0, wavBytes.size - 44)
        while (pos + 8 <= wavBytes.size) {
            val chunkId = String(wavBytes, pos, 4, Charsets.US_ASCII)
            val chunkSize = ByteBuffer.wrap(wavBytes, pos + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            if (chunkId == "data") {
                dataStart = pos + 8
                dataLen = min(chunkSize, wavBytes.size - dataStart)
                break
            }
            pos += 8 + chunkSize
        }
        val sampleCount = dataLen / 2
        val pcm = ShortArray(sampleCount)
        ByteBuffer.wrap(wavBytes, dataStart, sampleCount * 2)
            .order(ByteOrder.LITTLE_ENDIAN)
            .asShortBuffer()
            .get(pcm)
        return pcm
    }

    private fun playClipSequence(utteranceId: Long, clips: List<String>, reqStartNs: Long) {
        try {
            ensureClipAssetsLoaded()
            if (activeUtteranceSeq.get() != utteranceId) return

            val arrays = ArrayList<ShortArray>(clips.size)
            var totalSamples = 0
            for (i in clips.indices) {
                val pcm = clipCache[clips[i]] ?: continue
                arrays.add(pcm)
                totalSamples += pcm.size
                if (i < clips.lastIndex) totalSamples += SEGMENT_GAP_SAMPLES
            }
            if (totalSamples == 0) {
                mainHandler.post { channel?.invokeMethod("onDone", mapOf("utteranceId" to utteranceId)) }
                return
            }

            val combined = ShortArray(totalSamples)
            var cursor = 0
            for (i in arrays.indices) {
                val src = arrays[i]
                System.arraycopy(src, 0, combined, cursor, src.size)
                cursor += src.size
                if (i < arrays.lastIndex) {
                    cursor += SEGMENT_GAP_SAMPLES
                }
            }

            val minBufBytes = AudioTrack.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val bufBytes = max(minBufBytes, 4096)

            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(bufBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            currentAudioTrack = track
            isSpeaking.set(true)
            track.play()

            var onsetRecorded = false
            var onsetMs = 0.0
            val chunkSamples = 512
            var offset = 0
            while (offset < combined.size && activeUtteranceSeq.get() == utteranceId) {
                val count = min(chunkSamples, combined.size - offset)
                val written = track.write(combined, offset, count)
                if (written < 0) break
                if (!onsetRecorded && track.playbackHeadPosition > 0) {
                    onsetMs = (System.nanoTime() - reqStartNs) / 1_000_000.0
                    onsetRecorded = true
                    mainHandler.post {
                        channel?.invokeMethod("onStart", mapOf("utteranceId" to utteranceId, "onsetMs" to onsetMs))
                    }
                }
                offset += count
            }
            if (!onsetRecorded && activeUtteranceSeq.get() == utteranceId) {
                onsetMs = (System.nanoTime() - reqStartNs) / 1_000_000.0
                mainHandler.post {
                    channel?.invokeMethod("onStart", mapOf("utteranceId" to utteranceId, "onsetMs" to onsetMs))
                }
            }

            if (activeUtteranceSeq.get() == utteranceId) {
                try {
                    track.stop()
                } catch (_: Exception) {}
                isSpeaking.set(false)
                currentAudioTrack = null
                track.release()
                val audioDurMs = (combined.size * 1000.0) / SAMPLE_RATE
                val heapMb = Debug.getNativeHeapAllocatedSize() / (1024.0 * 1024.0)
                Log.i(
                    TAG,
                    "[BISAYA-AUDIO] Done utt=$utteranceId clips=${clips.size} " +
                        "onsetMs=${"%.2f".format(onsetMs)} audioDurMs=${"%.0f".format(audioDurMs)} " +
                        "nativeHeapMb=${"%.1f".format(heapMb)} seq=${clips.joinToString("+")}",
                )
                mainHandler.post {
                    channel?.invokeMethod(
                        "onDone",
                        mapOf("utteranceId" to utteranceId, "onsetMs" to onsetMs, "audioDurMs" to audioDurMs),
                    )
                }
            } else {
                isSpeaking.set(false)
                currentAudioTrack = null
                try { track.release() } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            isSpeaking.set(false)
            Log.e(TAG, "[BISAYA-AUDIO] Playback error", e)
            mainHandler.post {
                channel?.invokeMethod("onError", mapOf("utteranceId" to utteranceId, "error" to (e.message ?: "unknown")))
            }
        }
    }

    private fun stopAudioTrackOnly() {
        val track = currentAudioTrack ?: return
        currentAudioTrack = null
        try {
            track.pause()
            track.flush()
            track.stop()
        } catch (_: Exception) {}
        try {
            track.release()
        } catch (_: Exception) {}
    }
}
