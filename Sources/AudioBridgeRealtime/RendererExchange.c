#include "AUTransport.h"
#include <stdatomic.h>
#include <stdlib.h>

// Helper-local borrowed pointers. Main thread retains old and pending owners
// until adoption is acknowledged after the previous render block completes.
struct ABRendererExchange { _Atomic(void *) pending, adopted; };
ABRendererExchange *ABRendererExchangeCreate(void) {
    ABRendererExchange *slot = calloc(1, sizeof(*slot));
    if (!slot) return NULL;
    atomic_init(&slot->pending, NULL); atomic_init(&slot->adopted, NULL);
    if (!atomic_is_lock_free(&slot->pending) || !atomic_is_lock_free(&slot->adopted)) { free(slot); return NULL; }
    return slot;
}
void ABRendererExchangeDestroy(ABRendererExchange *slot) { free(slot); }
bool ABRendererExchangePublish(ABRendererExchange *slot, void *renderer) {
    void *empty = NULL;
    return renderer && atomic_compare_exchange_strong_explicit(&slot->pending, &empty, renderer,
        memory_order_release, memory_order_relaxed);
}
void *ABRendererExchangeTake(ABRendererExchange *slot) {
    return atomic_exchange_explicit(&slot->pending, NULL, memory_order_acquire);
}
void ABRendererExchangeAcknowledge(ABRendererExchange *slot, void *renderer) {
    atomic_store_explicit(&slot->adopted, renderer, memory_order_release);
}
bool ABRendererExchangeAdopted(const ABRendererExchange *slot, void *renderer) {
    return atomic_load_explicit(&slot->adopted, memory_order_acquire) == renderer;
}
