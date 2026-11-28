# Contributing to devzone

## Languages

- The **code** is in English: identifiers, file names, comments, tests, messages and CLI commands.
- The **documentation** is in English too: README, `manage/docs/` and this file.

## Progressive switch by batch (#502)

All tracked code files are written in English. The Go checks `go run ./cmd/devzone-checks english`, `go run ./cmd/devzone-checks layout` and `go run ./cmd/devzone-checks names` scan them on every run: the English scan includes comments and test names (data and documentation are excluded by path), the layout scan applies the 250-line ceiling, and the names scan checks file and folder names.

## devzone charts

Each devzone service has a chart `charts/devzone-<service>`: folder name, `Chart.yaml`, common values and labels are fixed by the convention in [manage/docs/reference.md](manage/docs/reference.md#devzone-chart-convention).
The check `bash manage/scripts/ci/check-charts.sh` verifies it.

## Shell script variables

In shell scripts, a variable followed by a non-ASCII character is written `${NAME}` (on macOS, `$NAME…` reads the character as part of the name). The check `bash manage/scripts/ci/check-utf8-vars.sh` verifies it (#591).
