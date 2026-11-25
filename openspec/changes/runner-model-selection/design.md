# Design

## Context

See proposal.md for the motivation. The facts below were checked on 2026-11-24
against the installed runtime (1.2.0, `a5e7b10`) and OpenCode 2.4.1. The ACP
checks were handshakes only: no prompt was sent and nothing was spent.

| Fact | Consequence |
| --- | --- |
| The OpenCode 2 interface has no `--model` flag (`run` and `mini` do); an `opencode.json` with `model` worked for one interface start and not for the next | a native `opencode` runner cannot be pinned reliably |
| `opencode acp` advertises `model` (79 values), `effort` (category `thought_level`) and `mode` (`build`, `plan`) as config options | model and effort can be pinned over ACP |
| The offered efforts depend on the model, and the effort is back at `default` after a model change | model first, then effort, then read both |
| `provider/model#variant` is rejected over ACP (`model not found`); `provider/model/variant` is accepted although it is not in the offered list | use the separate effort option, not a compound model string |
| `session/set_config_option` returns the full configuration with `currentValue` | confirmation costs nothing and precedes the first prompt |
| `boss_acp.py` records the *wanted* model as `acp.model` and never compares `currentValue`; a later `config_option_update` overwrites it without a warning | status cannot be trusted as proof today |
| After `session/load` without config options the model is not re-checked (`strict` is false) | a resume can deviate silently |
| `boss doctor` always probes with `--profile-temp`, also for `isolate = false` | in a temporary profile OpenCode offers only 11 `opencode/*` models, so a working `opencode-deepseek` runner is reported as broken |
| Without a model the ACP session started on a free `opencode/*` model | an unpinned ACP runner can send data to an unplanned provider |
| `opencode api get /api/session/<id>` returns model, variant, cost and tokens; Herdr knows the session id of a native tab | a native OpenCode tab can be verified, but only after it started |
| A Claude transcript records the model per message; a long Opus session also contained another Claude model and `<synthetic>` entries | verify the main model, list the others, ignore synthetic entries |
| `claude` accepts `--model`, `--effort` and `--fallback-model` | pinning works; a fallback flag must be refused |
| Goose reported cost in `usage_update`; whether OpenCode 2.4.1 does so during a turn was not checked | limits need a token path and an "unknown" state |

### What lives where

| Part | Place |
| --- | --- |
| Skills, shared RUN block, README | this repository |
| Runtime (`boss`, `boss-acp`, `boss_acp.py`, `boss-lib.sh`, ...) | this repository, `runtime/`; installed to `~/.local/bin` with origin `vision-skill` |
| Runner, catalog, role and provider entries | the operator's `boss.toml`, changed by the operator |
| `boss-mode` | older standalone snapshot: no ACP transport, no `BOSS_VERSION`, no Git repository; not installed |

So nothing in `boss-mode` has to change for this to work. If the snapshot stays
in use somewhere, its part is a separate change *in that project* (port the
runner fields and the `model_unpinned` check; the ACP parts have no counterpart
there). The runtime origin stays documented in `runtime/VENDOR.md`.

## Goals / Non-Goals

**Goals**

- One answer to "which model is running", read from the agent.
- A wrong, missing or unpaid-for model stops work before or directly after the
  start, with the work kept.
- No new mission syntax.

**Non-Goals**

- Model routing by price, load or quality.
- Reading provider balances or quota of a subscription.
- Treating the per-apply profile or the provider list as a sandbox.
- Pinning `boss session` tabs; a person sees and chooses the model there.
- Selecting the ACP `mode` from a config option. OpenCode advertises it that way
  while the runtime reads only `modes`, which is why `mode = ""` is needed
  today; this is a follow-up.

## Decisions

### 1. A named runner is the unit of choice

Model and effort belong to the runner, so `runner:` stays the only annotation.
Rejected: `model:`/`effort:` on the bullet - an older runtime parses the bullet
and drops unknown keys silently, which is exactly the failure to remove.
Rejected: `--model` on dispatch - retrigger and resume would need it too.

```toml
[model_policy]
unpinned = "strict"              # strict | warn (see Open Questions)
confirm_timeout_s = 120          # native confirmation interval

[models."deepseek/deepseek-flash"]
provider = "deepseek"
billing = "metered"
limit_usd = 1.00                 # example values; the operator sets them
limit_tokens = 3000000

[models."openai/gpt-6.2-astra"]
provider = "openai"
billing = "metered"
limit_usd = 5.00

[models."opus"]
provider = "anthropic"
billing = "quota"
expect = ["claude-opus-*"]       # ids the alias may resolve to
helpers = ["claude-sonnet-*", "claude-haiku-*"]

[runners.opencode-deepseek]
start = "acp"
command = "opencode"
model = "deepseek/deepseek-flash"
isolate = false
mode = ""

[runners.openai-review]
start = "acp"
command = "opencode"
model = "openai/gpt-6.2-astra"
effort = "xhigh"
isolate = false
mode = ""

[runners.claude-opus]
kind = "claude"
model = "opus"                   # replaces "--model" in args
effort = "high"

[model_roles]
code = "opencode-deepseek"
ui_hard = "claude-opus"
formula_check = "claude-opus"
second_review = "openai-review"

[model_providers]
shop = ["deepseek", "anthropic", "openai"]
```

Adding a model means: catalog entry, runner, doctor, trial, then use.

### 2. Confirm by transport

| Transport | Pin | Confirm | When |
| --- | --- | --- | --- |
| ACP | config options model, then effort | `currentValue` of the returned configuration | before every prompt |
| native `claude` | `--model`, `--effort` | model field in the session transcript | after the first answer |
| native `opencode` | not possible | session API by Herdr session id | after the first answer, as detection only |
| other native kinds | not possible unless an adapter is added | none | `unverifiable` |

