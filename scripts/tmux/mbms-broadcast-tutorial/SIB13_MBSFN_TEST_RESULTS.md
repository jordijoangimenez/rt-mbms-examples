# SIB13/MBSFN Parameter Test Campaign — Results

**Update 2026-07-15 (fix pass)**: a follow-up pass investigated and live-verified fixes for
several of the findings below. See "Fix pass outcomes" after the Summary table for what
changed, what got corrected (Finding 5 turned out not to be a real bug), and what's still
open. The findings below are left as originally written (the campaign's as-found record);
the fix pass section explains what's since changed.

**Date**: 2026-07-15
**Scope**: systematic one-dimension-at-a-time verification of SCS, MCS, time interleaving,
CAS muting, `pmch_bandwidth`, and `n_prb`, against the `n_prb=25` baseline resolved earlier
this session (see `rt-mbms-modem/KNOWN_ISSUES.md`: `-O3` build fix, BLER 0.0).
**Full working log** (chronological, with all raw evidence as it was found): the approved
plan at `~/.claude/plans/sequential-noodling-newt.md`, section "Results log".
**Helper script**: `test_sib_matrix.py` in this directory; per-phase raw output in
`*_phase_report.md` alongside it.
**Config change kept permanently**: `enb_baseline.conf` now sets `rrc_level = warning`
(previously RRC logged only at `error`, via the global `all_level=error`). This was added
as a debugging aid but kept deliberately: the RRC layer's own `logger.warning()` calls
(clamp explanations, infeasibility warnings) are genuinely useful to any operator running
this rig, not just to this investigation, and were previously invisible.

## Summary by phase

| Phase | Dimension | Result |
|---|---|---|
| 1 | SCS (15, 7.5, 2.5, 1.25kHz) | All PASS, BLER 0.0 |
| 2 | MCS (2, 9, 10, 16, 17, 28, 22-table2) | All PASS; MCS=28 clamp discrepancy corrected post-hoc, was a misdiagnosis (see fix pass) |
| 3 | Time interleaving (N,M up to 16,32) | Fixed and confirmed genuinely functional (real bug: OTA switch had no case for divisor-clamped values) — works given compatible scheduling parameters; safely/honestly disables otherwise (Finding 1) |
| 4 | CAS muting (k_cas,n_cas up to 32,16) | **FIXED 2026-07-17**: BLER inflation traced to a spurious equalized-power anomaly (~14% of muted sf=0 occasions) being wrongly counted as decode failures; validity gate extended, live-verified MCH BLER 0.82-1.00 → 0.0. Underlying trigger (one specific worker-pool instance, ~14% probability) still not fully root-caused, but no longer affects correctness or reported stats — Finding 3 |
| 5 | `pmch_bandwidth` (30, 35, 40 @ n_prb=25) | Root cause found and fixed (RX/TX pmch.c divergence + internal-vs-caller PRB count mismatch); substantially improved (MCCH mostly succeeds, MTCH now attempted) but a separate timing/blocking issue still causes most MTCH decodes to fail — Finding 4 |
| 5b | `n_prb` (6, 15, 25, 50, 75, 100) | 6, 15 crash (Finding 6, decimator CPU ceiling, unresolved); 25, 50, **75, 100 all clean (Finding 7 fixed 2026-07-18** — config-only: `base_srate`/`native_srate`/cell-search `-b` flag must all match the true rate for the configured `n_prb`, not just the bridge's own decimation ratio) |
| 6 | TI + muting interaction | **PASS (2026-07-18)**: run after Findings 1 and 3 were both fixed; TI(2,4) genuinely combines correctly alongside muting(8,4) and muting(16,8) — no new interaction bug (originally-planned M=8/16 values are structurally infeasible on this rig regardless of muting, see write-up) |
| 7 (added post-campaign) | Frequency interleaving (Rel-19 `pmch-TFI-Config`, on/off flag) | PASS — signaling and functional, BLER 0.0 (added 2026-07-15 after review found it missing from the original matrix) |

**Net result: 7 real, previously-undocumented issues found** (9 counting TI's three
sub-symptoms separately), none of them wire-format/protocol-compliance bugs — every one is
either (a) a live-reconfiguration path that doesn't actually reach the broadcast content
despite being accepted, or (b) a resource/scaling limit of the current ZMQ bridge
implementation. Two additional, pre-existing gaps were identified during planning (before
any live testing this campaign) and are listed separately at the end — they were scoped,
not re-verified live here.

## Fix pass outcomes (2026-07-15)

### Finding 4 (`pmch_bandwidth` propagation) — FIXED, root cause was different from the original guess

The original writeup guessed a missing value-tag bump or a repack block not re-executing.
Neither was right. Live-instrumented testing (temporary `rrc_level=debug` + a diagnostic
build) found the real cause in five minutes of testing what months of static reading of the
*other* candidates couldn't resolve: `rrc::reconfigure_embms()` had **a second, separate
clamp** — `if (pmch_bandwidth > cfg.cell.nof_prb) { pmch_bandwidth = cfg.cell.nof_prb; }` —
that silently rewrote every legal value (30, 35, 40) down to `nof_prb` (25 in this campaign)
whenever `nof_prb < 40`. `configure_mbsfn_sibs()`'s packer switch (only cases for 30/35/40)
then always saw the clamped-to-25 value, matched no case, and emitted no r17 extension —
exactly the "accepted but never broadcast" symptom this campaign observed. The clamp
directly contradicted the field's own purpose (pmch-Bandwidth-r17 signals coverage *wider*
than the base cell — see `enb_cfg_parser.cc`'s own comment, "may legitimately exceed
enb.n_prb") and was pure redundant harm given the validation one line above it already
constrains the value to `{0,30,35,40}`.

**Removing that clamp did make the signaling correct** (`pmch_bandwidth=30` decoded
correctly for the first time) — but exposed a **second, deeper, and more serious problem**:
functional PMCH decode broke completely (BLER 1.0) the moment the wider bandwidth was
actually signaled and attempted. Tracing further: `mac::write_mcch()` has its *own*,
separate clamp on `cell_config[0].cell.mbsfn_prb`, justified by an explicit comment about
preventing "overflow [of] the PMCH PRB-sized buffers." That clamp was correctly left in
place (touching it without verifying PHY resource-grid sizing would risk a real
buffer-overflow, not just a signaling nitpick) — meaning MAC/PHY still schedule and
transmit based on `nof_prb`, while RRC would have told receivers to expect a wider PMCH than
what's actually sent. **Conclusion: PMCH wider than the cell's own `nof_prb` is not actually
implemented at the PHY/resource-grid level in this codebase — only the RRC/SIB13 signaling
scaffolding exists.** The clamp was restored, with an honest warning explaining why
("extended PMCH coverage... is not implemented at the PHY level in this build... clamping
so the eNB doesn't signal a capability it cannot deliver") instead of the old, uninformative
"exceeds cell nof_prb" wording. A real fix needs PHY-level resource-grid/softbuffer support
for `mbsfn_prb > nof_prb` — a resource-grid-sizing change, out of scope for this pass (real
real-time DSP allocation code, not a validation-logic fix).

**Files changed**: `rt-mbms-tx/srsenb/src/stack/rrc/rrc.cc` (clamp restored with an honest
comment/warning citing this investigation).

**Verification note**: only `pmch_bandwidth=30` was re-tested live while root-causing this.
`35` and `40` were re-tested afterward (not just assumed identical): both confirmed the same
safe fallback (correctly clamped, no propagation, BLER 0.0) — consistent, since all three
exceed `nof_prb=25` the same way and hit the identical clamp.

### Finding 4, continued (same day): the "not implemented at the PHY level" conclusion above was wrong — found and fixed the real bug, substantial but incomplete progress

Re-opened this after being pushed to actually fix it rather than leave it disabled.
`phy_common.c`'s own `srsran_cell_isvalid()` comment states outright that downlink buffers
were *already* updated to size from `max(nof_prb, mbsfn_prb)` — confirmed by reading
`enb_dl.c`, `pmch.c`, `chest_dl.c`, and `refsignal_dl.c` on the TX side: all consistently use
`SRSRAN_MAX(nof_prb, mbsfn_prb)` for stride/buffer sizing. Wideband PMCH support genuinely
exists at the PHY level; the "not implemented" conclusion in the section above was reached by
checking the RRC/MAC clamps without ever checking whether the PHY layer had already been
fixed independently. Two real bugs, once actually traced:

1. **RX-side TX/RX divergence**: `rt-mbms-modem`'s copy of `pmch.c` (a separate copy of the
   same shared library file) was missing the exact stride fix already present in
   `rt-mbms-tx`'s copy — using plain `nof_prb` instead of `SRSRAN_MAX(nof_prb, mbsfn_prb)` as
   the buffer stride in `pmch_cp()`, corrupting every symbol beyond the first whenever
   `mbsfn_prb > nof_prb`. Fixed to match the TX side.
2. **The actual root cause of MCCH's 100% decode failure**: `pmch_cp()` (and its `pmch_get`/
   `pmch_put` wrappers, in *both* repos' copies) computed how many PRBs' worth of REs to
   extract/place internally from `q->cell.mbsfn_prb`, rather than from the value the caller
   (`srsran_pmch_decode`/`encode`) had already computed into `cfg->pdsch_cfg.grant.nof_prb`
   and was independently checking the extracted count against
   (`"PMCH 1 extract symbols error expecting %d symbols but got %d"`). Whenever these two
   independently-derived values disagreed, decode failed outright — confirmed via
   `subframe_log` data showing `SF_EVENT_MCCH`/`SF_STATUS_FAIL` on 100% of MCCH occasions
   once `pmch_bandwidth` signaled a wider MTCH allocation. Fixed by threading an explicit
   `prb_count` parameter through `pmch_cp`/`pmch_put`/`pmch_get` in both repos, so extraction
   always matches exactly what the caller's `cfg` says, eliminating the possibility of the
   two ever disagreeing.

**Also fixed**: three dashboard-diagnostic-only functions in `CasFrameProcessor.cpp`
(`cir_values()`, `ce_values()`, `composition_grid()`, feeding the CAS Composition/CIR/CE
visualizations) were sized from plain `nof_prb`, inconsistent with the actual sample stream's
width once `mbsfn_prb > nof_prb` — fixed to the same `SRSRAN_MAX` pattern. Confirmed via
`srsran_ue_dl_set_cell()` (the actual decode path, shared by CAS and MBSFN processors) that
the *real* CAS decode was never affected — it already correctly samples at the wider rate
and extracts only the narrower CAS-relevant region, the same "sample wide, extract narrow"
pattern standard LTE uses for PSS/SSS/PBCH within a wider carrier. Confirmed live: CAS decode
succeeds throughout (125/125 in one sample window) regardless of `pmch_bandwidth`.

**Result after both fixes**: substantial, measurable improvement, confirmed via
`subframe_log` — MCCH went from 100% failure to a majority-success rate (e.g. 5 OK / 3 FAIL
in one sample), and MTCH data decode was attempted at all for the first time (previously
zero attempts, since the schedule was never successfully learned). **Not fully fixed**: MTCH
data decode still mostly fails (e.g. 4 OK / 2259 FAIL in the same sample). Traced this to a
separate, still-open issue: `SdrReader`'s `SYNC_OFFSET_DIAG SLOWCALL` fires persistently
(11-22ms against a 1ms budget) once the sample rate is raised to accommodate the wider PMCH
(confirmed via `pidstat -t`: near-zero CPU on every thread during these overruns, so the
read thread is blocked/waiting, not compute-bound — ruling out a decimator-style CPU
ceiling). Also ruled out: the eNB falling behind in real-time TX (zero `tx time is X ms in
the past` messages, unlike Finding 7's n_prb=75/100 mechanism). Root cause of this remaining
blocking behavior not found — needs further investigation into the bridge's buffering/timing
at the higher (15.36 Msps, ratio=1) rate once the SDR dynamically retunes mid-operation to
accommodate a signaled `pmch_bandwidth`.

**Files changed**: `rt-mbms-modem/lib/srsran/lib/src/phy/phch/pmch.c` and
`rt-mbms-tx/lib/src/phy/phch/pmch.c` (both copies: stride fix, `prb_count` parameter
threading), `rt-mbms-modem/src/CasFrameProcessor.cpp` (diagnostic sizing fixes),
`rt-mbms-tx/srsenb/src/stack/rrc/rrc.cc` and `rt-mbms-tx/srsenb/src/stack/mac/mac.cc`
(both `>nof_prb` clamps removed again, this time with the actual mechanism understood rather
than reverted out of caution).

### Finding 5 (MCS=28 clamp discrepancy) — NOT a real bug; original finding was a misdiagnosis

Live-instrumented re-testing (temporary diagnostic prints at every step of the clamp/pack
chain) could not reproduce the original "log says 24, decoded is 26" discrepancy.
`clamp_pmch_mcs_to_feasible()` (the function that decides the feasible MCS) is a small,
pure, deterministic function of exactly its three parameters (`requested_mcs`, `nof_prb`,
`use_mcs_table2`) plus one hardcoded constant — verified by reading its full body. Called
today with the campaign's own inputs (26, 25 PRB, table1), it correctly and consistently
returns **26** (not 24) — i.e. MCS=26 genuinely *is* feasible at 25 PRB, and the value the
modem decoded (26) was the objectively correct answer all along. The original "clamping to
MCS=24" log line, found via `grep` much earlier the same day, most likely reflected some
other, untracked state at that specific moment (the function's determinism rules out the
log and the live test disagreeing under identical inputs) — this was not independently
re-verified before being written up as a bug, which in hindsight it should have been.

**What did get changed, and is being kept as a genuine (if unrelated) improvement**:
`rrc::pack_mcch()` used to independently recompute the exact same MCS clamp from
`cfg.mbms_mcs` rather than receiving the already-computed value from its only caller — two
copies of the same logic that happened to always agree here, but were one accidental future
edit away from silently diverging (the internal `mcch_t` struct and the OTA ASN.1 message
disagreeing on MCS). `pack_mcch()` now takes the clamped `mbms_mcs` as a parameter instead
of recomputing it. This is a code-hygiene fix, not a bug fix — no observed behavior changed
because of it.

**Files changed**: `rt-mbms-tx/srsenb/src/stack/rrc/rrc.cc`,
`rt-mbms-tx/srsenb/hdr/stack/rrc/rrc.h` (`pack_mcch()` signature).

### Spec-compliance gap fixed: `systemInfoValueTag` never bumped on live eMBMS reconfigure

Unrelated to Findings 4/5 turning out to have other causes, but found while investigating
them: `regenerate_si()` (the ETWS alert code path) bumps `cfg.sib1.sys_info_value_tag_r14`
before rebuilding SI content; `configure_mbsfn_sibs()` (the eMBMS live-reconfigure path)
rebuilds the same SI content but never bumped this tag. Per TS 36.331 §5.2.1.2, this tag is
the mechanism a spec-compliant UE uses to detect that broadcast SI changed and should be
re-acquired. This specific test rig's modem doesn't gate re-parsing on the tag (confirmed:
it only logs a warning on change, `Rrc.cpp:501-507`), so this wasn't the cause of any
observed test failure — but it's a real gap for any spec-compliant receiver. Fixed:
`configure_mbsfn_sibs()` now bumps the tag the same way `regenerate_si()` does.

### Finding 7 (`n_prb`∈{75,100} native-rate ceiling) — first pass: mitigated only (fails loudly instead of silently; actually fixed later, see below)

Building real bidirectional dynamic resampling (the actual fix) is a substantial
architecture change spanning both the TX and RX sides of `soapy-zmq-bridge` (confirmed: the
eNB's *own* TX `device_args` also hardcodes `base_srate=15.36e6` — this is not an RX-only
gap) and touches real-time DSP code that's already been the site of multiple delicate bugs
this session. Out of scope for this pass. Instead, `ZmqRxDevice.cpp` now detects
`sample_rate_ > native_sample_rate_` (previously silently ignored, falling through to
`ratio=1`) and logs a clear, rate-limited `SOAPY_SDR_ERROR` explaining the mismatch and what
to do about it, rather than leaving operators to puzzle over a growing "tx time in the past"
drift and a MIB that never decodes.

**Files changed**: `soapy-zmq-bridge/ZmqRxDevice.cpp` (rebuilt, `libzmqrxSupport.so`
redeployed).

### Finding 7, actually fixed (2026-07-18): both n_prb=75 and n_prb=100 now genuinely work — config-only, no code changes

The "substantial architecture change" framing above turned out to be wrong once actually
investigated: real bidirectional resampling was never needed. The eNB's own TX rate is
*also* just a hardcoded config literal (`enb_baseline.conf`'s `device_args=...,base_srate=
15.36e6,...`), completely decoupled from `n_prb` — confirmed via `txrx.cc:93-99`, which
already correctly computes the right rate for any `n_prb` via `srsran_sampling_freq_hz_scs()`
and calls `set_tx_srate()`, but that value only sets a decimation *ratio* against the
still-fixed `base_srate` (`rf_zmq_imp.c:437-457`) — it never changes what's actually sent
over the wire. So the eNB has the identical bug class as the bridge, and the two combine:
whatever `base_srate` says is genuinely what goes out, and the bridge's `native_srate` must
match it exactly for the ratio to even be computable.

**The fix**: keep `base_srate` (`enb_baseline.conf`) and `native_srate`
(`modem_zmqtest.conf`) equal to each other and equal to the true rate for whatever `n_prb`
is configured (25→7.68e6, 50→15.36e6, 75→23.04e6, 100→30.72e6 — the standard LTE
bandwidth-class table). At 75/100 this makes the bridge ratio exactly 1 (plain passthrough,
same as the already-working 50 PRB case), not 2/3/4 needing new upsampling logic.

That alone wasn't sufficient — it surfaced a **second, previously-invisible bug**: the
modem's blind cell-search phase (`Phy::cell_search()`, `main.cpp:419-420`) assumes a
hardcoded PRB count for its own FFT/frame sizing, taken from the `-b`/`--file-bandwidth`
CLI flag (`cs_nof_prb = file_bw * 5`) — **not** from `-p`/`--override_nof_prb` as the flag's
name would suggest; `file_bw` unconditionally wins in that ternary regardless of live-SDR
vs. file mode, making `-p` silently dead code for this launch script. `receive-netns.sh`
has always passed `-b 10` (→ `cs_nof_prb=50`, matching the pre-existing 15.36 MHz baseline
exactly, which is why n_prb=25/50 never surfaced this). At 75/100, `-b` must be bumped to
match too (`-b 15`→`cs_nof_prb=75`→23.04 MHz; `-b 20`→`cs_nof_prb=100`→30.72 MHz), or cell
search fails outright (`Phy: Could not find any cell in this frequency`) from a non-integer
bridge decimation ratio during the search phase. Both mechanisms confirmed live: n_prb=75
and n_prb=100 each reached clean BLER 0.0 once `base_srate`/`native_srate`/`-b` were all
kept in lockstep with `n_prb`; reverted all three back to the 25-PRB baseline afterward,
re-confirmed unchanged (243/243 CRC pass).

**Files changed**: `enb_baseline.conf` (`base_srate`, transiently, back to baseline),
`modem_zmqtest.conf` (`native_srate`, `search_sample_rate_hz`, transiently, back to
baseline; comment added documenting the required lockstep), `receive-netns.sh` (`-b` flag,
transiently, back to baseline `10`; comment added). No source code changes — this was
entirely a test-harness/config gap, not a bug in the eNB/modem/bridge code itself.

### Pre-existing gap fixed: `pmch_bandwidth=25` falsely accepted as a valid value

Confirmed via the actual ASN.1-generated header (`pmch_bandwidth_r17_opts`) that the enum
genuinely has no `n25` — only `{n40, n35, n30, spare1, nulltype}`. `reconfigure_embms()`'s
own validation (and `enb_cfg_parser.cc`'s static-config equivalent) used to accept 25 as if
it were a fourth legal value; since the packer's switch has no matching case, setting it was
silently a no-op. Both validation sites now reject 25 with a clear warning explaining why
(pmch-Bandwidth-r17 signals coverage *wider* than the base cell, which 25 — the smallest
cell size tested in this campaign — can never be).

**Files changed**: `rt-mbms-tx/srsenb/src/stack/rrc/rrc.cc`,
`rt-mbms-tx/srsenb/src/enb_cfg_parser.cc`.

### Finding 1 (TI live-reload / "M always decodes as 4") — FIXED, and the real cause was structural

The same live-diagnostic technique that cracked Finding 4 (bump `rrc_level`, watch a warning
that had been silently filtered) found this in minutes. `pack_mcch()`'s OTA-signalling switch
for `time_interleaving_m` only has explicit cases for `{8, 16, 32}` (`default: sf4` for
everything else) — matching `pmch-TimeInterleavingM-r19`'s actual ASN.1 enum
(`{sf4, sf8, sf16, sf32, nulltype}`, confirmed by reading the generated header — only 4
discrete values are representable at all). Separately, `configure_mbsfn_sibs()`'s M
divisor-clamp searched *all* integers down from the configured M for one that evenly divides
`sf_alloc_end`, with no regard for whether the result was one of those 4 legal values.
Live-confirmed: for this rig's baseline (`sf_alloc_end=623=7×89`), that search lands on 1 (for
M=4), 7 (for M=8), or other values with zero representation in the enum — the OTA switch then
always fell through to its `default: sf4`, regardless of what was configured or what the
clamp actually computed. That's the entire "M always shows 4" mechanism: not a value that's
stuck, but every clamped result independently landing outside the enum and silently defaulting
to the same fallback.

**Deeper finding**: confirmed by direct computation that under this baseline (no CAS muting,
`additional_non_mbsfn_subframes=0`), **no valid `mch_sched_period_rf` value ever produces an
`sf_alloc_end` divisible by 4, 8, 16, or 32** — so time interleaving is structurally infeasible
here regardless of which N/M is requested, not a "wrong test value" problem. (One combination
does work — `mch_sched_period_rf=4` with `additional_non_mbsfn_subframes=2` gives
`sf_alloc_end=36`, divisible by 4 — but that parameter is restart-only, not live-settable, so
exercising it is a separate, bigger change than this fix.)

**Fix**: the clamp now searches only the 4 legal enum values (largest first, capped at the
configured M), and if *none* divide `sf_alloc_end` evenly, disables time interleaving outright
(`N=0, M=0`) with a clear warning explaining why, instead of silently signaling an infeasible
M as if it were 4. Live-verified across all four N/M combinations plus the disable-restore
case under the original baseline: **all now correctly report N=0/M=0 with the explanatory
warning, BLER 0.0 throughout**.

**Follow-up, same day: made TI actually functional, not just honestly disabled.** Applied the
parameter change flagged above as a "separate, bigger change" — `additional_non_mbsfn_subframes=2`
(config-file edit, restart-only) plus a live `SET embms.mch_sched_period_rf=4` — giving
`sf_alloc_end=36`, divisible by 4. Enabled `time_interleaving_n=2, time_interleaving_m=4` (the
only legal M for this `sf_alloc_end`) and verified with the `PMCH_TI_DIAG` diagnostic exactly
per the original plan's methodology (BLER alone can't distinguish genuine combining from
coincidental per-subframe success on this clean a channel): confirmed the `TI_DIAG_MFP` worker
pointer stays **identical** across all `mch_subframe_idx` values within one 4-subframe block
and only changes at the block boundary, with `mb_idx_before` advancing exactly once per block —
the methodology-defined proof of real time-interleaving combining, not just correct signaling.
**Time interleaving genuinely works, given scheduling parameters compatible with the M-divides-
sf_alloc_end constraint.** Reverted `additional_non_mbsfn_subframes` back to the original
baseline afterward (consistent with this campaign's practice of restoring true baseline after
each test) — this is a proven, working configuration, documented here for future use, not
silently left as the new default.

**Not touched**: `time_interleaving_n_last_mtch`/`m_last_mtch` (the per-session LastMTCH
override, only relevant with 2+ MBMS sessions) are packed through their own, separate switch
statements with no divisor-clamp at all — out of scope, since this campaign's tests never
exercised multi-session TI.

**Files changed**: `rt-mbms-tx/srsenb/src/stack/rrc/rrc.cc` (clamp search restricted to legal
values; disables TI outright when none apply), `test_sib_matrix.py` (all 4 TI cases' `verify`
expectations updated to match: safe disable, not the nominal N/M, is now the correct
outcome under this baseline).

**Side effect worth noting for Finding 2**: the modem-non-recovery pattern was first observed
right after this exact bug (TI signaled-but-broken) put the eNB and modem in an inconsistent
state. With TI now either genuinely working or honestly disabled, never silently
signaled-as-enabled-but-actually-not, that specific trigger path no longer exists. Not
independently re-tested (would need deliberately reproducing a break, which wasn't attempted
here) — but Finding 2's CAS-muting-triggered instance is a separate, still-open path
regardless (per your instruction, TI and CAS muting were kept isolated throughout this
investigation, never combined).

### Finding 3 (CAS muting BLER breakage) — FIXED 2026-07-17, precisely characterized (2026-07-16)

A follow-up pass (same day) grounded this in the actual primary spec text (TS 36.211
v19.3.0, TS 36.331 v19.0.0, read from local copies in `~/Descargas`), not just TX/RX
self-consistency, per explicit instruction. Key spec facts confirmed:
- §6.1 (general rule): "For an MBMS-dedicated cell, subframes where PSS/SSS/PBCH or PDSCH
  carrying system information are transmitted... are non-MBSFN subframes" — conditional,
  so a muted CAS occasion's subframe genuinely reverts to ordinary MBSFN status. This
  vindicates the codebase's core design assumption on primary-source grounds.
- §6.6.4/§6.11.1.2/§6.11.2.1 (the literal CR 0577 text, all three identical): CAS is muted
  in the last `16*N_CAS - 4*K_CAS` frames of every `16*N_CAS`-frame period; matches the
  code's `nof_true_cas` formula exactly.
- CAS = "Cell Acquisition Subframes" (36.331 acronym list); confirmed CAS only ever occupies
  subframe 0 for an MBMS-dedicated cell (§6.11.1.2's exception clause: "transmitted in slot 0
  ... only", equation recovered from an embedded OLE object = `nf mod 4 = 0`, no subframe 5
  involvement at all). The code's `is_cas_subframe()`/`is_mch_subframe()` already reflect this
  correctly for `mbms_dedicated` cells; the legacy `tti%10==0||tti%10==5` branch only fires
  for non-dedicated (mixed) cells, not exercised on this rig.

**Ruled out this pass, each via direct reading of the actually-compiled code (not the
vendored-but-unused `lib/srsran/srsue/` reference app, which one exploratory agent
mistakenly cited — discarded):**
- Static/non-per-frame FFT, SCS, or non-MBSFN-region selection (genuinely keyed on
  `sf_type`, uniform for every subframe).
- `commonSF-Alloc-v1610` sf0/sf5 bits (both declared `true` on TX, correctly parsed on RX).
- Shared-`_ue_dl`-object contamination between `CasFrameProcessor`/`MbsfnFrameProcessor`
  (confirmed separate instances).
- `pmch_cp`'s RE-extraction offset formula (`srsran_refsignal_mbsfn_offset`): provably
  identical for sf=0 and sf=2 at this SCS (both even-tti, same stagger=0) — the bug is not
  in RE-indexing.
- TX-side PSS/SSS/PBCH/PCFICH muting-awareness (`enb_dl.c`'s `put_sync`/`put_mib`/
  `put_pcfich`): all correctly check `cas_muting`/`k_cas`/`n_cas` and skip on muted frames.
- TX resource-grid buffer staleness: `clear_sf()` zeros the *entire* grid unconditionally at
  the start of every subframe (`srsran_enb_dl_put_base`), before pilots/data are written —
  a muted, unscheduled sf=0 should transmit clean pilots + literal zero data, same as any
  other idle subframe.
- MAC scheduling being muting-specific: confirmed live (`CAS_MUTE_DIAG_ENCPMCH`, TX-side)
  that real MTCH data is scheduled for exactly one subframe per ~640-tti period
  (`mch_subframe_idx=0`), which structurally lands on sf=2, never sf=0 — so `rnti=0` at
  sf=0 is ordinary "nothing queued" behavior, same as most other positions, not something
  muting causes.

**A serious, separate bug was found and resolved along the way**: mid-investigation, overall
MCH BLER collapsed to ~4-8% (not just sf=0) and the modem crashed (`std::vector::operator[]`
out-of-bounds assertion). Proven via a clean A/B test (disable muting, same collapse) that
this was **independent of CAS muting** — it was the already-documented "Modem Long-Uptime
Degradation" bug (see that memory), apparently affecting the eNB side after ~1h+ uptime;
fixed by a fresh restart of both eNB and modem together. `SYNC_OFFSET_DIAG SLOWCALL`
(11-22ms per call vs 1ms budget) turned out to be a chronic, pre-existing, harmless artifact
of this pipeline's ~91%-of-nominal throughput ceiling (present even in a fully healthy run) —
not the cause of the BLER collapse. Also cleaned up genuine diagnostic debt: `SYNC_ERR_DIAG`
(unconditional fprintf on every MBSFN subframe, ~90% of traffic, left enabled since an
already-concluded earlier investigation), `RACE_DIAG`, `PMCH_RE_DUMP`, `DECIM_DUMP` were all
removed from `receive-netns.sh`'s default launch env (see that script's history) — this did
*not* fix the SLOWCALL issue (confirmed unchanged after removal), so it was pure debt, not
the root cause.

**Corrected, precise bug signature (2026-07-17, after user pushback caught a flawed
comparison)**: the original characterization ("sf=0 fails 100%, ~6x raw power deficit vs
sf≠0") conflated two different things by comparing FAILED sf=0 attempts against SUCCESSFUL
sf≠0 decodes — an apples-to-oranges comparison (empty vs real-content power), not evidence of
an sf=0-specific defect. Direct measurement of genuinely-idle (correctly DTX-filtered)
subframes shows the raw noise-floor power (~130) is IDENTICAL at every subframe position,
sf=0 through sf=9 — universal, not sf=0-specific. The corrected, narrower finding, measured
in one consistent time window:
- sf=0: 543/(543+3261) = **14.3%** of muted occasions trip the `data_pw<1e-3` "has content"
  gate and proceed to a (doomed) decode attempt.
- sf≠0: ~0.32% trip the same gate (14/4347 for sf=2, comparable for sf=3-9).
That is a genuine, ~45x anomaly specific to sf=0 — but it means roughly 86% of muted sf=0
occasions are correctly, harmlessly recognized as empty, exactly like sf≠0's mostly-idle
traffic. Only the ~14% that spuriously cross the threshold are a real defect: their
post-equalization data power spikes to thousands (not ~1.0 like genuine content, not ~0 like
genuine idle) and the resulting attempt always fails (0% success in every sample collected).
The aggregate dashboard BLER (~0.82-1.00 depending on sample window) was wrongly interpreted
as "MCH decode is broken at sf=0" — it's actually dominated by this narrower, ~1-in-7
spurious-detection anomaly, not a blanket decode failure. Channel estimate/RSRP still look
reasonably healthy in the failing subset (~850-880, comparable to sf≠0's ~880-894) — the
spurious content-detection spike is not simply explained by a globally-bad channel estimate
either. An ad-hoc raw time-domain capture of an actual failing sf=0 occasion
(`/tmp/pmch_rx_rawFAIL_tti*.bin`) shows real but weak in-band spectral energy.

**FIXED 2026-07-17** (`MbsfnFrameProcessor.cpp`, commit `c3bbdcd`): rather than continuing to
chase the exact trigger, fixed the actual observable defect directly. Confirmed live:
genuine content always shows `data_pw≈1.0` (0.9997-1.0002 across every real decode sampled);
genuine idle always shows `data_pw≈0` (0.000000-0.000003, identical at every subframe
position including sf=0 — confirmed NOT sf=0-specific, correcting the earlier
"6x power deficit" framing which compared failures against successes, not idle-vs-idle);
the anomalous cases show `data_pw` in the thousands (4500-39000) — physically impossible for
real content, only explainable by a near-zero denominator in the equalizer. The existing DTX
gate (`data_pw < 1e-3` → IDLE) only caught the empty case; extended it symmetrically to also
catch `data_pw > 10.0` → IDLE, since both extremes mean "nothing reliable was decoded", not a
genuine failure. **Live-verified**: MCH 0 BLER dropped from ~0.82-1.00 to **0.0**, 100%
success on every genuine decode attempt post-fix, confirmed directly via
`/modem-api/mch_status/0`.

**Root cause of the anomaly itself — still open, lower priority given the fix is deployed**:
live evidence (before the fix) showed the anomaly is 100% attributable to exactly ONE of the
`thread_cnt` (4) round-robin `MbsfnFrameProcessor` worker-pool instances — confirmed
reproducible across a fresh restart with new memory addresses (ruling out address-specific
corruption), at a uniform ~14.3% probability across all 32 possible muting-period phase
alignments (ruling out an SFN-wraparound-tied or otherwise frame-number-deterministic cause).
That SAME worker decodes sf=1-9 with 100% success, including immediately before and after its
own sf=0 misfires, ruling out a generally-broken instance. All 4 `MbsfnFrameProcessor`
objects are constructed identically (`main.cpp:481-488`, plain loop, no per-index
differentiation), so the divergence must be runtime/timing-dependent, not structural.
**Concrete new lead, not yet chased down**: `main.cpp:690` gates whether to dispatch a tti to
a worker at all via `phy.is_mbsfn_subframe(tti)` — a call *independent* of and separate from
`mbsfn_config_for_tti()` (already computed moments earlier, at `main.cpp:650`, as `peek_cfg`,
and again inside the worker's own `process()`). These are two different classification code
paths that must agree for a muted sf=0 to be both dispatched and correctly configured; if
they can momentarily disagree (e.g. via unsynchronized reads of `Phy::_cell`'s
`cas_muting`/`k_cas`/`n_cas` fields, which are plain members with no dedicated mutex, unlike
`_mcch_mutex`/`_sib13_mutex`), that would explain a rare, worker-timing-dependent divergence
specific to the position with dual CAS/MBSFN routing (sf=0) and nowhere else. Next step if
resumed: audit `Phy::_cell`'s field-level thread-safety, and/or add a diagnostic comparing
`is_mbsfn_subframe(tti)` and `mbsfn_config_for_tti(tti,...).enable` at the exact moment of
dispatch for every sf=0 occasion, to catch a live disagreement directly.

**Naming note (per explicit request)**: `MCH_SF5_DIAG` was renamed to `MCH_DIAG` — the name
was stale, inherited from an earlier, already-fixed, unrelated subframe-5 DTX-detection bug
(commit `8622a52`); the diagnostic itself was always generic (any non-MCCH MBSFN subframe),
just mislabeled. Also added `data_pw`/`cepw`/`rsrp`/`syncerr` fields to the diagnostic print.
`sf5` itself has no CAS-related meaning for an MBMS-dedicated cell (confirmed against primary
spec text above) — the only place sf5 is legitimately meaningful is `commonSF-Alloc-v1610`'s
separate sf0/sf5 "common MBSFN capacity" bits, unrelated to CAS occupancy, and both already
correctly declared `true` on this rig.

### Coverage gap found and closed: frequency interleaving was never tested

Review after the fix pass turned up a real gap in the original test matrix: `freq_interleaving`
(Rel-19 `pmch-TFI-Config`'s `pmch-FreqInterleav-r19`, `embms.freq_interleaving` on the
control socket) is a real, live-reconfigurable PMCH parameter — a simple on/off flag for
frequency-domain interleaving, distinct from (and independent of) time interleaving's N/M —
that was never included in the original plan's matrix or `test_sib_matrix.py`'s case list,
despite the campaign's stated goal of exercising "the different SIB parameters."

Added two cases (`freq_interleaving_enable`, `freq_interleaving_disable_restore`) and
tested live: **both PASS, cleanly** — `mcch.pmch_list.0.freq_interleaving` correctly
decodes `true`/`false` matching what was set (double-checked directly via REST, not just
the script's automated diff), and BLER stayed 0.0 throughout both transitions. Unlike time
interleaving (which shares the same `has_phase2`/v1900 MCCH extension code path but is
badly broken), frequency interleaving's simple on/off signaling works correctly end-to-end,
TX to RX. This is the same code path `use_mcs_table2` already exercised successfully earlier
in the campaign, consistent with that being the working case and full N/M time interleaving
being the outlier.

**Files changed**: `test_sib_matrix.py` (two new cases added, so future re-runs of this
matrix include frequency interleaving).

### Pre-existing gap (TI/MCCH §15.3.3 conflict) — left as-is, already self-documented

Already produces a clear, correctly-cited in-code warning
(`reconfigure_embms()`: "TS 36.300 §15.3.3 requires a time-interleaved MCH not carry MCCH").
An actual fix needs genuine multi-PMCH support (separating MCCH-carrying capacity from a
TI'd MTCH-only PMCH into distinct `pmch_info_list` entries) — a real feature addition, well
beyond a bug fix, not attempted this pass.

## Findings (as originally documented — see "Fix pass outcomes" above for what's changed)

### Finding 1: Time interleaving (`time_interleaving_n`/`m`) live-reload is unreliable

- `time_interleaving_m` sticks at its first-ever configured value (4) across all later live
  `SET`s (8, 16, 32 all decoded as 4).
- `time_interleaving_n` mostly updates correctly call-to-call, but at one point in the
  sweep (`ti_16_32`) decoded as the *previous* call's value instead of the new one —
  more consistent with a propagation-timing race (the fixed ~8s wait not always spanning a
  fresh `mcch_modification_period` boundary) than a hard "N never updates" rule.
- Disabling TI entirely via live `SET` (N=0) also failed to take effect — decoded N stayed
  at 4, and BLER collapsed to 100%. This is more serious than the M/N staleness above: a
  stale-but-internally-consistent signal is merely wrong, but a signal that goes stale
  *while the eNB's actual TI behavior underneath has changed* breaks decode outright.
- Root cause traced as far as `rrc.cc:1825-1839`: `pmch_item->time_interleaving_m` is only
  written inside `if (cfg.pmch_time_interleaving_n > 1 && cfg.pmch_time_interleaving_m > 1)`,
  with a divisor-clamp against `sf_alloc_end` (confirmed live: `sf_alloc_end=623=7×89`, a
  semiprime that none of the tested M values divide evenly — so the clamp-search should
  produce different results each time, e.g. M=8→7). The clamp warning log line never
  appeared at all across the sweep, suggesting the whole repack block may not be
  re-executing on subsequent `SET`s, not just the arithmetic being off. Not fully nailed
  down — needs tracing whether `reconfigure_embms()`/this block is even called again after
  the first live `SET`.

### Finding 2: Modem doesn't self-recover from TI-induced corruption without a full restart

Once Finding 1's N=0-disable failure broke decode (BLER 100%), restarting *only* the eNB
with a confirmed-clean config (N=0/M=0/MCS=9 via REST) still showed ~97-98% BLER on the
existing modem process. Only restarting the modem too brought BLER back to 0.0. This points
to the modem's TI block-boundary/worker-pinning logic (`main.cpp`'s `mb_idx`/
`ti_last_of_block` tracking) getting durably desynced by a broken or rapidly-changing TI
signal, with no self-recovery once the signal goes clean again — a robustness gap on the RX
side, distinct from Finding 1's TX-side propagation bug. The same "won't self-recover, needs
both eNB and modem restarted" pattern recurred once more later in the campaign (residual
~91-93% BLER at the start of the bandwidth phase, traced to the immediately-preceding CAS
muting sweep) — treat as a general property of this modem build, not a TI-only quirk.

### Finding 3: CAS muting breaks PMCH decode whenever active, despite fully correct signaling

All four tested `(k_cas, n_cas)` combinations decoded their signaling exactly right
(`sib1.cas_muting_enabled`/`k_cas`/`n_cas` all matched what was set) — unlike Finding 1,
the signaling path itself works. But functional BLER was severe in every enabled case:
(4,2)→100%, (8,4)→~91%, (16,8)→~43%, (32,16)→~95%. Disabling muting again immediately
returned BLER to 0.0 with no extra restart needed — unlike Finding 2, this one doesn't
leave lasting corruption.

BLER varying by combination (not a uniform 100%) points to a **partial subframe-index
misalignment** rather than total decode failure — consistent with `Phy.cpp:568-595`'s
`nof_true_cas` (frames actually consumed by CAS) being computed differently depending on
`cas_muting`, shifting the absolute-TTI-to-logical-MCH-subframe-index mapping. Working
hypothesis, not yet confirmed: muted CAS occasions are supposed to carry real MBSFN/PMCH
data (that's the point of muting, per Rel-19 CR 0577), so if the RX's subframe accounting
doesn't correctly treat a muted occasion as MCH-carrying, every subsequent MCH subframe
would be looked for at the wrong index — explaining large-but-not-always-100% BLER,
since some subframes coincidentally still land correctly depending on the specific
k_cas/n_cas period arithmetic. Not yet done: confirm directly by comparing `nof_true_cas`'s
computation against the actual muting pattern, and check whether the TX side has an
analogous accounting issue.

### Finding 4: `pmch_bandwidth` live-reload doesn't propagate (same pattern as Finding 1)

All three tested values (30, 35, 40 PRB at n_prb=25) decoded as `0` — the eNB accepts and
internally stores the value immediately (confirmed via control-socket `GET`), but it never
reaches the actual broadcast SIB13 content. BLER stayed 0.0 throughout (functionally
benign here, since TX and RX stay mutually consistent at the stale `pmch_bandwidth=0`) —
unlike Finding 3, no corruption or restart was needed. Same "accepted, not broadcast"
shape as Finding 1; not yet traced to a specific line, but `configure_mbsfn_sibs()`/
`pack_mcch()` possibly not being re-invoked (or a missing value-tag bump) on a live-reload
`SET` that only touches `pmch_bandwidth` is the leading candidate, by analogy.

### Finding 5: MCS=28's clamp — eNB log claims a stricter result than what's actually signaled

Configuring MCS=28 triggers the known infeasibility clamp (`rrc.cc`), and the eNB log
records: `"Configured PMCH MCS=26 is infeasible for 25 PRB (code rate > 1...); clamping to
MCS=24"`. But the value actually decoded by the modem — confirmed via REST, cross-checked
against the raw log — is **26, not 24**. BLER stayed 0 at 26. This is the same "accepted/
logged, not actually applied to the broadcast content" shape as Findings 1 and 4, just
surfacing through the MCS clamp path instead of TI or bandwidth. Functionally benign in
this instance because TX and RX ended up self-consistent at 26 regardless of what the log
claimed — but a case where TX and RX disagree (one side acting on the log's claimed 24,
the other on the implied-still-26 input) would not be benign. Not fully root-caused.

**Cross-cutting note**: Findings 1, 4, and 5 all show the identical shape — a live
`SET` (or an automatic clamp during one) is validated and logged correctly, but the
actual value packed into the broadcast MCCH/SIB13 content doesn't reflect it. Given three
independent parameters hit the same failure mode, the fix pass should look for one shared
cause (most likely in `configure_mbsfn_sibs()`/`pack_mcch()`'s re-invocation or a value-tag
bump on live reconfiguration) before treating these as three separate bugs to fix
individually.

### Finding 6: `n_prb`∈{6,15} crash the modem (decimator CPU saturation)

n_prb=6 and n_prb=15 both crashed the modem process outright (silent exit, no captured
crash log) within seconds of starting. Root cause, confirmed via `ZMQRX_RATIO_DIAG` and
`SYNC_OFFSET_DIAG SLOWCALL`: these bandwidths need decimation ratios of 8x and 4x
respectively (vs. 2x at the working n_prb=25 baseline), which by the bridge's
`design_decim_lowpass()` formula (`15×ratio+1` taps) means 121 and 61 taps — well past the
CPU headroom this session's `-O3` fix provides (validated safe only up to ratio=2, ~35-45%
of one core; ratio≥4 needs roughly 2-4x that compute). Not a SIB13/MBSFN signaling bug —
a scaling limit of the current (non-polyphase) decimator implementation.

### Finding 7: `n_prb`∈{75,100} fail via a hardcoded native-rate ceiling with no upsampling path

n_prb=75 didn't crash, but never acquired: the eNB log showed a persistent, steadily-growing
`tx time is X ms in the past` drift, and the modem's decoded MIB never appeared
(`nof_prb: 0` after 20+ seconds). Root cause, confirmed at the code level:

- `phy_common.c`'s `srsran_symbol_sz_scs()` (SCS_1KHZ25 branch) gives `symbol_sz=18432` for
  `nof_prb<=75`; physical sample rate = symbol_sz × SCS = 18432 × 1250Hz = **23.04 MHz**
  required for n_prb=75 at this session's 1.25kHz FeMBMS SCS (the same physical Fs as
  standard-LTE n_prb=75 at 15kHz SCS — the sample-rate steps line up with the familiar LTE
  bandwidth classes regardless of SCS: 6→1.92, 15→3.84, 25→7.68, 50→15.36, 75→23.04,
  100→30.72 MHz).
- `modem_zmqtest.conf` hardcodes `native_srate=15.36e6` — exactly matching n_prb=50, one
  step below what n_prb=75 needs.
- `soapy-zmq-bridge/ZmqRxDevice.cpp`: the decimation `ratio` is only computed when
  `sample_rate_ < native_sample_rate_` — there is no branch anywhere in the file for
  `sample_rate_ > native_sample_rate_`. When the modem requests 23.04 MHz against a 15.36
  MHz native rate, that condition is false, so `ratio` silently stays at its initialized
  value of `1` — no upsampling happens, no error is raised, and the bridge just serves
  15.36 Msps while the modem's PHY believes it's receiving 23.04 Msps. That fixed-ratio
  mismatch produces exactly the observed linearly-growing timing drift, and the wrong
  sample-rate assumption breaks symbol/slot boundary detection, explaining why the MIB
  never decoded.
- n_prb=100 (needing 30.72 MHz, 2x native — an even larger gap) was **not tested live**:
  the mechanism is confirmed at the code level, so a live test would not add information.
  Skipped by design, not by omission.

Distinct from Finding 6: that one is a compute-cost ceiling on the *downsampling* path;
this one is a complete absence of an *upsampling* path. Both are bridge scaling limits, not
SIB13/MBSFN protocol bugs. **Practical conclusion for this rig as currently built: only
n_prb=25 (ratio=2) and n_prb=50 (ratio=1, exact native-rate match) are usable.**

**Superseded, 2026-07-18: this "no upsampling path" framing was wrong — no upsampling was
ever needed.** The eNB's own TX rate is *also* just a hardcoded `base_srate` literal,
decoupled from `n_prb` the same way the bridge's `native_srate` is; nothing was ever
actually transmitting at 23.04/30.72 MHz to upsample from in the first place. Setting
`base_srate`/`native_srate` to the correct value for the configured `n_prb` (making the
bridge ratio exactly 1, not >1) plus a second, previously-hidden fix to the modem's
cell-search `-b` flag resolved both n_prb=75 and n_prb=100 completely — see "Finding 7,
actually fixed" earlier in this document for the full writeup. **Both are now usable**,
same as 25/50.

### Phase 6 (TI + muting interaction): not run at this point in the campaign

Blocked by Finding 1 — testing the planned interaction cases via live `SET` would just
re-trigger the already-documented TI propagation bug rather than exercise the interaction
itself. Skipped rather than spending live-test time on a result that wouldn't be
informative; revisit once Finding 1 is fixed (a static-config-plus-restart variant would
also sidestep the live-reload bug if an earlier interaction check is wanted).

**Update, 2026-07-18: run once Findings 1 and 3 were both fixed — both cases PASS, no new
interaction bug. See "Phase 6 — run 2026-07-18" further down for the full write-up.**

## Pre-existing gaps (identified during planning, not re-verified live this campaign)

1. **`pmch_bandwidth=25` combined with a different `n_prb`** is validated on the TX PHY
   side, but the SIB13 packer (`rrc.cc:1699-1710`) only has switch-cases for 30/35/40 —
   so this specific combination is silently never signaled over the air. (Separate from
   Finding 4, which is pmch_bandwidth failing to propagate even at n_prb=25 where the
   packer *does* have matching cases.)
2. **Any `time_interleaving_n>1` conflicts with TS 36.300 §15.3.3** (a TI'd MCH shouldn't
   carry MCCH), because this eNB always configures `pmch_info_list[0]`, which is always
   the MCCH-adjacent PMCH (`rrc.cc:1050-1060`, self-acknowledged in-code). Every TI>1 case
   in this campaign therefore ran non-compliant with the spec, independent of Finding 1's
   propagation bug.

## What's next

See "Fix pass outcomes" above for the full picture. Summary of what's actually left:

**Fixed and confirmed genuinely functional (not just safely disabled)**: Finding 1 (TI). The
real bug was `pack_mcch()`'s OTA switch having no case for divisor-clamped M values, always
defaulting to a misleading 4. Fixed the clamp to search only the legal enum values; **then
proven to genuinely work** (via `PMCH_TI_DIAG`'s worker-pointer-stability methodology, not
just BLER/signaling) once given scheduling parameters compatible with the M-divides-
`sf_alloc_end` constraint (`additional_non_mbsfn_subframes=2` + `mch_sched_period_rf=4`).
Safely/honestly disables (rather than misrepresenting) under scheduling parameters that
can't support any legal M, which is what this rig's original baseline happens to be.

**Substantially improved, root cause found and fixed, not fully resolved**: Finding 4
(`pmch_bandwidth`). The real bug (after an incorrect first conclusion that this needed new
PHY architecture) was a TX/RX code divergence in `pmch.c` plus an internal-vs-caller PRB
count mismatch in the same file, in both repos. Fixing both took MCCH from 100% failure to
majority success and made MTCH decode get attempted for the first time ever — but a separate,
still-unexplained timing/blocking issue (`SYNC_OFFSET_DIAG SLOWCALL`, not CPU-bound, not the
eNB falling behind) still causes most MTCH data decodes to fail. Also fixed along the way:
three CAS-dashboard diagnostic functions had the same PRB-sizing bug (cosmetic only — the
real CAS decode path was never affected).

**Also fixed and live-verified**: the `pmch_bandwidth=25` pre-existing gap, the missing
`systemInfoValueTag` bump. `n_prb`∈{75,100} initially only made to fail loudly instead of
silently misbehaving — later (2026-07-18) actually fixed outright, config-only, see
"Finding 7, actually fixed" further up. Frequency interleaving was found missing from the
original matrix entirely and, once added, tested clean (PASS, no fix needed).

**Corrected, not a bug**: Finding 5 (MCS=28 clamp) — could not be reproduced under
live-instrumented testing; the original finding was a misdiagnosis. The `pack_mcch()`
duplicate-computation cleanup was kept anyway as a genuine (if unrelated) hygiene fix.

**Fixed 2026-07-17**: Finding 3 (CAS muting BLER breakage). Root-caused to a spurious
equalized-power anomaly specific to ~14% of muted sf=0 occasions (one worker-pool instance,
trigger not fully explained but no longer matters for correctness); the DTX/idle gate was
extended to also treat implausibly-high post-equalization power as "nothing reliably
decoded," matching how the near-zero case was already handled. Live-verified: MCH BLER
0.82-1.00 → 0.0, commit `c3bbdcd`. Finding 2 (modem non-recovery) is confirmed resolved for
its CAS-muting-triggered path too, by the same live test (no restart needed to recover once
muting was disabled again, consistent with the earlier TI-path finding).

**Still open, needs live-instrumented diagnosis (not more static reading)**: only the Finding
4 SLOWCALL/timing issue now. A separate, unrelated investigation (2026-07-18) into a
previously-documented "eNB/modem long-uptime degradation" bug (BLER regresses after ~1h+/6h+
uptime, fixed only by a fresh restart) found no new TI-independent root cause after a
structured search across five candidate mechanisms — but did catch a real, newly-introduced
risk in an unrelated fix (see "ZMQ_PUB send buffer" note below) before it could cause a
similar-looking symptom. That original degradation's root cause remains unfound.

**Deliberately not attempted, real feature work not a bug fix**: Finding 6 (n_prb∈{6,15}
decimator CPU ceiling — needs a faster/polyphase decimator), the deeper PHY-level wideband
PMCH capability uncovered while fixing Finding 4 (needs resource-grid/softbuffer changes),
and the TI/MCCH §15.3.3 spec conflict (needs genuine multi-PMCH support). Making TI actually
functional under this rig's *default* baseline specifically (not just via a temporary
restart-only parameter change, `additional_non_mbsfn_subframes=2`, applied and reverted for
testing — see Phase 6 below) is not attempted: that would mean permanently changing the
tutorial's default config, a product decision rather than a bug fix.

`rt-mbms-tx` and `soapy-zmq-bridge` were modified this pass; `rt-mbms-modem` was not (the
remaining open findings are suspected to involve modem-side state, but this wasn't
confirmed).

### ZMQ_PUB send buffer: bounded HWM added, then corrected (2026-07-18)

While investigating Finding 4's SLOWCALL/timing issue, added an explicit `ZMQ_SNDHWM` on the
eNB's TX socket (`rf_zmq_imp_tx.c`, both `rt-mbms-tx` and `rt-mbms-modem` copies) — ZMQ_PUB's
default 1000-message HWM means a momentarily-lagging subscriber causes silent message drops,
not blocking. First attempt set it to unlimited (0); a background investigation into the
separate long-uptime degradation bug (below) flagged that since the ~91%-of-nominal
throughput ceiling is a *persistent*, chronic deficit rather than a transient stall, an
unlimited HWM risks roughly unbounded queue growth for as long as it's active at ratio=1
(no decimation margin). Corrected to a large-but-bounded value (50000) instead — keeps the
transient-stall protection without the unbounded-growth risk. Live-verified the video demo
stayed healthy through both the original change and the correction. Committed and pushed:
`rt-mbms-tx` `51fdc61`, `rt-mbms-modem` `5d366cf`. Does not fix the underlying throughput
ceiling itself (still open, see Finding 4 above) — only bounds the worst case of a mitigation
that was already a reasonable idea for the *transient*-stall case it was originally aimed at.

### Investigation: eNB/modem long-uptime degradation root cause (2026-07-18) — inconclusive

Separate, pre-existing bug (see the `project-modem-long-uptime-degradation` memory and
Finding 3's write-up above, where it was hit again and correctly identified as unrelated to
CAS muting): BLER regresses from 0.0 to ~75-79% (modem) or a catastrophic collapse + crash
(eNB) after prolonged uptime (modem ~6h+, eNB ~1h+), fixed only by a fresh restart of both.
Two previously-identified candidates (`pmch_ti_tx_buf` TX race, RX softbuffer poisoning) both
require Time Interleaving active, which the actual observed incidents did not have.

A structured background search (counter wraparound, unbounded containers, softbuffer/HARQ
reuse, floating-point drift, hot-path allocation) across both codebases found no convincing
TI-independent candidate. The only concrete finding was the ZMQ_SNDHWM=0 risk documented
above, which postdates and cannot explain the original, already-documented incidents. Root
cause remains genuinely open; would need live reproduction over hours with memory/per-thread
CPU profiling captured *before* a restart, not more static code review.

### Phase 6 (TI + muting interaction) — now unblocked, not yet run

The original plan deferred this because Finding 1 (TI) was broken. Finding 1 is now fixed
(functional, given `additional_non_mbsfn_subframes=2`/`mch_sched_period_rf=4`) and Finding 3
(CAS muting) is now fixed too — so the planned TI(4,8)+muting(8,4) and TI(8,16)+muting(16,8)
cases could genuinely be run for the first time. Not attempted yet: TI's working combination
needs a restart-only parameter change from this rig's baseline, so it needs an eNB restart to
set up, not just a live `SET`.

### Phase 6 — run 2026-07-18: both interaction cases PASS

Restarted the eNB with `additional_non_mbsfn_subframes=2` (the config-file, restart-only
change Finding 1's fix needs), then live-`SET` `mch_sched_period_rf=4` + `time_interleaving_n=2`/
`time_interleaving_m=4` — the only legal M for this rig's resulting `sf_alloc_end=36` (M∈{8,16}
from the original plan don't divide 36, so the two cases run were TI(2,4)+muting(8,4) and
TI(2,4)+muting(16,8), not the originally-planned M=8/16 values, which remain structurally
infeasible under the one known-working TI recipe on this rig).

Confirmed via raw `MCHDIAG` (worker-pointer-stability method, no restart of the diagnostic
needed since the pattern is visible in the plain per-subframe log): TI combining stayed
genuine with CAS muting active simultaneously, in both cases. Signature: one worker instance
holds for exactly N×M=8 consecutive `mch_sf_idx` values; the first 4 in each block report
`crc=0` (expected — not enough repetitions combined yet), the last 4 report `crc=1` (real
combined decode success). This ~50/50 `crc=0`/`crc=1` split is *expected* TI behavior, not a
failure rate — over a ~400-line sample: case A (muting 8,4) 193/164, case B (muting 16,8)
181/148, both consistent with the same pattern.

One transient wrinkle, self-resolving: right after enabling muting for case A, the modem
briefly showed a burst of `MCHIDLE`-only subframes and repeated `SIB1-MBMS` reacquisition
prints (~10-15s) before settling into the healthy pattern above — ordinary MCCH
modification-period reacquisition after a live reconfiguration, not a persistent bug (matches
the propagation-window behavior already documented for other live `SET`s in this campaign).

Reverted all live-set values (muting off, TI off, `mch_sched_period_rf=64`) and the
config-file `additional_non_mbsfn_subframes` back to baseline, restarted the eNB again;
re-verified BLER 0.0 on the plain baseline afterward.

**Net result**: no new TI/muting interaction bug found — both features work correctly
together, at least for the one TI configuration this rig supports. The dashboard did show a
few red "Fail" subframe-activity cells during this test window; checked whether that panel
naively flags any `crc=0` as a failure without accounting for TI's expected mid-span
non-convergence — it does not. `MbsfnFrameProcessor.cpp:569-606` already explicitly logs
intermediate subframes within an active TI combining span as IDLE (not FAIL) per Rel-19
§6.5.3, only emitting FAIL on the last subframe of a span that still didn't decode; the
frontend (`modem.js:522-529`) is a dumb, correctly-fed color map. So the red cells were
genuine decode failures, consistent with the transient reacquisition burst noted above —
not a dashboard bug, nothing to fix here.

Also observed during this window: two brief, physically-implausible CINR spikes (~80-90dB
instantaneous, against this rig's normal ~30-46dB range) on the CINR/BLER chart, each
coinciding with a live reconfiguration moment and a small real BLER blip. Not independently
root-caused — most likely the CINR estimator not clamping/resetting cleanly during the same
transient resync windows discussed above, rather than a new decode-affecting bug (BLER impact
was minor and self-resolving in both cases). Lower priority than the confirmed issues above;
flagged here for a future look, not chased further this pass.

## Follow-up pass, 2026-07-18: CAS stability across wideband retune, a real concurrency crash, and Finding 4 re-confirmed

Picked back up on Finding 4 (`pmch_bandwidth` wideband, PMCH > carrier). Four distinct,
independently live-verified fixes this pass, plus a re-confirmation that the one remaining
Finding 4 symptom (MTCH decode) is the same pre-existing gap already documented above, not a
new regression.

**Fixed and confirmed — `rt-mbms-modem`, all uncommitted, pending commit:**

1. **CAS instability across a wideband retune**: `Phy::set_cell()` resized `_ue_sync`'s
   fft_size/sf_len for the new geometry but never called `srsran_ue_sync_reset()`, leaving it
   in `SF_TRACK` applying corrections computed under the OLD geometry to samples now aligned to
   the NEW one. Separately, the retune trigger (`main.cpp`, `phy.nof_mbsfn_prb() > cas_nof_prb`)
   had no guard against re-firing, so it repeated on every CAS occasion (~360ms) for as long as
   `pmch_bandwidth` stayed wider than the carrier, continuously restarting the SDR and
   resyncing. Fixed both (sync reset + a `mbsfn_nof_prb`-tracked one-shot guard). Live-verified:
   CAS held stable for 4+ minutes straight through PDSCH, confirmed directly by the user
   comparing dashboard behavior before/after.
2. **A genuine double-free/heap-corruption race**: `set_cell()` (main thread) reallocates a
   processor's FFT/CIR buffers while a previously-dispatched, fire-and-forget `process()` call
   may still be running on a worker-pool thread against those same buffers. First fix attempt
   (a mutex) caused a *worse*, guaranteed deadlock (`get_rx_buffer_and_lock()` already holds the
   same non-recursive mutex on the main thread before `pool.push()` even runs) and was reverted.
   Real fix: capture the `std::future` `pool.push()` already returns (previously discarded) per
   processor (`cas_future`, `mbsfn_futures[thread_cnt]` in `main.cpp`), and `.wait()` on it
   immediately before that processor's next `set_cell()` call, at all three call sites (CAS
   retune, MBSFN reconfigure, post-sync-loss CAS re-sync). Live-verified: no crash across
   repeated widen/narrow retune cycles and sustained wideband operation (previously crashed
   with `double free or corruption` within minutes).
3. **Missing retune-back-down logic**: the retune trigger only handled PMCH growing wider than
   the carrier; reverting `pmch_bandwidth` back to 0 left the SDR/CAS FFT permanently stuck at
   the wider grid (wrong RE-per-symbol count) until a full process restart, even though the eNB
   was signalling a narrower width again. Spotted live by the user via the CAS composition
   dashboard ("changed again and this should not be different, CAS is the same"). Fixed by
   generalizing the trigger to `target_mbsfn_prb = max(actual PMCH width, carrier)` and
   retuning whenever that changes in *either* direction (using the plain carrier-rate calc,
   not the MBSFN-SCS-aware one, when narrowing back to the carrier's own width). Live-verified
   across two full widen→narrow cycles: `fft_size`/`sf_len` correctly return to the 25 PRB
   baseline (512/7680) both times, CRC 87/87 and 100% (post-settling) respectively.
4. **CAS composition dashboard canvas-width bug**: `CasFrameProcessor::composition_grid()`
   sized its rendering canvas from `max(nof_prb, mbsfn_prb)` — copied from `cir_values()`/
   `ce_values()`, which genuinely need the wider canvas since they represent the MBSFN-adjacent
   sample stream. But composition_grid() only marks CAS-domain elements (PBCH/PSS/SSS/CRS/
   PCFICH/PDCCH), which are semantically always the carrier's own width, never wider. Worse,
   this was internally inconsistent: PBCH/PSS/SSS were drawn centred in the wider canvas while
   CRS/PCFICH/PDCCH used narrow, uncentred carrier-relative indices — so elements no longer
   lined up with each other on top of the whole chart being visually wider than it should be.
   Fixed by using `_cell.nof_prb` alone. User-confirmed live ("CAS is peffect") immediately
   after the fix, at the exact same `pmch_bandwidth=30` config that showed it broken before.

**Re-confirmed, not fixed — same pre-existing gap as Finding 4 above, not a new regression:**
spent substantial time this pass tracing the full CE pipele for the `pmch_bandwidth=30`
extended-BW case end-to-end (reference-sequence generation in `refsignal_dl.c`, raw pilot
extraction, the `chest_dl.c` LS-estimate computation, and interpolation) — all internally
self-consistent by static reading, no new bug found. (Side note: for this specific "PMCH wider
than carrier" scenario, `main.cpp` already forces `cell.nof_prb = max(nof_prb, mbsfn_prb)`
before configuring the MBSFN processor, making every `act_prb`-vs-`nof_prb` distinction in
that pipeline numerically inert here — it only matters for the opposite, sub-allocation case.)
Symptom observed: `cepw` (channel-estimate power) stays suspiciously constant/real while
`rxpwr`/`datapw` (actual decoded data power) collapses to noise floor and CRC is 100% fail,
with `SYNC_OFFSET_DIAG SLOWCALL` present throughout (11-12ms per 1ms budget). This exactly
matches the already-documented Finding 4 continuation above ("a separate, still-unexplained
timing/blocking issue... still causes most MTCH data decodes to fail") — confirmed to be the
same open gap, not something introduced by this pass's fixes. Still needs live timing
instrumentation (not more static code reading) to actually crack.

**Two more fixed and confirmed, found via user-spotted dashboard anomalies:**

5. **MBSFN CE waterfall chart showing solid green blocks either side of the real content**:
   both `CasFrameProcessor::ce_values()` and `MbsfnFrameProcessor::ce_values()` zero-pad their
   wider display canvas with a raw `0.0f`/`memset`, but that padding region never goes
   through `srsran_vec_abs_dB_cf()`'s own `-80` floor - only the real, centred active-PRB
   content does. The dashboard's `waterfall_color()` maps `db=0` to a strong, solid green
   (RGB≈(19,162,0) at this chart's -20..25dB scale), not black/background, so the padding
   rendered as two solid green blocks bookending the real (narrower) content. Fixed by
   filling the padding with `-80.0f` directly instead of `0`/`memset`, in both files.
   (`cir_values()` in both files was already correct — it dB-converts the *entire* IFFT
   output, no partial-region padding issue.)
6. **A stuck-worker MCCH decode failure, found while investigating #5**: `MCCHDIAG` showed
   100% CRC failure across the *entire* modem run (1745/1745 samples), always on the exact
   same pinned worker-pool instance, while MTCH decode on the other instances stayed
   perfectly healthy the whole time. Traced the real scheduling-affecting gate
   (`MbsfnFrameProcessor.cpp:445`'s `if (pmch_dec.crc)`, feeding `Rrc.cpp`'s independent
   ASN.1 `unpack()` validation) — confirming the campaign's live-verified `pmch_bandwidth`/MCS
   propagation this session was never running on corrupted data, just on whichever MCCH
   decode last succeeded before this instance got stuck. Matches a failure mode already
   documented earlier in this campaign (a worker instance not self-recovering after a
   retune without a modem restart). Confirmed via a fresh restart: MCCH 52/52 and MCH 134/134
   both crc=1 immediately - a transient state issue from this pass's heavy retune testing,
   not a new code bug.

**Dispatch ruled out as the cause, narrowing Finding 4's remaining gap**: added a `DISPATCH`
diagnostic (env `RACE_DIAG2`, `main.cpp`) logging every `pool.push()` dispatch with its
`mb_idx`. Fresh restart, clean baseline (MCCH 62/62 crc=1), then `pmch_bandwidth=30`: all 4
round-robin workers dispatched perfectly evenly (156/156/156/156 over the same window) - the
earlier "stuck worker" read on a *different* restart was a real, separate transient (matches
Finding 6 above), not this pass's steady-state behavior. But decode still failed uniformly
across all four (619/619 MCH, the one MCCH sample too) once widened. This rules out a
scheduling/dispatch gap and re-centers Finding 4's remaining symptom squarely on the decode
path itself (CE/data extraction, or the exact retune-transition timing) - not a stuck-instance
problem. Reverted cleanly to baseline afterward (33/33 crc=1). Next session should pick up
here: the CE/interpolation/reference-generation pipeline was already traced clean by static
reading this pass (see the CE-pipeline paragraph above), so the next step is runtime
instrumentation of the decode path itself, not more static tracing.

## Root cause found (2026-07-18, same day, continued): eNB TX never actually widens for pmch_bandwidth

After formula-level verification against TS 36.211 §6.10.2.2.2 (MBSFN-RS mapping) and
§6.3.5 (generic data RE mapping) confirmed the RX's reference-signal AND data RE
placement are both spec-correct for the wideband case, a targeted LLR/pilot/raw-grid
dump investigation (`PMCH_RE_DUMP`, already existing in the codebase, retargeted live
via `/tmp/pmch_dump_tti`) found: 71% of LLRs were exactly zero, correlating exactly
with post-equalization symbols collapsed to near-zero magnitude (not NaN). Dumping the
pre-extraction raw grid directly (`sf_symbols`, before any RX-side processing) showed a
clean, smooth, bell-shaped power envelope spanning almost exactly the ORIGINAL,
narrower carrier's own bandwidth (~25 PRB), centred within the wider 30-PRB acquisition
window the RX correctly retuned to - with genuine silence at the edges. **This proves
the eNB itself never actually transmits the wider PMCH content on the air**, even
though `pmch_bandwidth` is correctly signalled in SIB13/MCCH - a `rt-mbms-tx` (TX-side)
bug, not an RX decode bug, this session's RX-side fixes notwithstanding.

Traced the exact mechanism in `rt-mbms-tx`: the eNB's own RF sample rate
(`srsenb/src/phy/txrx.cc:93`) and per-subframe TX buffer sample count
(`srsenb/src/phy/lte/sf_worker.cc:159`) are both derived from the carrier's plain
`nof_prb` only, computed ONCE at process startup (`enb.cc`/`phy.cc`/`enb_cfg_parser.cc`'s
one-time `cell_list_lte` snapshot) and never revisited - not on a live `pmch_bandwidth`
`SET` (`control_server.cc` -> `rrc::reconfigure_embms()`), and not even if
`pmch_bandwidth` were set at startup instead, since nothing re-plans the main
CAS/PBCH/PSS/SSS `ifft[]` for the wider width either. `cc_worker.cc`'s own
`signal_buffer_tx`/`ifft_mbsfn` ARE already correctly `mbsfn_prb`-aware, but the extra
samples they generate are silently dropped every subframe by `sf_worker.cc`'s narrower
declared sample count before ever reaching the radio.

**Two fix attempts this session, both caused a worse regression (baseline cell search
broke entirely) and were fully reverted**:
1. Unconditionally provisioning `cell->mbsfn_prb` for the legal maximum (40 PRB) at
   config-parse time, plus widening `txrx.cc`/`sf_worker.cc` to match. This made
   `cell.mbsfn_prb != cell.nof_prb` unconditionally true, which some other code path
   (not yet identified) apparently uses as an "is MBSFN widening active" signal -
   baseline (`pmch_bandwidth=0`) cell search broke immediately.
2. A more careful attempt mirroring the RX's own solution: added
   `srsran_ofdm_tx_set_prb_symbol_sz()` (a TX-side equivalent of the RX's existing
   `srsran_ofdm_rx_set_prb_symbol_sz()`) to decouple the main CAS/PBCH `ifft[]`'s
   `symbol_sz` from its logical `nof_prb`, keeping content centred within a wider
   symbol - the same principle that works correctly on the RX side. Paired with
   `enb_baseline.conf` setting `pmch_bandwidth=40` at startup (to provision the frozen
   snapshot correctly) and the same `txrx.cc`/`sf_worker.cc` widening. This ALSO broke
   baseline cell search (still "Could not find any cell") - the TX-side PSS/SSS/PBCH
   generation apparently needs more than symbol_sz decoupling to stay correct within a
   widened symbol (unlike the RX, which only needs to *read* a wider symbol correctly;
   the TX must *generate* PSS/SSS/PBCH sequences at the exact right position within it,
   which may need its own dedicated centring logic this attempt didn't add).

Both attempts were fully reverted (`rt-mbms-tx`: `enb_cfg_parser.cc`, `txrx.cc`,
`sf_worker.cc`, `phy_common.h`, `enb_dl.c`, `ofdm.c`/`ofdm.h` all back to git HEAD;
`enb_baseline.conf`'s `pmch_bandwidth` back to unset) and baseline re-confirmed healthy
(CE diagnostics clean, dispatch correct, zero cell-search/readStream errors) before
ending this pass. **The actual TX-side fix remains open** - the root cause is now solid
and well-evidenced (see above), and two specific approaches are now known NOT to be
sufficient on their own, but a properly verified fix (most likely needing the TX's
PSS/SSS/PBCH generation to be made genuinely position-aware within a widened symbol,
not just FFT-size-aware) needs its own dedicated, carefully-tested session rather than
another rushed attempt.
