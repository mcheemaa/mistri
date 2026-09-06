# Compaction eval

A maintainer tool that measures what a resumed agent can still answer and do
after Mistri compacts a session. It is not part of the gem and it calls real
providers, so every run costs money.

## What it measures

Each scenario is a synthetic but realistic session: a finance export, a
production incident, an account research chat. Seeded facts are placed along
the history, carried the way real facts arrive: said by the user, stated by
the assistant, inside a tool result, or buried in the middle of a long tool
result that the compactor truncates. Some facts change later, so the latest
value must win. Filler turns pad the session to the target size with log-like
noise. The last two turns stay outside the cut, so every fact is summarized,
never kept.

After the real `Mistri::Compactor` runs, the same model answers one probe per
fact from the compacted context alone, and then performs the scenario's
continuation, one tool call whose arguments are the latest agreed values.
Grading is deterministic: a probe passes when the normalized reply contains
the expected value, a yes/no probe when its first word matches, a tool
argument when it carries the expected value (numbers compare as numbers, text
may be a fuller rendering such as a date with its year). An empty reply is a
miss: some models answer nothing when they do not know. There is no judge
model, so a run is reproducible and cheap.

Baselines bound the result: `full` probes the uncompacted history, the ceiling
a summary can reach; `tail` probes the kept tail alone, the floor it must beat.
`--folds` compacts again after each later segment, so retention across
checkpoints shows up by segment.

## Running

```sh
bundle exec ruby script/compaction_eval.rb list
bundle exec ruby script/compaction_eval.rb run
bundle exec ruby script/compaction_eval.rb run --models all --sizes S,M,L --repeat 2 --folds --baselines
bundle exec ruby script/compaction_eval.rb report tmp/compaction-eval/<file>.jsonl
bundle exec ruby script/compaction_eval.rb compare eval/baselines/<base>.jsonl <candidate>.jsonl
bundle exec ruby script/compaction_eval.rb regrade <file>.jsonl <regraded>.jsonl
```

Rows keep every probe reply and every tool argument in full, so `regrade`
applies the current grading rules to a stored run: a grading fix never needs
another paid run, and a committed baseline can be brought up to date without
new provider calls.

The default matrix is one cheap model per provider (Haiku 4.5, GPT-5.6 Sol,
Gemini 2.5 Flash), all scenarios, sizes S and M, one repetition: about ten
cents per cell, a few dollars in all. Size L runs near 150k input tokens per
compaction; `--models all` is the whole catalog. The `full` baseline sends the
whole history with every probe, so at size M it costs several dollars per cell
on the larger models; run baselines at S. Keys come from the environment;
`.env.development.local` wins over the shell, as in the tests.

Rows land in `tmp/compaction-eval/` as JSONL with a markdown report beside
them, tagged with the git SHA and a digest of the compactor prompts. Every row
keeps the summary text and each probe's reply, so a miss can be read, not
guessed.

## Changing the compactor prompt

A prompt change must come with an eval, run on the same matrix as the
committed baseline in `eval/baselines/` with at least two repetitions, and
the comparison in the pull request. The committed baseline is two runs per
default model, concatenated: sizes S with baselines and folds, then size M
with folds:

```sh
bundle exec ruby script/compaction_eval.rb run --sizes S --repeat 2 --folds --baselines --out tmp/compaction-eval/candidate-S.jsonl
bundle exec ruby script/compaction_eval.rb run --sizes M --repeat 2 --folds --out tmp/compaction-eval/candidate-M.jsonl
cat tmp/compaction-eval/candidate-S.jsonl tmp/compaction-eval/candidate-M.jsonl > tmp/compaction-eval/candidate.jsonl
bundle exec ruby script/compaction_eval.rb compare eval/baselines/<current>.jsonl tmp/compaction-eval/candidate.jsonl
```

The bar: no model loses more than five points of probe accuracy, changed
facts and continuation do not regress, and summary size stays within the
compactor's limit with room to spare. `--prompts FILE` loads a Ruby file that
redefines the `Mistri::Compactor` prompt constants for local iteration; the
prompt digest in every row keeps such a run from passing as a baseline.

## Limits

The scenarios are synthetic. They cover how facts arrive and change, not every
domain a host runs. Grading checks values, not prose quality, so a summary
can score well and still read badly; read the summaries. Models are not
deterministic: compare means over repetitions, and treat a difference smaller
than the spread between repetitions as noise.