The state keeps `declared` and `confirmed` apart:

```json
"model": {"declared": "openai/gpt-6.2-astra", "effort_declared": "xhigh",
          "confirmed": "openai/gpt-6.2-astra", "effort_confirmed": "xhigh",
          "status": "confirmed", "source": "acp_config", "checked_at": "...",
          "provider": "openai", "billing": "metered", "seen": ["..."]}
```

`status` is `pending`, `confirmed`, `mismatch`, `unpinned`, `unverifiable` or
`unknown` (old state). `acp.model` stays as the declared value for
compatibility.

### 3. Metered models only where confirmation comes first

Native confirmation happens after tokens were bought. For `metered` models the
runtime therefore requires a transport that confirms first. `quota` models (a
subscription) may be confirmed late. The check never calls the model itself.

Rejected: start `opencode mini --model` as a native runner. The flag exists, but
Herdr integration, permissions and the shared server are untested for it. It can
become an adapter later.

### 4. A mismatch stops, it does not repair

Setting the model back and continuing would hide that part of the work came from
another model. The turn is cancelled (ACP) or interrupted (native) and the boss
decides. Exception: directly after `session/load` the declared value is set again
and confirmed, because no prompt has run yet.

### 5. Limits are measured on reported use

Sum cost and tokens over all prompts of an apply. Sources: ACP `usage_update` and
the prompt result, or the agent's session record. Some agents report only at the
end of a turn, so a limit can be overshot by one turn. The README names that and
recommends a provider-side cap (prepaid balance, project budget) as the hard
stop. `limit_tokens` is needed wherever cost is not reported.

### 6. Trial run

`boss model trial <runner>` creates an empty temporary directory, sends a fixed
prompt without project content, applies a small limit and writes the record to
`$BOSS_STATE_DIR/models/`. It needs `--confirm-spend <amount>` or the charter
amount. Related read-only commands: `boss model list` (runners, models, billing,
trial state) and `boss model check <runner>` (handshake only, no prompt).

### 7. Provider list instead of content filter

The agent has the user's file rights, so the runtime cannot guarantee what is
read. The enforceable statement is "this project's applies start only with these
providers". Data classes (code, plans, logs, personal data) are decisions in the
charter that the Explorer follows when assigning runners. A gateway counts as an
additional provider.

### 8. Roles are planning data

P4 resolves a role once and writes the runner name, so a later change of
`[model_roles]` does not move a planned mission silently. Today's table in the
README (research, legal, code) becomes the default role set. A second review is
its own change with `after:` on the reviewed one and another model vendor.

### Error codes

`model_unpinned`, `model_uncataloged`, `model_not_offered`, `effort_not_offered`,
`model_mismatch`, `model_confirmation_late`, `model_fallback_configured`,
`model_limit_missing`, `model_untried`, `provider_not_allowed`,
`invalid_runner_model` (extended); stop reason `cost_limit`.

## Risks / Trade-offs

- [The agent's report is wrong or incomplete] → it is the best available source;
  a trial also compares the session record where one exists.
- [A session record format changes] → the adapter returns `unverifiable`, never
  `confirmed`; fixtures pin the known formats.
- [Strict policy stops running missions after the update] → `warn` exists, the
  doctor lists affected runners and changes before the switch.
- [An old runtime ignores the new tables] → README requires the installed version
  before relying on them; a dispatch result without `model` means an old runtime.
- [Provider changes its price] → limits use reported cost, the catalog holds no
  prices.
- [Helper models cause false stops] → `helpers` per catalog entry; free or quota
  helpers of an allowed provider are only listed.
- [A non-isolated probe can leave an empty session in the user's agent store] →
  close it, delete it where supported, report it otherwise.

## Migration Plan

1. Operator answers the Open Questions; adjust specs if an answer differs from
   the recommendation.
2. Install the new runtime with `unpinned = "warn"`; nothing that runs today
   stops.
3. Add catalog, roles and provider lists; move `--model` from `args` to `model`.
   `goose` and `goose-review` need a model, `opencode` and `opencode-commit` have
   no pinned form and need an ACP counterpart.
4. Run the doctor until no unpinned runner is in use, do the trials, switch to
   `strict`.

Rollback: set `warn` or remove the tables; old states and missions stay readable.

## Open Questions

Decided by the operator on 2026-11-24 ("1 bis 8 ok"): every recommendation below is
accepted as written. The amounts in 3 are per apply and per trial, not per month.

1. **Default for unpinned runners?** Recommendation: `warn` for one release, then
   `strict`. The alternative `strict` at once stops `opencode`,
   `opencode-commit` and the `goose` runners immediately.
2. **Which default runner?** Recommendation: the pinned DeepSeek ACP runner.
   Consequence: the apply tab is a transcript view, and `boss session` still needs
   a native runner.
3. **Limits per apply and trial?** Recommendation: start with 1 USD for DeepSeek
   Flash, 5 USD for an OpenAI review, 0.10 USD per trial, plus a cap at the
   provider. Only the operator can set amounts.
4. **Does a limit stop or only warn?** Recommendation: stop, with a warning at
   80 percent.
5. **Do models already in use need a trial?** Recommendation: yes, once; it costs
   cents and fills the record.
6. **May a charter name a substitute model?** Recommendation: no in this change;
   a missing model waits for the operator.
7. **Which providers may receive which data in which project, in particular
   health data and free gateway models?** Recommendation: list providers per
   project, no personal data to free models, personal data only to providers
   named in the charter.
8. **Is native OpenCode still wanted for free or quota models?** Recommendation:
   no for applies, yes for interactive sessions.
