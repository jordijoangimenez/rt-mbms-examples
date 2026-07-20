- Once wideband PMCH decode genuinely works: re-run the actual verification this whole
  pass was for (`PMCH_RE_DUMP`/raw-IQ confirmation that content spans the full widened
  spectrum, MCCH/MTCH decode without CRC failures).
- Decide what to commit: the TX/RX rate-split fix, the FFT-sizing fix, the stale-TUN
  fix, and all three `chest_dl.c` fixes this pass are keepers regardless of outcome;
  the test-only `mbsfn_prb_test_override` and its config values are almost certainly
  NOT meant for commit (test-only scaffolding to bypass the SIB13-discovery chicken-
  and-egg deadlock, not needed in a real deployment where a real UE waits for SIB13
  naturally).

## Continuation pass, 2026-07-19 (dispatched continuation agent): root cause NOT found
## despite exhaustive isolation - narrowed to the live srsenb process's own IFFT
## execution; one real independent bug found and fixed; several dead-end hypotheses
## conclusively ruled out with hard evidence

Picked up directly from "the raw pilot phase-scrambling finding... not yet root-caused"
above. This pass did NOT find the fix. It DID produce the sharpest localization yet via
a chain of empirical tests, each one closing off a whole category of explanation. Full
honesty up front: CAS/PDCCH decode is still 0% at the end of this pass
(`pdcch_status`: `found=0`, `not_found_rate=1`, `total` climbing normally) - the wide
test config is left active per this campaign's standing setup, but wideband PMCH
verification is still blocked on this.

### Real, independent bug found and fixed: `chest_estimate_cfo()` had the same
### act_prb mixup already fixed elsewhere in this file

`chest_dl.c`'s `chest_estimate_cfo()` (used only for CAS, i.e. non-MBSFN, occasions -
feeds `chest_res.cfo` -> `CasFrameProcessor::process()`'s
`_phy.set_cfo_from_channel_estimation()` -> `srsran_ue_sync_set_cfo_ref()`, ue_sync's
own CFO tracking-loop reference) computed its slot-to-slot time span using
`n = srsran_symbol_sz(q->cell.nof_prb)` - the carrier's own native symbol size (512 for
this session's 25 PRB), not the REAL transform size CAS's `q->fft[port]` actually runs
at once `mbsfn_prb != nof_prb` (1024, `srsran_symbol_sz(mbsfn_prb)` - see
`srsran_ue_dl_set_cell_scs()` in `ue_dl.c`, fixed in an earlier pass). This is the exact
same "content width (nof_prb) vs. real transform size (mbsfn_prb when widened)"
distinction already fixed in `chest_dl_estimate_correct_sync_error()`'s `sz_se`/`sz_scs`
a few hundred lines below in the same file - this function was simply missed in that
earlier pass, since it computes a separate, independent CFO estimate, not `sync_error`.
Fixed the same way: `act_prb = q->cell.mbsfn_prb ? q->cell.mbsfn_prb : q->cell.nof_prb`,
`n = srsran_symbol_sz(act_prb)`.

**Confirmed via live A/B test that this is real but NOT the (sole) explanation for the
acute scrambling**: added a `CFO_FEEDBACK_DISABLE` env-gated skip around the
`_phy.set_cfo_from_channel_estimation()` call this bug's output feeds. Disabling it left
`sync_error` rock-stable from occasion to occasion (13.85, unchanging) instead of
slowly drifting (13.83 -> 15.33 over ~20s in the normal case) - confirming this feedback
loop (hence indirectly this bug) IS the source of a real, separate, slow, frame-to-frame
CFO-like drift. But `noise_estimate_dbm`/`snr_db`/`pdcch_status` were completely
unchanged (still `noise_estimate_dbm≈50.2`, `snr_db≈1.4-1.6`, `found=0`) - this bug does
not explain the acute per-subcarrier scrambling that's actually breaking PDCCH.

### New diagnostic finding: PSS shows the EXACT SAME scrambling as CRS - rules out
### anything CRS-specific, and rules out the "clean data region proves no corruption"
### reasoning from the previous pass

The previous pass's "data region looks clean (tight QPSK clusters), so a real physical
timing/CFO ramp is ruled out" reasoning was **wrong and is retracted**: PDSCH/PBCH data
is ALSO QPSK-modulated with scrambled (pseudo-random) bits, so it forms tight 4-point
clusters regardless of whether a hidden per-RE corruption is also present - clustering
by itself proves nothing about whether the channel is clean, only a KNOWN reference
signal can actually answer that.

