#ifndef AB_AU_TRANSPORT_H
#define AB_AU_TRANSPORT_H
#include <stdbool.h>
#include <stdint.h>
typedef struct ABAUTransport ABAUTransport;
typedef struct {
    uint32_t inputFrames, outputFrames;
    uint64_t heartbeat, processedFrames;
    int32_t fault;
    bool ready, stopped;
    float latencySeconds;
} ABAUTransportMetrics;
ABAUTransport *ABAUTransportCreate(const char *name, uint32_t capacity);
ABAUTransport *ABAUTransportOpen(const char *name);
void ABAUTransportUnlink(ABAUTransport *transport);
void ABAUTransportClose(ABAUTransport *transport);
void ABAUTransportShutdown(ABAUTransport *transport);
void ABAUTransportReady(ABAUTransport *transport, float latency);
void ABAUTransportFault(ABAUTransport *transport, int32_t fault);
void ABAUTransportHeartbeat(ABAUTransport *transport);
ABAUTransportMetrics ABAUTransportSnapshot(const ABAUTransport *transport);
uint32_t ABAUCaptureWrite(ABAUTransport *transport, const float *samples, uint32_t frames);
uint32_t ABAUOutputRead(ABAUTransport *transport, float *samples, uint32_t frames);
uint32_t ABAUWorkerRead(ABAUTransport *transport, float *samples, uint32_t frames);
uint32_t ABAUWorkerWrite(ABAUTransport *transport, const float *samples, uint32_t frames);
uint32_t ABAUWorkerSpace(const ABAUTransport *transport);
#endif
