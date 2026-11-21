# Contributing to devzone

## Languages

- The **code** is in English: identifiers, file names, comments, tests, messages and CLI commands.
- The **documentation** is in English too: README, `manage/docs/` and this file.
- The French names of the CLI are removed (#695): devzone refuses them and shows the new name (table in `manage/docs/reference.md`, "Removed names").

## Progressive switch by batch (#502)

The switch of the code to English is done by batches. The `.english` file at the root lists the files already written in English; CI checks them on every run (`bash manage/scripts/check-english.sh`). Every new code file must be added to it.

## devzone charts

Each devzone service has a chart `charts/devzone-<service>`: folder name, `Chart.yaml`, common values and labels are fixed by the convention in [manage/docs/reference.md](manage/docs/reference.md#devzone-chart-convention).
The check `bash manage/scripts/check-charts.sh` verifies it.

## Shell script variables

In shell scripts, a variable followed by a non-ASCII character is written `${NAME}` (on macOS, `$NAME…` reads the character as part of the name). The check `bash manage/scripts/check-utf8-vars.sh` verifies it (#591).
