# Compaction eval

A maintainer tool that measures what a resumed agent can still answer and do
after Mistri compacts a session. It is not part of the gem and it calls real
providers, so every run costs money.

## What it measures

Each scenario is a synthetic but realistic session at Shopify: a payouts
ledger export in Finance, an incident in the address validation service, and
a sales assistant researching a merchant before a gift send. Shopify,
Allbirds, and BigCommerce appear only as names that make the sessions read
like real work; every person, ticket, repository, incident, address, number,
and email is invented, domains end in `.example`, and nothing describes real
events.

Seeded facts are placed along the history, carried the way real facts arrive:
said by the user, stated by the assistant, inside a tool result, or buried in
the middle of a long tool result that the compactor truncates. Some facts
change later, so the latest value must win. Filler turns pad the session to
the target size with rotating shapes (log tails, row counts, metric queries,
spec runs) and a tool call that fails every seventh turn, as real ones do.
The last two turns stay outside the cut, so every fact is summarized, never
kept.

After the real `Mistri::Compactor` runs, the same model answers one probe per
fact from the compacted context alone, then performs the scenario's
continuation, one tool call whose arguments are the latest agreed values.
Grading is deterministic: a probe passes when the normalized reply contains
the expected value, a yes/no probe when its first word matches, a tool
argument when it carries the expected value (numbers compare as numbers, text
may be a fuller rendering such as a date with its year). An empty reply is a
miss: some models answer nothing when they do not know.

Baselines bound the result: `full` probes the uncompacted history, the ceiling
a summary can reach; `tail` probes exactly the tail the real cut keeps, found
with a throwaway compaction, the floor a summary must beat. Both controls
measure the first segment only. `--folds` compacts again after each later
segment, so retention across checkpoints shows up by segment.

## The judge

Deterministic probes grade what we asked about. A judge grades what we did
not: after each compaction a strong model reads the exact transcript the
summarizer saw and the final summary, lists every claim the transcript does
not support, and rates resumability from one to five. The judge is GPT-6
Astra by default, and GPT-5.6 Sol when Astra itself is the summarizer under
test, so no model grades its own family; `--judge MODEL` overrides,
`--no-judge` skips it. Its answer is a schema, parsed rather than pattern
matched. The count of unsupported claims and the resumability score appear in every
report and comparison as information; they do not decide the bar until they
have been calibrated against hand-checked flags. In the first live cells the
judge flagged more than invention: a summary that kept an old deadline next
to the new one as an open question, and failures listed as outstanding after
the same call had later succeeded. Those are exactly the drifts probes cannot
see.

A second knob separates summary quality from reader ability: `--reader MODEL`
makes one fixed model answer every probe regardless of which model wrote the
summary. The default is the summarizer itself, which is what production does.

## Running

```sh
bundle exec ruby script/compaction_eval.rb list
bundle exec ruby script/compaction_eval.rb run
bundle exec ruby script/compaction_eval.rb run --models all --sizes S,M,L --repeat 2 --folds --baselines
bundle exec ruby script/compaction_eval.rb report tmp/compaction-eval/<file>.jsonl
bundle exec ruby script/compaction_eval.rb compare eval/baselines/current.jsonl <candidate>.jsonl
bundle exec ruby script/compaction_eval.rb regrade <file>.jsonl <regraded>.jsonl
bundle exec ruby script/compaction_eval.rb distill <file>.jsonl <distilled>.jsonl
```

Rows land in `tmp/compaction-eval/` as JSONL, one row per finished cell,
with a markdown report beside them. Every row is tagged with the git SHA, a
digest of the compactor prompts, a digest of its scenario (facts by segment,
the continuation contract, and a fingerprint of one built session, so filler
and builder changes count), and the grader's version, and keeps the summary,
every probe reply, and every tool argument in full, so a miss can be read
rather than guessed and a regrade grades the same text. `regrade` applies the
current grading rules to a stored run, so a grading fix never needs another
paid run. `distill` drops every generated word and keeps the scores and the
names of any wrong continuation fields, which is the only form a baseline is
committed in. Probe costs include every retried attempt; a judge that failed
reports no counts rather than a clean zero.

