# AU editor crash investigation — 2026-10-11

While implementing ADR-002, the user reported "AU editor quits unexpectedly" and the existing callback/buffer timeout. Current effects are Analog Obsession and Everclean, not TDR Nova.

Read-only DiagnosticReports inspection found three earlier AudioBridgeAUWorker crashes at 21:24:21/27/37, all EXC_BAD_ACCESS at address 0 in TDR Nova while `AUParameter stringFromValue:` was invoked by the generic `ParameterControl` layout. These historical reports do **not** explain the current Analog Obsession/Everclean failure. A read-only process check found AudioBridge running from `/private/tmp/AudioBridge-phase2/AudioBridge.app`; no render helper was active at inspection. No process was restarted or plugin instantiated by automation.

The generic editor now uses host numeric formatting instead of calling plugin parameter formatters with a null pointer. Generic controls are shown only after the native-view request resolves, preventing a transient generic editor during native loading. This removes the evidenced crash path, without claiming the current plugins are fixed. Native editors continue using the plugin's own UI.

`make build` passed after this change and the routing backend (3.70 seconds), and after status UI integration (4.18 seconds). Tests, plugin execution, app launch and editor appearance were not run. Current plugin runtime acceptance remains pending; requested diagnostics/build number and exact effect identity are needed for the reported failure.

The accompanying engine update preserves an existing AU fault instead of replacing it with the generic callback timeout. Startup failures report missing input/output callbacks or processed buffer plus captured, AU-processed and queued frame counts. This is a diagnostic correction, not evidence that permission or hardware callback delivery is repaired. Recovery and login remain later phase work.
