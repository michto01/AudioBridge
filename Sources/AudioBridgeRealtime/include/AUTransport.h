#ifndef AB_AU_TRANSPORT_H
#define AB_AU_TRANSPORT_H
#include <stdbool.h>
#include <stdint.h>
typedef struct ABAUTransport ABAUTransport;
uint32_t ABAUTransportProtocolVersion(void);
typedef struct { uint32_t inputFrames, outputFrames, inFlightFrames, pendingFrames; } ABAUQueueMetrics;
// Minimal callback snapshot; omit UI/timing counters from audio hot paths.
// pendingFrames conserves accepted capture minus consumed/discarded source.
ABAUQueueMetrics ABAUTransportQueues(const ABAUTransport *transport);
bool ABAUTransportStopped(const ABAUTransport *transport);
uint64_t ABAUTransportProcessedFrames(const ABAUTransport *transport);
typedef struct {
    uint32_t inputFrames, outputFrames, pendingFrames;
    uint64_t heartbeat, processedFrames;
    int32_t fault;
    bool ready, stopped, bypassed, effectsProcessingEnabled;
    float latencySeconds;
    uint32_t inFlightFrames;
    uint64_t renderBlocks, renderNanoseconds, lastRenderNanoseconds, maxRenderNanoseconds;
    uint64_t blockBudgetNanoseconds, renderOverBudgetBlocks;
    uint64_t workerWaits, workerLateWakeups, maxWorkerWakeLatenessNanoseconds;
} ABAUTransportMetrics;
ABAUTransport *ABAUTransportCreate(const char *name, uint32_t capacity);
const char *ABAUTransportLastError(void);
ABAUTransport *ABAUTransportOpen(const char *name);
void ABAUTransportUnlink(ABAUTransport *transport);
void ABAUTransportClose(ABAUTransport *transport);
void ABAUTransportShutdown(ABAUTransport *transport);
void ABAUTransportReady(ABAUTransport *transport, float latency);
void ABAUTransportSetLatency(ABAUTransport *transport, float latency);
void ABAUTransportSetBypass(ABAUTransport *transport, bool bypass);
bool ABAUTransportBypassed(const ABAUTransport *transport);
void ABAUTransportSetEffectsProcessingEnabled(ABAUTransport *transport, bool enabled);
bool ABAUTransportEffectsProcessingEnabled(const ABAUTransport *transport);
void ABAUTransportFault(ABAUTransport *transport, int32_t fault);
void ABAUTransportHeartbeat(ABAUTransport *transport);
ABAUTransportMetrics ABAUTransportSnapshot(const ABAUTransport *transport);
// Helper worker only; wall processing time is separate from signal latency.
uint64_t ABAUTransportBeginBlock(ABAUTransport *transport, uint32_t frames);
void ABAUTransportEndBlock(ABAUTransport *transport, uint64_t start);
// Helper only. Configure before readiness; polling waits never run in HAL callbacks.
void ABAUTransportConfigureTiming(ABAUTransport *transport, uint64_t blockBudgetNanoseconds);
void ABAUTransportWorkerWait(ABAUTransport *transport, uint32_t microseconds);
// Deterministic accounting entry points allow tests without sleeping/plugins.
void ABAUTransportRecordWorkerWait(ABAUTransport *transport, uint64_t requestedNanoseconds, uint64_t elapsedNanoseconds);
void ABAUTransportRecordRenderDuration(ABAUTransport *transport, uint64_t durationNanoseconds);
uint32_t ABAUCaptureWrite(ABAUTransport *transport, const float *samples, uint32_t frames);
uint32_t ABAUOutputRead(ABAUTransport *transport, float *samples, uint32_t frames);
uint32_t ABAUWorkerRead(ABAUTransport *transport, float *samples, uint32_t frames);
uint32_t ABAUWorkerWrite(ABAUTransport *transport, const float *samples, uint32_t frames);
uint32_t ABAUWorkerSpace(const ABAUTransport *transport);
#endif