Keys come from the environment; `.env.development.local` wins over the shell,
as in the tests. The `full` baseline sends the whole history with every probe,
so at size M it costs several dollars per cell on the larger models; run
baselines at S.

## Tiers

The default run is the CI tier: Sonnet 5, GPT-5.6 Sol, and Gemini 2.5 Flash,
all scenarios, size S, one repetition, the judge on, about five dollars. Size
L runs near 150k input tokens per compaction; `--models all` is the whole
catalog. The `full` baseline sends the whole history with every probe, so at
size M it costs several dollars per cell on the larger models; run baselines
at S. Keys come from the environment; `.env.development.local` wins over the
shell, as in the tests.

Sol stays in every tier because it is the production default for the hosts we
know.

## Running it in CI

`.github/workflows/compaction-eval.yml` runs the CI tier on any pull request
that touches the compactor or the eval, and any tier on manual dispatch. The
jobs run in the GitHub environment `eval`, which holds the three provider
keys and requires a maintainer's approval before a job starts. GitHub never
hands repository secrets to a workflow started by a pull request from a fork,
so for outside contributions the workflow uses `pull_request_target`: it
checks out the pull request's head and runs it with the keys, which is why
the approval exists. Read the diff before approving. The keys are dedicated
to the eval and spend-capped at each provider, so the worst a bad change can
do is spend the cap.

One job per model uploads its rows as an artifact; a final job, running the
base branch's code, regrades the candidate's raw rows with the base branch's
grader, compares them against the base branch's `eval/baselines/current.jsonl`,
writes report and comparison to the job summary, comments the comparison on
the pull request, and fails when the comparison failed.

## Changing the compactor prompt

A prompt change must come with an eval on the baseline tier and the
comparison in the pull request. The committed baseline is two runs per model,
concatenated and distilled:

```sh
bundle exec ruby script/compaction_eval.rb run --sizes S --repeat 2 --folds --baselines --out tmp/compaction-eval/candidate-S.jsonl
bundle exec ruby script/compaction_eval.rb run --sizes M --repeat 2 --folds --out tmp/compaction-eval/candidate-M.jsonl
cat tmp/compaction-eval/candidate-S.jsonl tmp/compaction-eval/candidate-M.jsonl > tmp/compaction-eval/candidate.jsonl
bundle exec ruby script/compaction_eval.rb compare eval/baselines/current.jsonl tmp/compaction-eval/candidate.jsonl
```

`compare` first refuses anything not comparable: different grader versions,
or an empty side. Then it matches cells, a cell being model, scenario, size,
mode, reader, and fold count, leaves out scenarios whose digest changed, names
every baseline cell the candidate did not run and every candidate cell without
a baseline, and aggregates per model over the matched cells only. The
comparison passes when no model loses more than three points of aggregate
probe accuracy and no model's rejected-compaction rate rises; it exits
nonzero otherwise, and the CI job fails with it. The rest is read, not
computed: changed facts and continuation stay within their noise, the judge's
unsupported-claim count does not rise, the misses list reads as improvements
rather than trades, and summary size stays within the compactor's limit with
room to spare.

The three-point bar comes from measurement: two runs of the same prompt
differed by up to six points in one cell but by under two points per model in
aggregate (about 250 probes each), while changed-fact accuracy and
continuation, with a few dozen and a dozen samples per model, moved by up to
eight points. A CI-tier run (size S) therefore compares against the size S
cells of the baseline, never against the baseline's aggregate over sizes it
did not run.

`--prompts FILE` loads a Ruby file that redefines the `Mistri::Compactor`
prompt constants for local iteration; the prompt digest in every row keeps
such a run from passing as a baseline.

## Limits

The scenarios are synthetic. They cover how facts arrive and change, not every
domain a host runs. Deterministic grading checks values, not prose, and the
judge is an opinion until calibrated; read the summaries. Models are not
deterministic: compare means over repetitions, and treat a difference smaller
than the spread between repetitions as noise.
