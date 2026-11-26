# Contributing to devzone

## Languages

- The **code** is in English: identifiers, file names, comments, tests, messages and CLI commands.
- The **documentation** is in English too: README, `manage/docs/` and this file.

## Progressive switch by batch (#502)

The switch of the code to English is done by batches. The `.english` file at the root lists the files already written in English; CI checks them on every run (`bash manage/scripts/ci/check-english.sh`). Every new code file must be added to it.

## devzone charts

Each devzone service has a chart `charts/devzone-<service>`: folder name, `Chart.yaml`, common values and labels are fixed by the convention in [manage/docs/reference.md](manage/docs/reference.md#devzone-chart-convention).
The check `bash manage/scripts/ci/check-charts.sh` verifies it.

## Shell script variables

In shell scripts, a variable followed by a non-ASCII character is written `${NAME}` (on macOS, `$NAME…` reads the character as part of the name). The check `bash manage/scripts/ci/check-utf8-vars.sh` verifies it (#591).
