# Workstation control without VS Code

.DEFAULT_GOAL := help
.PHONY: help hors-conteneur test-fonctionnel test-cli desinstaller uninstall

# These commands control the container from the host: run in the container
# (which uses the host Docker, #291), they would create a second devzone next
# to the first, without fixing anything. In the container: /.dockerenv, or folder /workspaces/devzone
hors-conteneur:
	@if [ -f /.dockerenv ] || [ "$(CURDIR)" = /workspaces/devzone ]; then \
		echo "✖ make $(MAKECMDGOALS) : à lancer sur ta machine (terminal du Mac ou du PC), pas dans le conteneur devzone." >&2; \
		echo "  Ici, dans le conteneur : devzone (état, modules), et les outils directement." >&2; \
		exit 1; fi

help: ## Lists the commands
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-16s %s\n", $$1, $$2}'

.DEFAULT:
	@echo "✖ make $@ does not exist (make up, shell, stop, down, rebuild and status were removed): use devzone workspace start|shell|stop|status" >&2; exit 1

test-fonctionnel: hors-conteneur ## Functional tests: isolated devzone, built then removed (5 to 10 min)
	@bash manage/test/functional.sh

test-cli: hors-conteneur ## CLI tests in a real terminal: isolated devzone, then removed (10 to 15 min)
	@bash manage/test/cli-terminal.sh

desinstaller: hors-conteneur ## Removes everything devzone created, after confirmation (GARDER=connexions: keeps the connections)
	@GARDER="$(GARDER)" bash manage/scripts/uninstall.sh

uninstall: hors-conteneur ## Removes everything devzone created, after confirmation (alias of desinstaller)
	@GARDER="$(GARDER)" bash manage/scripts/uninstall.sh
