# Validation record — NscaleTX GB300 (2026-07-29)

Offline suite + evidence gathered on the live NscaleTX cluster. Recorded so the
numbers behind the thresholds are auditable.

---

## 1. Does this repo modify `llmb-run`? **No.**

Asked directly by the site team. The answer is verifiable from the tree:

- `lib/llmb.sh` header: *"the only place that knows how to talk to `llmb-run`"*.
  It **invokes** the CLI; it never writes into `$LLMB_INSTALL` or the
  `dgxc-benchmarking` checkout.
- Repo-wide search for writes into the llmb tree
  (`sed -i|cp|install|>|>>|patch` targeting `llmb_repo|dgxc-benchmarking|metadata.yaml|LLMB_INSTALL`)
  returns **nothing** outside `tests/`.
- `metadata.yaml` is not referenced anywhere in the repo.

What *did* change is the **caller**: work that used to be
`sbatch jobs/allreduce.sbatch` is now
`llmb-run submit -w microbenchmark_nccl -s nccl --dtype fp8 --scale <N> --force …`.
See `MIGRATION.md` §1 for the full command mapping. Recipes, container and
`llmb-run` itself are stock.

### Note on non-power-of-2 scales (why `--force` matters)

An 18-tray GB300 NVL72 rack is **72 GPUs**. Upstream `nccl/metadata.yaml` for
`gb300` ships scales `[4, 8, 16, 32, 64, 128, 256, …]` — **72 is not in the list**,
so a plain submit is rejected. This repo solves that with `scale_flag=force`
(`conf/workloads.conf` → `llmb-run --force`), which bypasses the scale whitelist
**without editing upstream recipe data**. That is the preferred approach: any
site tooling that instead patches `metadata.yaml` is modifying upstream and will
have the edit reverted by the installer's `git checkout -f` on the next run.

## 2. Offline test suite

`tests/run-tests.sh` → **37 passed, 0 failed** (no cluster required).
`tests/lint.sh` → clean over 31 shell files + `conf/workloads.conf`.

**Resolved during this validation: `test_interview_generates_a_working_config`.**
It failed at first, and the root cause was worth recording because it was a real
weakness in the detection heuristic, not just a fixture artefact.

The fixture `make_inventory()` builds uniform 18-node racks (`11-18, 28-37`),
while `setup()` also injects a 2-node foreign rack (`other01-11/12`) into
`partition.nodes` — deliberately, since `test_multi_rack_uses_exclude` needs a
node outside the group to appear in the exclude set. The rack-rule scorer in
`bin/interview.sh` only awarded points when **every** group was the same size
(`uniq_sizes == 1`), so one foreign 2-node rack made the *correct* rule score 0
and a wrong grouping won → `NODES_PER_RACK` ≠ 18.

That is not a fixture-only problem. Any real cluster with a login/utility node or
a partial rack in the same partition would have hit it, and the failure mode is
the bad kind: a plausible-looking `cluster.conf` with a wrong rack size, which
then builds wrong nodelists.

**Fix applied:** `NODES_PER_RACK` is now derived from the **modal** rack size
(`bin/interview.sh`, the `modal=` computation) rather than requiring total
uniformity, and racks that deviate from the mode are printed as a warning for the
operator to eyeball rather than silently discarding the rule. The uniformity
bonus is retained as a *tie-breaker* in the scorer, which is what it was
originally for. Suite is green, and `bin/interview.sh --non-interactive` standalone
and with `tests/mocks` on `PATH` both emit `NODES_PER_RACK=18`.

## 3. Measured GB300 bandwidth vs `conf/profiles/gb300-nvl72.conf`

Full 24-test `microbenchmark_nccl` sweep, **72 GPUs / 18 trays**, rack
`ink50-dh01-h03`, via `llmb-run submit` (job 65828, COMPLETED in 26m15s,
`#wrong=0` on every test). busbw = out-of-place, at the largest message size
(16 GiB) — the same definition the profile floors use.

| Collective | Profile floor | Measured | Margin |
|---|---|---|---|
| all_reduce | 820 | **916.84** | +11.8 % |
| reduce_scatter | 640 | **708.30** | +10.7 % |
| alltoall | 620 | **690.72** | +11.4 % |
| sendrecv | 625 | **686.84** | +9.9 % |
| all_gather | 620 | **646.78** | +4.3 % |

All five clear their floors, and the margins are tight enough that the floors
look correctly calibrated for GB300 NVL72 rather than arbitrary.

`PROFILE_GPUS_PER_NODE=4` × `PROFILE_NODES_PER_RACK=18` = 72 — matches the live
rack exactly.

### all_reduce is bimodal — the sweep contains both

The 6 all_reduce variants are `NCCL_NVLS_ENABLE=[0,1]` × `-G=[None,2,4]`:

```
NVLS off :  704.17   696.08   696.27
NVLS on  :  914.98   916.60   916.84
```

**NVLS is worth ~+31 %.** Anything that scores all_reduce from the *first* block
rather than the best will read ~700 GB/s and sit below the 820 floor — a false
FAIL on a healthy rack.

**Confirmed handled.** `llmb_nccl_peaks()` in `lib/llmb.sh` globs *every* sweep
file for a collective and passes them all to `nccl_peak_busbw()`, which tracks a
single running `peak` across all files, all message sizes, and both the in-place
and out-of-place `busbw` columns (columns located from the header, so the
13-column and 11-column `nccl-tests` layouts both work). The NVLS-on block
therefore wins, and the measured 916.84 above is what the scorer sees.

Note the parser is intentionally *more* permissive than the floor definition: it
takes the best of in-place and out-of-place rather than out-of-place only. That
biases toward passing, which is the right direction for an absolute floor whose
job is catching gross failures — the fleet-relative outlier gate (README §9) is
what catches the marginal rack. Anyone rewriting this parser must keep
"best block, not first block."

## 4. Environment gotchas confirmed on this cluster

- **`UCX_TLS=^tcp` is fatal inside the llmb/NeMo container.** The container
  exposes only tcp/IPoIB — no mlx5 verbs — so forbidding tcp leaves UCX with no
  transport: `ucp_ep_create … Destination is unreachable`, every rank Killed.
  This repo does **not** set `UCX_TLS`/`NCCL_IB_HCA`/`UCX_NET_DEVICES` — correct.
  Do not add them to `LLMB_EXTRA_ENV`.
- **Never pin `NCCL_IB_HCA` fleet-wide from a single node's probe.** Rail counts
  are per-node facts. On a rack where one tray is missing a rail, a pinned list
  makes NCCL open a device that does not exist there →
  `Detected mixed local CollNet device counts across ranks (min 3, max 4)` and
  the job aborts. Let each rank auto-detect.
- **Rail asymmetry still matters even unpinned.** `h03-12` and `h03-37` have 3 of
  4 compute rails (verified via sysfs: ACTIVE + InfiniBand + 800G, bond excluded).
  The llmb container path tolerated it; the host-mpirun path did not.
- **`sacct` is present** on the head node, so job tracking is not degraded to
  `squeue` (see MIGRATION.md "Known limitations").
