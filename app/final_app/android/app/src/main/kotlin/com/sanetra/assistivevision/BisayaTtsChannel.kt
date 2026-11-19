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
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/**
 * High-performance, offline audio engine for Sanetra:
 * 1. Dedicated low-latency selector audio lane for instant language confirmation
 *    (English, Kannada, Hindi, Bisaya) with isolated AudioTrack.MODE_STATIC playback.
 * 2. Instant offline PCM clip-concatenation player for Bisaya currency speech.
 * 3. Strict preemption and latest-selection-wins guarantee.
 */
class BisayaTtsChannel(
    private val context: Context,
    private val channelName: String = "vision_assistant/bisaya_tts",
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "BisayaAudio"
        private const val ASSET_DIR = "assets/audio/bisaya"
        private const val DEFAULT_SAMPLE_RATE = 16000
        private const val SEGMENT_GAP_SAMPLES = 320 // 20 ms silence between clips at 16kHz
    }

    data class DecodedClip(
        val pcm: ShortArray,
        val sampleRate: Int = DEFAULT_SAMPLE_RATE,
        val channels: Int = 1,
    )

    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val audioExecutor = Executors.newSingleThreadExecutor()
    private val selectorExecutor = Executors.newSingleThreadExecutor()

    private val clipCache = ConcurrentHashMap<String, DecodedClip>()

    // Currency/general utterance tracking
    private val activeUtteranceSeq = AtomicLong(0)
    private val isSpeaking = AtomicBoolean(false)
    @Volatile
    private var currentAudioTrack: AudioTrack? = null

    // Dedicated selector lane tracking
    private val selectorLock = Any()
    private val activeSelectorSeq = AtomicLong(0)
    private val isSelectorSpeaking = AtomicBoolean(false)
    @Volatile
    private var activeSelectorTrack: AudioTrack? = null

    @Volatile
    private var initialized = false

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "preloadSelector" -> {
                val t0 = System.nanoTime()
                selectorExecutor.execute {
                    try {
                        val count = ensureSelectorClipsPreloaded()
                        val ms = (System.nanoTime() - t0) / 1_000_000.0
                        Log.i(TAG, "[SELECTOR-AUDIO] Preloaded $count selector clips in ${"%.2f".format(ms)}ms")
                        mainHandler.post {
                            result.success(mapOf("status" to "preloaded", "clips" to count, "loadMs" to ms))
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "[SELECTOR-AUDIO] Selector preload warning: ${e.message}")
                        mainHandler.post { result.success(mapOf("status" to "skipped")) }
                    }
                }
            }
            "loadSelectorClip" -> {
                val clipId = call.argument<String>("clip") ?: ""
                val filePath = call.argument<String>("path") ?: ""
                if (clipId.isEmpty() || filePath.isEmpty()) {
                    result.error("INVALID_ARGS", "clip and path are required", null)
                    return
                }
                selectorExecutor.execute {
                    try {
                        val file = File(filePath)
                        if (!file.exists()) {
                            Log.w(TAG, "[SELECTOR-AUDIO] File does not exist for $clipId: $filePath")
                            mainHandler.post { result.success(mapOf("status" to "missing_file")) }
                            return@execute
                        }
                        val bytes = file.readBytes()
                        val decoded = parseWav(bytes)
                        clipCache[clipId] = decoded
                        Log.i(TAG, "[SELECTOR-AUDIO] Cached $clipId (${decoded.pcm.size} samples, ${decoded.sampleRate}Hz)")
                        mainHandler.post { result.success(mapOf("status" to "cached", "samples" to decoded.pcm.size)) }
                    } catch (e: Exception) {
                        Log.e(TAG, "[SELECTOR-AUDIO] Failed to load selector clip $clipId from $filePath", e)
                        mainHandler.post { result.error("LOAD_CLIP_FAILED", e.message, null) }
                    }
                }
            }
            "speakSelector" -> {
                val reqStartNs = System.nanoTime()
                val clipId = call.argument<String>("clip") ?: "confirm_bisaya"
                val utteranceId = activeSelectorSeq.incrementAndGet()
                
                // Immediately interrupt previous selector playback without waiting
                stopSelectorPlaybackOnly()

                selectorExecutor.execute {
                    playSelectorConfirmation(utteranceId, clipId, reqStartNs)
                }
                result.success(utteranceId)
            }
            "stopSelector" -> {
                val cancelStartNs = System.nanoTime()
                val prevId = activeSelectorSeq.get()
                activeSelectorSeq.incrementAndGet()
                val wasSpeaking = isSelectorSpeaking.getAndSet(false)
                stopSelectorPlaybackOnly()
                val cancelMs = (System.nanoTime() - cancelStartNs) / 1_000_000.0
                if (wasSpeaking) {
                    Log.i(TAG, "[SELECTOR-AUDIO] Interrupted selector utt=$prevId in ${"%.2f".format(cancelMs)}ms")
                    mainHandler.post {
                        channel?.invokeMethod("onCancel", mapOf("utteranceId" to prevId, "cancelMs" to cancelMs))
                    }
                }
                result.success(1)
            }
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
                                    "sampleRate" to DEFAULT_SAMPLE_RATE,
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
                    Log.w(TAG, "[BISAYA-AUDIO] Refusing playback for unmapped Bisaya text=\"$text\" (no explicit clips)")
                    mainHandler.post {
                        channel?.invokeMethod("onError", mapOf("error" to "unmapped_bisaya_text", "text" to text))
                    }
                    result.success(0)
                    return
                }
                val utteranceId = activeUtteranceSeq.incrementAndGet()
                stopAudioTrackOnly()
                if (clips.size == 1 && clips[0] == "confirm_bisaya") {
                    // Route single confirm_bisaya through dedicated low-latency selector path
                    selectorExecutor.execute {
                        playSelectorConfirmation(utteranceId, "confirm_bisaya", reqStartNs)
                    }
                } else {
                    audioExecutor.execute {
                        playClipSequence(utteranceId, clips, reqStartNs)
                    }
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
                activeSelectorSeq.incrementAndGet()
                stopAudioTrackOnly()
                stopSelectorPlaybackOnly()
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
            norm == "english" || norm == "english." -> listOf("confirm_en")
            norm == "ಕನ್ನಡ" || norm == "ಕನ್ನಡ." -> listOf("confirm_kn")
            norm == "हिन्दी" || norm == "हिन्दी." -> listOf("confirm_hi")
            norm.startsWith("walay kwarta") -> listOf("prompt_empty")
            norm.startsWith("dili klaro") -> listOf("warn_overlap")
            norm.startsWith("nagkasumpaki") -> listOf("warn_conflict")
            norm == "naka-on ang flashlight." || norm == "naka-on ang flashlight" -> listOf("flashlight_on")
            norm == "naka-off ang flashlight." || norm == "naka-off ang flashlight" -> listOf("flashlight_off")
            else -> emptyList()
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
                    clipCache[clipId] = parseWav(bytes)
                }
            }
        }
        initialized = clipCache.isNotEmpty()
        return clipCache.size
    }

    private fun ensureSelectorClipsPreloaded(): Int {
        val loader = FlutterInjector.instance().flutterLoader()
        val assetDirKey = loader.getLookupKeyForAsset(ASSET_DIR).trimEnd('/')
        val selectorClips = listOf("confirm_bisaya", "confirm_en", "confirm_kn", "confirm_hi")
        for (clipId in selectorClips) {
            if (!clipCache.containsKey(clipId)) {
                try {
                    context.assets.open("$assetDirKey/$clipId.wav").use { input ->
                        clipCache[clipId] = parseWav(input.readBytes())
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "[SELECTOR-AUDIO] Could not load $clipId.wav asset: ${e.message}")
                }
            }
        }
        return clipCache.size
    }

    private fun parseWav(wavBytes: ByteArray): DecodedClip {
        var sampleRate = DEFAULT_SAMPLE_RATE
        var channels = 1
        var pos = 12
        var dataStart = 44
        var dataLen = max(0, wavBytes.size - 44)

        while (pos + 8 <= wavBytes.size) {
            val chunkId = String(wavBytes, pos, 4, Charsets.US_ASCII)
            val chunkSize = ByteBuffer.wrap(wavBytes, pos + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            if (chunkId == "fmt " && chunkSize >= 16) {
                channels = ByteBuffer.wrap(wavBytes, pos + 10, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt()
                sampleRate = ByteBuffer.wrap(wavBytes, pos + 12, 4).order(ByteOrder.LITTLE_ENDIAN).int
            } else if (chunkId == "data") {
                dataStart = pos + 8
                dataLen = min(chunkSize, wavBytes.size - dataStart)
                break
            }
            pos += 8 + max(0, chunkSize)
        }

        val sampleCount = dataLen / 2
        val pcm = ShortArray(sampleCount)
        if (dataStart + sampleCount * 2 <= wavBytes.size) {
            ByteBuffer.wrap(wavBytes, dataStart, sampleCount * 2)
                .order(ByteOrder.LITTLE_ENDIAN)
                .asShortBuffer()
                .get(pcm)
        }
        return DecodedClip(pcm, sampleRate, channels)
    }

    /**
     * Isolated static AudioTrack playback for instantaneous selector announcements.
     * Guaranteed head reset, serialized thread-safety, positive playback head advancement check,
     * and immediate cancellation if preempted by a newer volume keypress.
     */
    private fun playSelectorConfirmation(utteranceId: Long, clipId: String, reqStartNs: Long) {
        var track: AudioTrack? = null
        try {
            ensureSelectorClipsPreloaded()
            if (activeSelectorSeq.get() != utteranceId) return

            val clip = clipCache[clipId] ?: run {
                Log.w(TAG, "[SELECTOR-AUDIO] Clip not in cache: $clipId")
                mainHandler.post {
                    channel?.invokeMethod("onError", mapOf("utteranceId" to utteranceId, "error" to "clip_not_found"))
                }
                return
            }

            if (clip.pcm.isEmpty()) {
                mainHandler.post {
                    channel?.invokeMethod("onDone", mapOf("utteranceId" to utteranceId, "audioDurMs" to 0.0))
                }
                return
            }

            val bufBytes = clip.pcm.size * 2
            val channelMask = if (clip.channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO

            synchronized(selectorLock) {
                if (activeSelectorSeq.get() != utteranceId) return

                // Stop and release previous track
                activeSelectorTrack?.let { prev ->
                    try {
                        if (prev.playState == AudioTrack.PLAYSTATE_PLAYING) {
                            prev.pause()
                            prev.flush()
                        }
                        prev.stop()
                    } catch (_: Exception) {}
                    try { prev.release() } catch (_: Exception) {}
                }
                activeSelectorTrack = null

                // Build isolated fresh static track
                track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build(),
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(clip.sampleRate)
                            .setChannelMask(channelMask)
                            .build(),
                    )
                    .setBufferSizeInBytes(bufBytes)
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()

                track?.write(clip.pcm, 0, clip.pcm.size)
                activeSelectorTrack = track
            }

            if (activeSelectorSeq.get() != utteranceId) {
                releaseTrackSafe(track)
                return
            }

            isSelectorSpeaking.set(true)
            track?.play()

            val onsetMs = (System.nanoTime() - reqStartNs) / 1_000_000.0

            // Verify positive playback head advancement
            var headAdv = false
            val startWait = System.currentTimeMillis()
            while (System.currentTimeMillis() - startWait < 80) {
                val pos = track?.playbackHeadPosition ?: 0
                if (pos > 0) {
                    headAdv = true
                    break
                }
                Thread.sleep(2)
            }

            Log.i(
                TAG,
                "[SELECTOR-AUDIO] Started utt=$utteranceId clip=$clipId onsetMs=${"%.2f".format(onsetMs)} " +
                    "headAdv=$headAdv head=${track?.playbackHeadPosition}",
            )
            mainHandler.post {
                channel?.invokeMethod("onStart", mapOf("utteranceId" to utteranceId, "onsetMs" to onsetMs, "headAdv" to headAdv))
            }

            val durMs = (clip.pcm.size * 1000L) / (clip.sampleRate * max(1, clip.channels))
            val deadline = System.currentTimeMillis() + durMs + 40L

            while (System.currentTimeMillis() < deadline && activeSelectorSeq.get() == utteranceId) {
                Thread.sleep(10)
            }

            if (activeSelectorSeq.get() == utteranceId) {
                isSelectorSpeaking.set(false)
                synchronized(selectorLock) {
                    if (activeSelectorTrack === track) {
                        try { track?.stop() } catch (_: Exception) {}
                        try { track?.release() } catch (_: Exception) {}
                        activeSelectorTrack = null
                    }
                }
                Log.i(TAG, "[SELECTOR-AUDIO] Completed utt=$utteranceId clip=$clipId durMs=$durMs")
                mainHandler.post {
                    channel?.invokeMethod(
                        "onDone",
                        mapOf("utteranceId" to utteranceId, "onsetMs" to onsetMs, "audioDurMs" to durMs.toDouble()),
                    )
                }
            } else {
                // Cancelled / preempted
                releaseTrackSafe(track)
            }
        } catch (e: Exception) {
            isSelectorSpeaking.set(false)
            releaseTrackSafe(track)
            Log.e(TAG, "[SELECTOR-AUDIO] Error during selector playback utt=$utteranceId clip=$clipId", e)
            mainHandler.post {
                channel?.invokeMethod("onError", mapOf("utteranceId" to utteranceId, "error" to (e.message ?: "unknown")))
            }
        }
    }

    private fun releaseTrackSafe(track: AudioTrack?) {
        if (track == null) return
        synchronized(selectorLock) {
            if (activeSelectorTrack === track) {
                activeSelectorTrack = null
            }
        }
        try {
            if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                track.pause()
                track.flush()
            }
            track.stop()
        } catch (_: Exception) {}
        try { track.release() } catch (_: Exception) {}
    }

    private fun stopSelectorPlaybackOnly() {
        synchronized(selectorLock) {
            activeSelectorTrack?.let { track ->
                try {
                    if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                        track.pause()
                        track.flush()
                    }
                    track.stop()
                } catch (_: Exception) {}
                try { track.release() } catch (_: Exception) {}
            }
            activeSelectorTrack = null
        }
    }

    private fun playClipSequence(utteranceId: Long, clips: List<String>, reqStartNs: Long) {
        try {
            ensureClipAssetsLoaded()
            if (activeUtteranceSeq.get() != utteranceId) return

            val arrays = ArrayList<ShortArray>(clips.size)
            var totalSamples = 0
            for (i in clips.indices) {
                val clip = clipCache[clips[i]] ?: continue
                arrays.add(clip.pcm)
                totalSamples += clip.pcm.size
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
                DEFAULT_SAMPLE_RATE,
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
                        .setSampleRate(DEFAULT_SAMPLE_RATE)
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
                val audioDurMs = (combined.size * 1000.0) / DEFAULT_SAMPLE_RATE
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
