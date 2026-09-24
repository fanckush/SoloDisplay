# Issue #9: WindowServer watchdog stack

Analyzed 2026-09-23 from the reporter's `apple_diagnose.txt`. This file contains a
WindowServer watchdog report with a system-wide stackshot and a hardware summary;
it is not a complete sysdiagnose archive with historical driver/firmware logs.
The original diagnostic is not copied into the repository.

## Finding

At capture, WindowServer's main thread is waiting inside a synchronous display
coprocessor (DCP) RPC for `get_digital_out_state`, reached while processing a
display connection and updating its power state. The watchdog reports that the
main thread has failed to check in for 40 seconds.

This locates the observed stall in Apple's display stack. It does not establish
why the DCP transaction fails to complete, which physical display is being queried,
or that every possible restoration sequence must fail on M3.

## Matched binaries

The reporter used Mac15,12 (M3 Air), macOS 27.0 build 26A428. Matching locally
installed binaries were used, verified by UUID rather than OS version alone:

| Image | Diagnostic image index | UUID |
| --- | --- | --- |
| dyld shared cache | 14 | ea2c265e-297c-39c2-8646-7d8a2dff648a |
| kernel.release.t8122 | 0 | 237425c9-b6ec-3159-8cf1-a190ae05cb47 |
| IOMobileGraphicsFamily-DCP | 6 | b429f541-c197-3fa1-aa56-9b4dc0d09001 |
| IOMobileGraphicsFamily | 7 | 23a8f9b7-6a83-3f47-92ea-8ce6ed898987 |

Shared-cache addresses were resolved in a separate framework-loading inspector.
Kernel extensions were read from a temporary, unpacked copy of the installed
kernel collection. Kernel image type `T` offsets refer to `__TEXT_EXEC`, not the
Mach-O header; using the header yields incorrect symbols. No debugger was attached
to WindowServer and no display changes were issued.

## Main-thread stack

WindowServer PID 453, thread 4207 (`ws_main_thread`), state `TH_WAIT | TH_UNINT`.
Selected frames below are in caller-to-callee order; intermediate wrappers are
omitted. Names and displacements come from the matching binaries.

```text
SkyLight: CAWSManager::inject_hotplug(bool, int, unsigned int) + 140
  reconfigure_callback_process_hotplug_event(...) + 728
  CAWSManager::process_deferred_hotplug_events() + 132
  [deferred hotplug block] + 3256
  CAWSManager::process_hotplug_event(...) + 448
  SLCADisplay::process_display_connect(unsigned int) + 588
  SLCADisplay::set_ca_display_enabled(bool) + 156
QuartzCore: -[CAWindowServerDisplay setEnabled:] + 188
  Server::set_display_state(...) + 808
  IOMFBDisplay::update_power_state_locked(bool) + 576
IOMobileFramebuffer: kern_GetDigitalOutState + 68
IOKit: IOConnectCallScalarMethod + 80
  io_connect_method + 520
[kernel transition]
IOMobileGraphicsFamily: IOMobileFramebufferUserClient::s_get_digital_out_state(...) + 40
  IOMobileFramebufferUserClient::get_digital_out_state(unsigned int*) + 72
IOMobileGraphicsFamily-DCP: IOMobileFramebufferAP::get_digital_out_state(unsigned int*) + 148
  DCPLink::rpc(...) + 180
  AppleDCPLinkService::rpc(...) + 72
  rpc_caller(rpc_args_t*) + 612
  [IOCommandGate::runAction / link_cond_action_run wrappers]
  rpc_caller_gated(void*) + 672
kernel: IOEventSource::sleepGate(void*, unsigned int) + 140
  IOWorkLoop::sleepGate(void*, unsigned int) + 172
  lck_mtx_sleep + 212
```

Useful raw offsets for independent verification:

| Image | Offset | Symbol and displacement |
| --- | --- | --- |
| shared cache | 0xb3a3104 | update_power_state_locked + 576 |
| shared cache | 0xff05514 | kern_GetDigitalOutState + 68 |
| IOMobileGraphicsFamily-DCP | 0x18558 | get_digital_out_state + 148 |
| IOMobileGraphicsFamily-DCP | 0x1d8cc | rpc_caller_gated + 672 |
| kernel | 0x8758f0 | IOWorkLoop::sleepGate + 172 |

Disassembly adds two details beyond the function names:

- `get_digital_out_state` sends RPC tag `0x41343134` (`A414`).
- `rpc_caller_gated` calls `link_send_message_priv` at +556. Its successful path
  reaches the sleep call whose return address is +672, the sampled frame. The
  surrounding loop also services nested RPC callbacks. Thus this is a wait within
  a sent DCP transaction, not merely contention while entering the command gate.

The report does not contain DCP firmware execution state or the RPC's object
arguments. It cannot distinguish a missing reply, a callback dependency, or another
firmware/driver state problem. One sample also does not prove that the thread spent
the entire watchdog interval at exactly this instruction.

## Correlation with SoloDisplay diagnostics

All times below are UTC on 2026-09-22. The watchdog report uses local time +0200.

| Time | Event |
| --- | --- |
| 07:06:01.024 | SoloDisplay starts disabling the panel |
| 07:06:01.620 | Disable worker succeeds, 596 ms |
| 07:07:29.226 | User selects all monitors; enable worker is dispatched |
| 07:08:17.096 | WindowServer watchdog stackshot, about 47.870 s after dispatch |
| 07:08:18.606 | Guardian begins restoration with reason `appGone` |

The guardian recovery retries happen after this captured stall and cannot explain
its onset.

SoloDisplay PID 33759's main thread and child PID 33888's cooperative thread both
wait in `SLSessionCopyCurrentDictionary`, through
`SLSCopySessionPropertiesTemporaryBridge`. Their turnstile records explicitly name
WindowServer PID 453 as the process they await. The child's lifetime aligns with
guardian startup; it is not a newly launched restore worker. No separate display
worker is present in the capture; this does not establish whether it returned or
was killed earlier.

This matches the synchronous `CGSessionCopyCurrentDictionary()` call in
`Sources/SoloDisplayPlatform/DisplayObserver.swift`. These observed waits explain
why the app and guardian also stop progressing when WindowServer is stuck. Moving
or isolating these reads could improve app responsiveness, but would not by itself
complete WindowServer's outstanding DCP transaction. Exact SoloDisplay instruction
offsets were not symbolicated because the available local app dSYM has a different
UUID from the reporter's executable.

## Consequences for the experiment

The blocked clamshell probe still cannot test this behavior: its entitlement failure
occurs before any display-state request is sent. Repeating that build adds no
evidence about this DCP stall.

The useful next investigation is the reattachment/power-state sequence around
restoration. A physical external-disconnect versus connected-restore comparison,
if not already tested, could help establish whether an active external connection
is necessary to trigger the stall. That remains a proposed hardware experiment,
not a demonstrated workaround or a reason to ship another DMG yet.

Physical clamshell operation can work while this software reattachment path fails:
different transitions can reach the same driver in different states. This report
supports investigating that distinction; it does not prove a hardware limitation
or a fix.
