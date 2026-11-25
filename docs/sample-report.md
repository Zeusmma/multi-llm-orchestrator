<!-- Illustrative report in the format written by `orchestrate.sh run ... --mode route`. Numbers are fictional. -->
# Orchestrator report - 2025-01-15

- Mode: **route**
- Tasks: **6**, succeeded: **6**
- Peak hours are computed in the PEAK_TZ time zone (Mon-Fri 09-12, 14-18).

## Tasks

| Task | Tier | Final model | Attempts (chain) | Escalations | Seconds | Exit |
|---|---|---|---|---|---|---|
| summarize-a | light | ag-model-fast-low | ag-model-fast-low | 0 | 14 | 0 |
| summarize-b | light | ag-model-fast-low | ag-model-fast-low | 0 | 11 | 0 |
| classify-tickets | medium | ag-model-fast-high | ag-model-fast-medium → ag-model-fast-high | 1 | 42 | 0 |
| refactor-plan | strong | ag-model-strong-low | ag-model-strong-low | 0 | 88 | 0 |
| review-contract | critical | ds-model-fast%low | ag-model-strong-medium → ag-model-strong-high → ds-model-fast%low | 2 | 131 | 0 |
| translate-faq | light | ds-model-fast%low | ag-model-fast-low → ag-model-fast-medium → ds-model-fast%low | 2 | 37 | 0 |

## DeepSeek tokens and estimated cost

| Task | Model | input | cache_read | output | Peak | Cost |
|---|---|---|---|---|---|---|
| review-contract | ds-model-fast%low | 5120 | 18432 | 2210 | off-peak | 0.0114 |
| translate-faq | ds-model-fast%low | 1840 | 0 | 960 | off-peak | 0.0038 |

Total estimated DeepSeek cost: **0.0152**

Antigravity attempts: 9 (run on a daily quota, no per-token cost).

## Today's usage (against limits)

| Model | Usage | Limit | Status |
|---|---|---|---|
| ag-model-fast-high | 1 | 50 | available |
| ag-model-fast-low | 3 | 50 | available |
| ag-model-fast-medium | 2 | 50 | available |
| ag-model-strong-high | 1 | 5 | available |
| ag-model-strong-low | 1 | 20 | available |
| ag-model-strong-medium | 1 | 10 | EXHAUSTED (today) |
| ds-model-fast | 2 | 50 | available |

Exhausted models: ag-model-strong-medium
