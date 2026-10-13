#include "AudioBridgeRealtime.h"
#include <stdatomic.h>
#include <stdlib.h>
struct ABStartGate { _Atomic bool cancelled; _Atomic uint32_t references; };
ABStartGate *ABStartGateCreate(void) {
    ABStartGate *gate = calloc(1, sizeof(*gate));
    if (!gate) return NULL;
    atomic_init(&gate->cancelled, false); atomic_init(&gate->references, 1);
    if (!atomic_is_lock_free(&gate->cancelled)) { free(gate); return NULL; }
    return gate;
}
void ABStartGateRetain(ABStartGate *gate) { if (gate) atomic_fetch_add_explicit(&gate->references, 1, memory_order_relaxed); }
void ABStartGateRelease(ABStartGate *gate) {
    if (gate && atomic_fetch_sub_explicit(&gate->references, 1, memory_order_acq_rel) == 1) free(gate);
}
void ABStartGateCancel(ABStartGate *gate) { if (gate) atomic_store_explicit(&gate->cancelled, true, memory_order_release); }
bool ABStartGateCancelled(const ABStartGate *gate) { return gate && atomic_load_explicit(&gate->cancelled, memory_order_acquire); }