Added `PSS_KNOWN_DIAG` (`CasFrameProcessor.cpp`, `process()`): for every CAS occasion at
`tti % 10 == 0` (a PSS-bearing subframe), regenerates the known PSS sequence locally
(`srsran_pss_generate()`, keyed only on `cell.id % 3` - a completely separate generator
from CRS's Gold-sequence-based `srsran_refsignal_cs_set_cell()`, no shared code at all)
and divides the 8 raw received PSS symbols (contiguous subcarriers, last symbol of the
slot, no comb spacing at all unlike CRS) by it. **Result: PSS shows the identical
signature CRS does** - magnitude consistently ~15-17 (real signal energy, matching
PSS's larger RE-boost/no-CFO-null-subcarrier vs. CRS's ~5) but phase scrambled by large,
inconsistent amounts between EVERY adjacent subcarrier (not just comb-spaced ones) -
e.g. one capture: `-34.1, -133.9, 22.3, -16.0, -68.2, 136.9, -126.6, -129.3` degrees for
k=0..7, no smooth trend at all. This is present from `tti=0` (the very first CAS
occasion ever processed at this width), ruling out any connection to the one-time
SDR-retune/cell-reconfigure block in `main.cpp` (~line 625-690).

**This conclusively rules out**: CRS reference generation, CRS extraction stride/
indexing, the LS division itself, and (independently, since PSS's own math is entirely
separate) narrows the search to something that corrupts the FFT-extracted grid as a
whole, not anything CRS-specific.

### Isolated, in-process ofdm.c TX->RX round-trip: mathematically and empirically
### PROVEN CLEAN for this exact config, in every variant tried

Wrote a standalone C test (`/tmp/.../ofdm_isolation_test.c`, `ofdm_resize_test.c`,
linked directly against the real built `libsrsran_phy.a`, no eNB/modem/ZMQ/threads at
all) that runs a TX `srsran_ofdm_t` (IFFT) directly into an RX `srsran_ofdm_t` (FFT) in
the same process's memory, nof_prb=25/symbol_sz=1024 (the exact CAS hybrid config).
Tried every variant that could plausibly differ from the real system:
- Fresh-init directly at the final config, sparse content (only 4 known CRS-like values
  populated, everything else zero): **perfectly clean** - all 4 positions recovered
  exactly, `rx/tx` ratio identically `1024.0 ∠0°` (the expected unnormalized-IFFT/FFT
  gain, `normalize=false` on both sides).
- Same, but with EVERY RE of every symbol densely populated with pseudo-random
  QPSK-ish content (mimicking a fully-loaded real subframe instead of a sparse test):
  **still perfectly clean**, identical ratio.
- Fresh-init at `MAX_PRB`/native size first (matching `srsran_enb_dl_init()`'s/
  `srsran_ue_dl_init()`'s actual startup lifecycle), THEN resize via
  `srsran_ofdm_tx_set_prb_symbol_sz()`/`srsran_ofdm_rx_set_prb_symbol_sz()` to
  nof_prb=25/symbol_sz=1024 (matching `srsran_enb_dl_set_cell()`'s/
  `srsran_ue_dl_set_cell_scs()`'s actual widen-branch call sequence, not a from-scratch
  init at the final config): **still perfectly clean**.

This independently confirms (this time by direct execution, not just manual derivation)
that `ofdm.c`'s mirror/dc/copy_pre/copy_post FFT-shift handling, `nof_guards`/`nof_re`
computation, and the CP-length arithmetic are ALL correct for this exact
nof_prb/symbol_sz combination, in every lifecycle/content-density variant a real system
could plausibly exercise. The bug is NOT in `ofdm.c`/`dft_fftw.c`'s logic.

### The decisive finding: the eNB's OWN transmitted samples are ALREADY scrambled when
### independently re-FFT'd, with the wire/RX system entirely out of the picture

Added `TX_CRS_DIAG_AFTER_PUT_REFS`/`TX_CRS_DIAG_BEFORE_IFFT` (`enb_dl.c`, already
existed from earlier in this pass) and `TX_TIME_DUMP` (`enb_dl.c`, new): dumps the
FINAL, actually-transmitted post-IFFT post-normalization time-domain samples for one
specific tti straight from `q->ifft[0].cfg.out_buffer` to a file. Captured tti=0 with
**both** `TX_CRS_DIAG_BEFORE_IFFT` and `TX_TIME_DUMP` active together (same log, back-
to-back lines, so guaranteed the same exact transmission instance):

```
TX_CRS_DIAG_BEFORE_IFFT tti=0 fidx0=1 vals=(0.7071,0.7071) (-0.7071,0.7071) (-0.7071,-0.7071) (-0.7071,-0.7071)
TX_TIME_DUMP tti=0 sf_len=15360 ...
```

i.e. confirmed (yet again) that `q->sf_symbols[0]` holds the exact expected clean CRS
values immediately before the IFFT runs. Then took the dumped `TX_TIME_DUMP` time-domain
samples and ran them through a **completely independent, freshly-built `srsran_ofdm_t`
RX object** (`fft_dump_check.c`, a small standalone tool, same library) - i.e. FFT'd the
eNB's own transmitted bytes directly from its own dumped memory, with the real RX
system, the wire, ZMQ, and SoapySDR entirely out of the picture. **Result: still
scrambled** - `fidx=1,7,13,19` came back as magnitude 16.384 (consistent - confirms real
signal, not noise) but phase `-95.63, -16.87, 61.87, 50.62` degrees - not matching the
known clean input (45, 135, -135, -135) under ANY constant rotation, and notably
`fidx=13`/`fidx=19` (which share the IDENTICAL reference value) disagree with each other
by 11 degrees. The SAME tool, fed the isolated test's own known-clean buffer instead,
correctly reproduces the expected clean 45/135/-135/-135 pattern - so the tool itself is
not the source of the discrepancy.

**This means the corruption is being introduced during the REAL, live `srsenb`
process's own execution of `srsran_ofdm_tx_sf(&q->ifft[0])` (`enb_dl.c`,
`srsran_enb_dl_gen_signal()`), in a way that a byte-for-byte equivalent standalone
reproduction (same library, same init-then-resize lifecycle, same dense content) does
NOT reproduce.** The wire/ZMQ/SoapySDR bridge/RX system are now OUT OF SCOPE for this
bug entirely - whatever it is, it happens before the samples ever leave the eNB process.

### Hypotheses tested and ruled out for "what's different about the live process"

- **Multi-threaded PHY worker race** (`nof_phy_threads` - each `cc_worker` has its own
  `srsran_enb_dl_t enb_dl` member, so no expected sharing, but tested directly anyway
  given the wider/slower 1024-point transform could plausibly widen a race window):
  set `nof_phy_threads=1` (config only, no rebuild), fresh restart both sides -
  **identical broken pattern** (`noise_estimate_dbm≈50.2`, `snr_db≈1.4-1.5`,
  `sync_error≈14-15`). Reverted to `4`. Ruled out.
- **Stale/corrupted FFTW wisdom file** (`~/.srsran_fftwisdom` - shared by BOTH the eNB
  and modem processes on this machine, since both link the same srsRAN FFT code and
  both have the same `__attribute__((constructor/destructor))` load/save hooks; a
  wisdom entry poisoned by an earlier session/build could in principle bias FFTW's
  algorithm selection for this exact size): deleted the file, fresh restart both sides
  (regenerates automatically) - **identical broken pattern**. Ruled out.
- ZMQ bridge (`~/soapy-zmq-bridge/ZmqRxDevice.cpp`) decimation path: confirmed `ratio=1`
  (native_srate=15.36e6 == requested sample_rate) for this whole test - the FIR
  decimator is never even invoked; `readStream()`/`rxThreadLoop()`'s ratio=1 path is a
  plain, whole-sample-aligned memcpy pipe. Not implicated (though this file's own
  extensive historical comments document real, already-fixed bugs in the ratio>1 path
  from an earlier, different investigation - not relevant here).
- `phase_compensation_hz`/`freq_shift_f` (`srsran_ofdm_cfg_t` optional fields that, if
  nonzero, apply an extra rotation in `ofdm.c`): grepped the whole TX and RX application
  code (`enb_dl.c`, `srsenb/src/phy/*.cc`, all modem `src/*.cpp`, `ue_dl.c`) - never set
  anywhere, stay at their zero-initialized default on both sides. Not implicated.

### Still-open next steps

- The bug is now known to live specifically inside the real, live `srsenb` process's
  execution path from `q->sf_symbols[0]` (confirmed clean) through
  `srsran_ofdm_tx_sf(&q->ifft[0])` to the dumped `q->ifft[0].cfg.out_buffer` (confirmed
  scrambled when independently re-FFT'd) - and does NOT reproduce in a byte-for-byte
  equivalent standalone harness using the identical library code, lifecycle, and
  content density. Whatever differs between "real running srsenb" and "standalone
  isolated reproduction" is the remaining thing to find. Candidates not yet tried:
  attaching a debugger/additional per-call instrumentation to the LIVE srsenb process
  at the exact `srsran_ofdm_tx_sf(&q->ifft[0])` call site (e.g. dump `q->tmp`,
  `q->fft_plan.p`/`.in`/`.out` pointer values, and `q->nof_guards`/`q->nof_re` on
  literally the live object, not an equivalent standalone one, right before and after
  the call) to see whether the LIVE object's own state actually matches what's assumed;
  checking whether some OTHER thread/subsystem in the real `srsenb` process (M3AP,
  GTP-U, the control_server, PRACH worker, or another `cc_worker` instance for a
  different carrier/subframe pipeline stage) could be touching `q->ifft[0]`'s memory
  region via some unrelated bug (heap corruption/buffer overflow elsewhere stomping on
  this object - a class of bug no amount of ofdm.c-focused reasoning would catch);
  building a debug/ASan-instrumented `srsenb` and reproducing live to catch a potential
  heap-corruption source directly.
- `chest_estimate_cfo()`'s fix and the diagnostics added this pass
  (`PSS_KNOWN_DIAG`, `TX_CRS_DIAG_AFTER_PUT_REFS`/`_BEFORE_IFFT`, `TX_TIME_DUMP`,
  `RX_TIME_DUMP`, `TX_SF_TYPE_DIAG`, `PILOT_REF_DIAG`, `PILOT_WIDE_DIAG`(+`_L1/L2/L3`),
  `PILOT_NDFT_DIAG`, `RAW_IQ_DUMP`+`RAW_IQ_DUMP_PILOT_STRIDE`) are real, independent
  keepers regardless of outcome - all `getenv()`-gated, inert by default.
  `SYNC_CORRECT_DISABLE`/`CFO_FEEDBACK_DISABLE` are confirmed-ruled-out kill-switches,
  kept as cheap regression-check tools with their comments updated to say so plainly.
- Revert `main_thread_priority_rt` to `20` once the SIGKILL trigger is understood or
  confirmed gone - still not investigated this pass, unchanged from before.

### Config state at time of writing
`enb_baseline.conf`: `pmch_bandwidth = 40` (wide test, active), `nof_phy_threads = 4`
(restored after the single-thread test above). `modem_zmqtest.conf`:
`mbsfn_prb_test_override = 40` (wide test, active), `main_thread_priority_rt = 0`
(still the temporary SIGKILL workaround, untouched, not yet reverted).
`receive-netns.sh`'s modem launch line: `CAS_CE_DIAG=1 PILOT_RAW_DIAG=1 RAW_IQ_DUMP=1
PSS_KNOWN_DIAG=1` (the other per-investigation diagnostics from this pass are available
but not enabled by default - see their own doc comments for the env vars needed).
Both eNB and modem left running in this config at the end of this pass.

## Further continuation, same day: two of the "not yet tried" candidates above tried -
## both came back clean; root cause still open

Picked up the two concrete candidates the previous section flagged as untried:
multi-object/multi-subframe-type interaction, and an ASan-instrumented live `srsenb`.
Both were tried. Neither found it. Also tried UBSan (not previously listed as a
candidate). Full honesty: **still open at the end of this pass too.**

### Multi-object interaction: ruled out

Extended the agent's own standalone `ofdm.c` round-trip test
(`/tmp/.../scratchpad/ofdm_multiobj_test.c`, kept alongside its `ofdm_isolation_test.c`/
`ofdm_resize_test.c`) to create BOTH a CAS-like object (nof_prb=25, symbol_sz=1024,
fresh-init-then-resize) AND an MBSFN-like object (mbsfn_prb=40, SRSRAN_SCS_1KHZ25,
symbol_sz=12288) in the same process, then ran a CAS round-trip (1) before the MBSFN
object even existed, (2) right after it was created but not yet run, (3) after 5 rounds
of active MBSFN TX/RX, and (4) interleaved with further MBSFN activity. This models the
real `srsenb`'s actual coexistence of `ifft[0]`/`ifft_mbsfn` (sharing FFTW's global
plan-creation mutex) far more closely than the single-object tests the previous pass
ran. **Result: CAS stayed perfectly clean in all four phases** (`ratio=1024∠0.00deg`
throughout, matching the expected unnormalized IFFT/FFT gain exactly). This rules out
"FFTW global state gets confused when multiple differently-sized plans coexist/
interleave" as the explanation.

Also re-verified by direct reading (not just re-trusting the earlier pass's conclusion)
that `q->ifft[0]`'s actual init lifecycle in the real system is exactly the 2-step
"fresh at nof_prb=25 (implicit symbol_sz=512) inside `srsran_enb_dl_set_cell()`, then
widened to symbol_sz=1024" the standalone tests already modeled - `srsran_enb_dl_init()`
(called once, at `cc_worker` startup, with `max_prb=dl_max_prb=40`) only initializes
`q->ifft_mbsfn` (CP_EXT, SCS_1KHZ25) at that call; `q->ifft[0]` is untouched until
`srsran_enb_dl_set_cell()` runs. No hidden third resize step.

### AddressSanitizer: clean

Built a separate `rt-mbms-tx/build-asan` directory (`cmake -DENABLE_ASAN=ON
-DCMAKE_BUILD_TYPE=RelWithDebInfo`, already a supported first-class CMake option in
this repo - no manual flag hacking needed), built just the `srsenb` target, ran it live
against the real modem for a sustained period with the wide test config active.
**Zero ASan reports of any kind**, in any file, for the entire run - despite
`CAS_CE_DIAG` confirming the usual failure signature was present throughout
(`noise_estimate_dbm≈+50.2`, `snr_db≈1.4-1.6`, `sync_error≈14-15`). Since ASan reports
on the very first offending access, and many CAS occasions were processed, this is
fairly strong evidence against a classic heap/stack buffer overflow or use-after-free
anywhere in the process, not just in the PHY/CAS/PMCH code path specifically.

### UndefinedBehaviorSanitizer: clean in the relevant code, noisy everywhere else

Built `rt-mbms-tx/build-ubsan` combining `-fsanitize=address,undefined` (plus the
existing repo's own `-Wno-error=...` suppressions for known-benign warnings that
`-Werror` would otherwise turn fatal, e.g. `stringop-overflow` in generated ASN.1
`dyn_array` code). First run used `-fno-sanitize-recover=undefined` (abort on first
violation) and immediately died on a **pre-existing, unrelated** startup-time issue:
a null-pointer reference bind while copying an empty ASN.1 octet string
(`sib_type13_r9_s::operator=`, `srsenb::rrc_cfg_t::operator=`,
`enb_stack_lte::init()`) - nothing to do with CAS/PMCH, just a latent, harmless (empty
container `operator[]`) pattern this codebase has apparently never been run under
UBSan before to notice. Rebuilt with `UBSAN_OPTIONS=halt_on_error=0` to log-and-continue
instead. Once past startup, one PHY-side finding fired: a misaligned 16-bit store in
`srsran_bit_interleaver_run` (`lib/src/phy/utils/bit.c:127`), reached via
**PDSCH** encoding (`cc_worker::encode_pdsch` -> `srsran_pdsch_encode` ->
`srsran_dlsch_encode2` -> `srsran_rm_turbo_tx_lut`) - a completely different code path
from CAS/PMCH/CRS/PSS, and one x86 tolerates at the hardware level regardless (UBSan
flags it as technically UB per the C standard; it's not what's breaking this feature).
Otherwise, a long tail of **pre-existing, unrelated** alignment/null-reference findings
across S1AP/GTPU/RRC/network_utils/a custom intrusive-list `node`/`pooled_node` type -
none in `enb_dl.c`, `ofdm.c`, `chest_dl.c`, `refsignal_dl.c`, `pss.c`, or `cc_worker.cc`'s
CAS/PMCH-relevant methods, despite `CAS_CE_DIAG` confirming the failure was actively
reproducing throughout the run. **No new lead from UBSan either.**

### Also directly re-verified this pass (by reading, not just re-citing): PSS placement

`srsran_pss_put_slot()` (`lib/src/phy/sync/pss.c:372`) - the previous pass's report that
PSS shows the identical corruption signature CRS does was already strong evidence
against anything CRS-specific, but this pass additionally confirmed PSS's own
*placement* function (as opposed to just its Zadoff-Chu *generation*) is exactly as
narrow/correct as CRS's: uses only the `nof_prb` parameter passed in
(`q->cell.nof_prb`), no `mbsfn_prb` reference anywhere. Between this and the earlier
confirmation on `refsignal_cs_get_sf`/`_put_sf`/`_fidx`/`_nsymbol`/`_v`, every actual
content-placement function for both known reference signals is confirmed clean. If the
bug is a placement/indexing bug at all, it would have to be in something shared by both
signal types AND not caught by the ofdm.c isolation tests - increasingly narrowing to
"something about the live process specifically" rather than any single function's
logic.

### Where this leaves it

Ruled out, cumulative across both passes: retune timing, TX/RX FFT sizing and CP/guard-
band scaling, `_ue_sync`'s sizing and its own tracked offset state, CRS and PSS
generation AND placement (both signals, independently), FFTW plan replan attribute
persistence, multi-object/interleaved-subframe-type FFTW interaction, classic memory-
safety bugs (ASan), and a broad class of undefined-behavior bugs (UBSan). Four real,
independent bugs found and fixed along the way (kept regardless). The paradox from the
previous pass stands unresolved: the eNB's own pre-IFFT content is confirmed correct,
the IFFT operation is confirmed correct in every isolated reproduction tried so far
(including ones deliberately designed to match the live system's exact object
coexistence and lifecycle), yet the live process's actual output is confirmed
corrupted. Remaining untried candidates: a ThreadSanitizer pass specifically (checks a
different bug class than ASan/UBSan - a race condition - but carries real risk of its
much higher overhead breaking real-time ZMQ transmission timing and producing a
misleading trail; would need its own from-scratch build, ASan+TSan can't combine); or
attaching a debugger directly to the live process at the exact
`srsran_ofdm_tx_sf(&q->ifft[0])` call site to inspect the live object's actual internal
state (`q->tmp`, `q->fft_plan.p`/`.in`/`.out`, `q->nof_guards`/`q->nof_re`) in place,
rather than an equivalent standalone object.

### Config/build state at end of this pass
Both eNB and modem stopped (mid-investigation pause). `rt-mbms-tx/build-asan/` and
`rt-mbms-tx/build-ubsan/` are separate, additional build directories (not touching the
normal `rt-mbms-tx/build/`) - safe to keep for a future continuation or delete if
disk space matters. `enb_baseline.conf`/`modem_zmqtest.conf` unchanged from the state
described in the section above (wide test config, `main_thread_priority_rt=0` workaround
still in place, still not reverted).

## Continuation pass, 2026-07-19 (later same day): root cause found and fixed - the
## "CAS phase-scrambling" mystery was a test-tool bug, not a real defect; the actual
## BLER=1.0 blocker was a MAC-scheduler/PHY-muting gap, now fixed and confirmed

Picked up directly from the previous pass's unresolved state (root cause of the
widened-`pmch_bandwidth` corruption still open, redesign implemented but not yet
proven to fix anything). This pass found and fixed the actual root cause of the whole
campaign's core problem. Full honesty up front: **PMCH/MTCH decode now works** -
`pdcch_status` 100%, MCH BLER ~2.2-2.3% (down from 100%), confirmed stable over
hundreds of samples. One unrelated pre-existing crash found and flagged, not fixed.

### Finding 1: `srsran_enb_dl_set_mbsfn_subcarrier_spacing()` was silently re-narrowing
### `ifft_mbsfn` back to `nof_prb`, undoing `srsran_enb_dl_set_cell()`'s correct wide sizing

This function (`rt-mbms-tx/lib/src/phy/enb/enb_dl.c`), called lazily from
`cc_worker.cc` on the first actual MBSFN subframe, defaulted `ofdm_prb = q->cell.nof_prb`
and only widened for the special-cased 0.37 kHz SCS branch. For 1.25 kHz SCS (what
this test actually uses), `ofdm_prb` stayed at `nof_prb` (25), silently re-narrowing
`ifft_mbsfn` from the correct wide (40 PRB) sizing `srsran_enb_dl_set_cell()` had
already established at `cc_worker` startup. This bug was completely independent of the
CAS/PMCH FFT-sharing architecture question the previous pass spent a full day on -
explaining why *both* the old (shared-widened-FFT) and new (decoupled) architectures
showed the identical symptom (`ifft_mbsfn`'s actual PMCH content generation was broken,
at the wrong width, on both, since this function was never touched by the redesign).
Fix:
```c
// BEFORE:
uint32_t ofdm_prb = q->cell.nof_prb;
if (SRSRAN_SCS_IS_370HZ(subcarrier_spacing)) { ofdm_prb = ...; }
// AFTER:
uint32_t ofdm_prb = SRSRAN_MAX(q->cell.nof_prb, q->cell.mbsfn_prb);
if (SRSRAN_SCS_IS_370HZ(subcarrier_spacing)) { ofdm_prb = (ofdm_prb <= 75u) ? ofdm_prb : 75u; }
```
Confirmed via a temporary `IFFT_MBSFN_STATE_TRACE` diagnostic: before the fix,
`ifft_mbsfn.cfg.nof_prb=25` (wrong); after, `nof_prb=40, symbol_sz=12288,
mbsfn_sf_len=15360` (correct). This alone took MCCH/SIB13 decode from broken to fully
working and was the first big win of this pass.

### Finding 2: the entire "CAS phase-scrambling" investigation (previous pass, ASan/
### UBSan, multi-object tests) was chasing a bug in the VERIFICATION TOOLING, not a
### real defect in the transmitted signal

After Finding 1's fix, CAS/PDCCH was *still* failing (`pdcch_status` ~2% found). Traced
this using the same `fft_dump_check`-style standalone re-FFT tool the previous pass
built - but that tool hardcoded `SRSRAN_CP_NORM`, while this cell's actual
configuration is `extended_cp = true` (`enb_baseline.conf`). Extended CP has 6
symbols/slot with a uniform CP length, not 7 with the normal split - a completely
different symbol/window boundary layout. Re-running the exact same captured TX buffer
with the CP setting corrected to `SRSRAN_CP_EXT`: CRS at fidx 1/7/13/19 recovered
**exactly** 45.00°/135.00°/-135.00°/-135.00° (matching the known pre-IFFT reference,
uniform magnitude), and PSS showed a clean, structured phase pattern - not chaos. **The
eNB's transmitted signal was clean all along.** The previous pass's entire "isolated
ofdm.c round-trip is clean but the live process's real transmitted samples are already
scrambled" conclusion was an artifact of its own verification tool's CP mismatch, not a
real defect. This does not mean the earlier ASan/UBSan/multi-object work was wasted -
it correctly ruled out several real hypothesis classes - but the specific "IFFT
execution corrupts content" conclusion does not hold.

### Finding 3: chest_dl.c's `chest_dl_estimate_correct_sync_error()` CAS branch was
### actively corrupting CAS content - obsolete leftover from the abandoned
### shared-widened-FFT architecture

With Finding 2 ruling out a transmitted-signal defect, the remaining question was why
`pdcch_status` still failed. Live A/B test: setting `SYNC_CORRECT_DISABLE=1`
(an existing kill-switch, previously "confirmed ruled out" in the *old* architecture)
took `pdcch_status` from ~2% to 490/490 (100%) found, with `noise_estimate_dbm`/`snr_db`
simultaneously returning to physically-sensible values. Root cause: CAS's own
`fft[port]` is now permanently narrow (this session's redesign) - a completely
standard, unwidened LTE transform with no more need of a "sync error" correction than
any ordinary non-FeMBMS cell. This function's CAS-branch `act_prb`/`nre`/`nsymb`
formulas still reflected the abandoned widened-FFT architecture and were measuring/
correcting against the wrong transform size, actively corrupting otherwise-clean CAS
content. Fix: skip the CAS branch entirely (both measurement and correction) at
function entry - `if (sf->sf_type != SRSRAN_SF_MBSFN) { return; }` - leaving the MBSFN
branch untouched (it may still have a genuine need for this correction - see Finding
5). Confirmed: `pdcch_status` 100% (494/494), `sync_error` correctly reads 0.0000 for
CAS (measurement now skipped entirely, as intended).

*(Aside, tried and reverted during this investigation: removing the resampler's
per-occasion `reset_state()` call, on the theory that a "cold start against phantom
zero history" was the cause. Made zero measurable difference - proving the resampler
delay is a structural/permanent property of the filter, not a cold-start transient.
Reverted has no effect either way; left removed since it's arguably more correct
regardless.)*

### Finding 4: `MbsfnFrameProcessor`'s CE/CIR dashboard canvas used the wrong (15 kHz)
### symbol-size formula for a 1.25 kHz cell - the visual "frequency notches"/"25 PRB
### instead of 40" the user spotted

`MbsfnFrameProcessor::set_cell()` sized its CE/CIR display canvas with
`srsran_symbol_sz(_cell.nof_prb)` - the plain 15 kHz-numerology table - even though
MBSFN here runs at 1.25 kHz (true `symbol_sz=12288` for 40 PRB, not 1024). This 12x
undersized canvas meant `ce_values()`/`cir_values()` read only the first ~1/12th of the
real `chest_res.ce[]` array and IFFT'd it at the wrong transform size - exactly the
periodic comb/notch pattern visible on the CE waterfall and CIR dashboard panels, and
the "PMCH acquired at 25 instead of 40" appearance. This is a **display-only** bug -
actual PMCH decode uses `_pmch_cfg.pdsch_cfg.grant.nof_re` against the full-size `ce[]`
array directly, unaffected. Fixed using `srsran_symbol_sz_scs()` and
`SRSRAN_NRE_SCS(_ue_dl.subcarrier_spacing)` throughout instead of the hardcoded 15 kHz
assumptions. Confirmed: CE canvas now correctly 12288 samples wide with exactly 5760
active REs (=40 PRB x 144 RE/PRB) at a flat ~35.5-36.0 dB.

### Finding 5: MBSFN sync-error correction, force-disabled since 2026-07-14, is stable
### again and meaningfully improves the CIR - re-enabled

`MbsfnFrameProcessor`'s chest_cfg explicitly set `sync_error_enable=false`, with an
extensive comment describing why: back then, the estimator's measured values ran into
the hundreds (e.g. -427, 311, -348) for MBSFN's `nsymb=1` case, and its "correction"
actively corrupted data/pilot REs, root-caused as the primary cause of a
~99.6-99.75% CRC failure. Given everything fixed today (Findings 1-4), re-tested this
empirically rather than assuming it still applies: `SYNC_ERR_DIAG` now shows a
rock-stable measurement of ~-14.00 samples (std-dev <0.02 across many subframes) at
the current wideband config - not the wild pre-fix values. Enabling the correction
moves the MBSFN CIR's main tap to exactly lag 0 (previously off-center by ~14 samples)
and substantially reduces - though does not fully eliminate - a periodic ripple. Does
not change MCH BLER either way (confirmed separately, still 1.0 at the time, before
Finding 7's fix). Re-enabled permanently; the comment explaining the original 2026-07-14
disable is preserved alongside the new finding for future reference.

### Finding 6: PMCH's EVM was a dead field, always 0/NAN - added real computation,
### which is what pointed at the actual remaining bug

`srsran_pmch_decode()` never called anything analogous to `pdsch.c`'s own
`srsran_evm_run_s()` - `srsran_pdsch_res_t::evm` stayed at its zero-initialized default
for every PMCH decode, a genuinely dead diagnostic field despite the REST API/dashboard
already having plumbing to display it (`_rest._mch[idx].evm_rms`). Added: `evm_buffer`
member on `srsran_pmch_t` (alloc/free mirroring `q->d`/`q->e`'s own lifecycle,
sized from `q->max_re` at the worst-case 256QAM bit rate), and a real
`srsran_evm_run_s()` call right after the existing soft-demodulate call in
`srsran_pmch_decode()`, before descrambling touches `q->e`. First real reading:
`evm=0.951` (95% RMS error) - despite Findings 1-5 all being genuine, confirmed fixes,
the actual data path was still producing near-noise-level equalized symbols. This
directly falsified the "maybe it's just a residual channel-estimate ripple" hypothesis
(that would show as a smaller, non-catastrophic EVM) and redirected the investigation
correctly to Finding 7.

### Finding 7 (the actual root cause of BLER=1.0): MAC almost never grants MTCH at this
### bandwidth, and the eNB was retransmitting stale buffer content instead of silence
### on the idle subframes - THE FIX

Traced the 95% EVM by comparing raw received symbols against the channel estimate
(`raw[i]/ce[i]` vs the actual equalized `d[i]` - confirmed the equalization arithmetic
itself is correct, matching exactly for every index checked) and mapping magnitude
across the full 4800-RE grant: **strong, consistent signal (~61) for indices 0-2999,
then an abrupt 30x drop to ~2.0 from index 3000 onward.** 3000/4800 = 62.5%, and 62.5%
of 40 PRB = exactly 25 PRB. The eNB was only ever transmitting real PMCH data across
the original 25-PRB carrier - never the widened 40-PRB allocation it signals in SIB13
and correctly sizes its FFT for (Finding 1).

Root cause, confirmed via `PMCH_TI_DIAG` on the live eNB: `cc_worker::encode_pmch()`
early-returns (without calling `srsran_enb_dl_put_pmch()` at all) whenever MAC sets
`grant->dci.rnti=0` ("nothing to actually transmit this subframe"). Live count for a
single matched eNB/modem run: **21782 calls with `rnti=0x0` vs only 35 with a real
grant (0.16%)**. Traced into `mac::build_mch_sched()`: when queued content is *less*
than a scheduling period's capacity (`sfs_per_sched_period * bytes_per_sf`), it
schedules just enough subframes to drain what's queued, then leaves the rest of the
~623-subframe period idle. Since `pmch_bandwidth=40` makes `bytes_per_sf` far larger
than at 25 PRB, the same test content source drains almost instantly into a 40-PRB
pipe - a legitimate, expected consequence of testing wideband capacity against a
narrower content source, not a scheduling bug per se.

The actual bug: `srsran_enb_dl_gen_signal()` unconditionally IFFTs `sf_symbols` for
*every* MBSFN subframe regardless of whether fresh content was written this occasion -
so an idle occasion (no MAC grant) was retransmitting whatever the *last real* PMCH
encode had written there, not silence. The receiver's own DTX/idle detection
(`MCHIDLE`, power-threshold based) should catch idle occasions and skip counting them,
but for this same matched run it only recognized ~52% of subframes as idle
(`416802 MCHIDLE` vs `378519 MCHDIAG`) - the other ~48% still looked like a real,
powered signal worth attempting to decode, and correctly failed every time (it's
stale/wrong-TB content, not this subframe's actual data) - inflating BLER on subframes
that were never really scheduled at all.

**Fix** (`rt-mbms-tx/srsenb/src/phy/lte/cc_worker.cc`, `encode_pmch()`'s existing
`rnti==0` early-return branch):
```c
if (!grant->dci.rnti) {
  srsran_vec_cf_zero(enb_dl.sf_symbols[0], enb_dl.ifft_mbsfn.nof_re);
  return SRSRAN_SUCCESS;
}
```
Sized from `ifft_mbsfn.nof_re` - the exact frequency-domain RE count that object's own
IFFT reads for the current `mbsfn_prb`/SCS, so this covers precisely what would
otherwise be written, no more/less. Zeroing the RE grid makes an idle occasion transmit
genuine silence, letting the receiver's existing power-based DTX detection correctly
recognize it instead of attempting a doomed decode.

**Confirmed live, stable, matched eNB/modem pair, no regression:**
- `pdcch_status`: 100% (1235/1235).
- MCH BLER: **~0.022-0.023** (down from 1.0), stable across 10+ consecutive samples.
- This is the actual fix for the entire campaign's core "wideband pmch_bandwidth PMCH
  won't decode" problem.

### Separately found, not fixed: a pre-existing modem crash unrelated to today's work

During testing, the modem process crashed once:
```
/usr/include/c++/15/bits/stl_vector.h:1263: std::vector<...>::operator[](size_type):
Assertion '__n < this->size()' failed.
```
This is a `std::vector<std::string>` out-of-bounds access, most likely in
`main.cpp`'s CSV/measurement-file report-building code (`cols.emplace_back(...)`
sequences building rows of inconsistent length across different `if`/`else` branches -
seen near `main.cpp:1120-1135`), though not confirmed with a full backtrace. Not
blocking (measurement_file is disabled by default in this test's config, so the exact
trigger condition isn't yet understood) and unrelated to any change made this pass -
flagged for a future, dedicated investigation with a debug build/core dump.

### Config/build state at end of this pass
Both eNB (PID varies across restarts during this pass, last confirmed working
instance) and modem running, wideband config (`pmch_bandwidth=40`,
`mbsfn_prb_test_override=40`) active, confirmed working end-to-end. Still pending:
revert `main_thread_priority_rt` to 20 (long-standing, unrelated temporary SIGKILL
workaround, still not investigated), decide commit scope (this pass's fixes are all
keepers; test-only scaffolding like `mbsfn_prb_test_override` is not meant for commit),
remove/decide fate of temporary diagnostics accumulated across this and prior passes
(`IFFT_MBSFN_STATE_TRACE`, `TX_TIME_DUMP_NARROW`/`RX_TIME_DUMP_NARROW`, several others -
all `getenv()`-gated and inert by default, safe to leave or remove at leisure).
`rt-mbms-tx/build-asan/`, `rt-mbms-tx/build-ubsan/` still present from the prior pass,
still safe to keep or delete.

### Follow-up, same day: Finding 7's mute fix regressed the CE/CIR panels (real pilots
### were being zeroed too), and fixing that regressed BLER back to 1.0 - both now fixed

The user caught this live on the dashboard immediately: the MBSFN CIR panel went
completely empty (stuck at the -80dB floor) after Finding 7's fix landed.

**Regression cause**: `enb_dl.c`'s `put_refs()` writes MBSFN reference signals
(`srsran_refsignal_mbsfn_put_sf()`) into the same `sf_symbols` buffer independently of
PMCH data encoding - real FeMBMS/LTE requires these on *every* MBSFN subframe
regardless of whether user data is present, specifically so receivers can maintain
channel estimation through idle occasions. Zeroing the *entire* RE grid in
`encode_pmch()`'s early-return also wiped these pilots, so the receiver's
`chest_res.ce[]` went completely empty on the ~99.8% of subframes that are now (rightly)
muted. Fixed by re-writing the reference signals immediately after the zero-fill,
mirroring `put_refs()`'s exact call - safe and idempotent regardless of call order:
```c
srsran_vec_cf_zero(enb_dl.sf_symbols[0], enb_dl.ifft_mbsfn.nof_re);
srsran_refsignal_mbsfn_put_sf(enb_dl.cell, 0, enb_dl.csr_signal.pilots[0][tti % 10u],
    enb_dl.mbsfnr_signal.pilots[0][sf_idx], enb_dl.sf_symbols[0], scs, tti);
```
Confirmed: CIR peak now exactly at lag 0, CE canvas populated correctly again.

**That fix's own regression**: restoring real pilots reintroduced a small, genuine
amount of pilot-to-data leakage into the equalized "empty" data REs - measured live at
`datapw=0.0010-0.0012`, just barely above the existing DTX/idle-detection threshold in
`MbsfnFrameProcessor.cpp` (`data_pw < 1e-3f`). This pushed MCH BLER back to 1.0 on
exactly the subframes with this marginal leakage. Widened the threshold to `1e-2f` -
still two full orders of magnitude below the ~1.0 real-content level (confirmed
0.9997-1.0002 on genuine decodes), so no risk of masking real failures.

**Confirmed, final, stable state** (matched eNB/modem pair, extended observation):
- `pdcch_status`: 100% (1311/1311).
- MCH BLER: **0.0**, `MCH TOTAL ERRORS: 0`, stable across 10+ consecutive samples.
- CIR (both CAS and MBSFN): correct single peak at lag 0, no comb/floor artifacts.

This is now the fully-working, end-to-end confirmed state for wideband
`pmch_bandwidth=40` at `n_prb=25`: signaling, CAS/PDCCH, and PMCH/MTCH data decode all
working, all live-verified, not just theorized.

## Continuation pass, 2026-07-20: REST API crash fix, waterfall display fixes, and a
## thorough but inconclusive MCCH EVM ripple investigation

### REST API crash fixed: `mch_status`/`mch_data` indexed `paths[1]` with no bounds check

A bare (no-index) request to either endpoint (`RestHandler.cpp`) crashed the whole
modem process via an out-of-bounds `std::vector` access, matching a "pre-existing
modem crash" flagged earlier this campaign as unconfirmed. Root-caused this pass by
triggering it directly. Fixed with a `paths.size() < 2` guard, same convention already
used elsewhere in the file.

### Waterfall display: two real fixes, not root causes of any signal-quality issue

1. All four CE/CIR waterfalls (`modem.js`) redrew on every 100ms poll regardless of
   whether the backend snapshot had actually changed. Since MBSFN's own CE/CIR buffer
   only updates every `CE_CIR_UPDATE_STRIDE=10` occasions (itself irregular, since real
   PMCH occasions at this wideband config are sparse per Finding 7), most polls were
   redundant redraws of stale data: this reads as a solid "burst" then a sharp
   "discontinuity" on the next real update, resembling a channel artifact while being
   purely a display-refresh-rate mismatch. Fixed: skip the redraw when the fetched
   snapshot is byte-identical to the last one.
2. The CAS and MBSFN frequency waterfalls used mismatched, uncorrelated x-axis scales
   (CAS at 12 REs/PRB native resolution, MBSFN at 144 REs/PRB for 1.25kHz, a 12x
   difference). Exposed the true configured PMCH width as a new `mbsfn_prb` REST field
   and rescaled CAS's real band by the actual PRB ratio before centering it within
   MBSFN's wider canvas, so the two occupied-bandwidth widths now render proportionally
   correct (e.g. 25 vs 40 PRB visibly different, matching reality) rather than either
   mismatching scale or shrinking to invisibility.

### MCCH EVM ripple: real, reproducible, root cause still not found after five tested
### hypotheses

User-spotted pattern on the live dashboard: MCCH's own EVM (`_rest._mcch.evm_rms`,
directly assigned from `pmch_dec.evm` on every decode, not an accumulating average)
sits at a rock-stable ~4.66% baseline but jumps intermittently to 4.7-16.3%, roughly
every few hundred ms to a few seconds, with no clean fixed period. Every jump shows the
same physically-consistent signature: raw power (`rxpwr`) ticks up slightly while
channel-estimate power (`cepw`) and RSRP drop, post-equalization data power (`datapw`)
rises above its normal 1.0000, and `sync_error` deviates from its steady -14.015 (though
not proportionally to the EVM jump's size). This is a genuine intermittent degradation
of channel-estimate coherence for one isolated occasion, not random noise and not (per
BLER staying 0.0 throughout every observation) currently a functional failure.

Five hypotheses, each tested live with real captured data rather than assumed correct,
all ruled out:

1. **`ZmqRxDevice.cpp`'s periodic (~5s) occupancy/throughput log**, running inline on
   the SCHED_RR-50 receive thread that feeds the ring buffer the PHY blocks on (the
   exact same disease as an already-fixed, unrelated "Dropping spurious MCCH-LCID SDU"
   debug-log-at-1kHz bug in the same file, just a lower-frequency call site nobody had
   audited for this). First correlation looked clean: the MCCH occasion immediately
   BEFORE each log print was consistently elevated across 15 occurrences. Moved the log
   to its own thread (a real improvement on its own merits, kept), then re-tested: bumps
   continued at a similar or higher rate, with the correlation now landing on the
   occasion AFTER the print instead of before. Ruled out; the original correlation was
   most likely coincidental (two independent ~5s-ish periodic events drifting in and out
   of phase).
2. **`MbsfnFrameProcessor`'s own `CE_CIR_UPDATE_STRIDE` computation**, running inline on
   the same worker thread immediately after decoding, before that worker is free for the
   next occasion (a same-thread, directly-causal mechanism, no cross-thread race
   needed). Added a `CIRSTRIDE_DIAG` print at the exact trigger point and correlated
   directly against `MCCHDIAG`: only 2 of 10 stride events were followed by an elevated
   MCCH reading, and several clear bumps had no stride event anywhere near them. Ruled
   out.
3. **Coarse system-level CPU-frequency variance.** This machine is bare metal (confirmed
   via `systemd-detect-virt`), all 32 cores run the `powersave` governor, current
   frequencies span 800MHz to 5+GHz at any given moment, and the modem's real-time
   threads have no CPU affinity set (floating freely across cores per `ps -T ... -o
   psr`). Sampled per-core frequency spread (`nlow` = cores under 1GHz) every ~300ms
   alongside timestamped `MCCHDIAG` lines: `nlow` at bump moments (7, 7, 9, 6, 4, 10)
   was statistically indistinguishable from `nlow` at non-bump moments (2 through 10,
   same range). Ruled out at this granularity; a genuine per-thread-core frequency test
   would need sub-millisecond resolution this polling approach cannot reach.
4. **The occasion's own processing duration.** Added high-resolution
   (`std::chrono::steady_clock`) timing directly in `MbsfnFrameProcessor::process()`,
   measuring both wall-clock duration of the call and the interval since the previous
   call, printed in `MCCHDIAG` as `durationus`/`intervalus`. Across 81 samples, bump mean
   duration (227.7us) was only mildly higher than normal mean (183.4us), and the ranges
   overlapped completely: one clear bump (6.5% EVM) had the *shortest* duration (85.1us)
   in the entire dataset. If a processing-time delay were the cause, the fastest-
   processed occasion should be the last place to see a bump. Ruled out.
5. **Sample-alignment shift** (a residual timing/CFO error, which would show as a
   linear phase ramp across RE index in the channel estimate). Added `ALIGN_DUMP`: dumps
   the raw post-FFT RE grid and channel estimate for an occasion whenever `evm` crosses
   0.055, plus the immediately following occasion as a paired baseline, capped at 6
   pairs. Computed `ce`'s unwrapped phase slope across RE index for all 12 dumps: every
   single one, bump or normal, came back at order 1e-6 to 1e-5 rad/RE, i.e. no
   detectable ramp at all. Ruled out specifically as the visible mechanism. The
   equalized-symbol magnitude spread (`raw[i]/ce[i]`, the same technique that found
   Finding 7) was 20-25% higher on genuine bumps versus genuine baseline in the three
   clean pairs, but that is a restatement of the EVM elevation itself, not a new causal
   finding.

**Left in place, all env-gated and inert by default**: `ZMQRX_DUMP` (bounded one-shot
raw wire capture, `soapy-zmq-bridge/ZmqRxDevice.cpp`), `CIRSTRIDE_DIAG`, the
`durationus`/`intervalus` fields (folded into the existing `MCH_DIAG` gate), and
`ALIGN_DUMP` (all `rt-mbms-modem/src/MbsfnFrameProcessor.cpp`). None reproduce the root
cause; all are cheap, bounded, and may be useful starting points for a future pass.

**Not yet tried**: a genuinely sub-millisecond, per-thread-core frequency/migration
trace (hypothesis 3's polling resolution was three orders of magnitude too coarse to
rule this out properly); comparing the exact captured sample window itself (not just
its FFT/phase-domain summary) against a reference sync point for bump versus non-bump
occasions.
