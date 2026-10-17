# Pilotage du devcontainer sans VS Code
DC     := npx -y @devcontainers/cli
WS     := --workspace-folder $(CURDIR)
FILTRE := --filter "label=devcontainer.local_folder=$(CURDIR)"

.DEFAULT_GOAL := help
.PHONY: help hors-conteneur up shell stop down rebuild status test-fonctionnel test-cli desinstaller

# Ces commandes pilotent le conteneur depuis la machine : lancées dans le
# conteneur, elles créeraient un devzone dans son Docker interne, sans rien
# réparer. Dans le conteneur : /.dockerenv, ou dossier /workspaces/devzone
hors-conteneur:
	@if [ -f /.dockerenv ] || [ "$(CURDIR)" = /workspaces/devzone ]; then \
		echo "✖ make $(MAKECMDGOALS) : à lancer sur ta machine (terminal du Mac ou du PC), pas dans le conteneur devzone." >&2; \
		echo "  Ici, dans le conteneur : devzone (état, modules), et les outils directement." >&2; \
		exit 1; fi

help: ## Liste les commandes
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-16s %s\n", $$1, $$2}'

# up et rebuild : étapes affichées, journal complet dans .devzone.log, question
# posée dans le conteneur signalée au lieu d'attendre (lancer.sh)
up: hors-conteneur ## Lance le conteneur (le crée si absent)
	@bash lancer.sh up "$(CURDIR)"

shell: hors-conteneur up ## Ouvre un shell dans le conteneur
	@$(DC) exec $(WS) bash

stop: hors-conteneur ## Arrête le conteneur (état conservé)
	@ids=$$(docker ps -q $(FILTRE)); if [ -z "$$ids" ]; then echo "déjà arrêté"; else docker stop $$ids >/dev/null && echo "devzone arrêté"; fi

down: hors-conteneur ## Supprime le conteneur (volumes, image et Docker interne conservés)
	@ids=$$(docker ps -aq $(FILTRE)); if [ -z "$$ids" ]; then echo "aucun conteneur"; else \
		docker inspect $$ids --format 'IMAGE={{.Config.Image}}{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}} DIND={{.Name}}{{end}}{{end}}' | head -1 | tr ' ' '\n' > .devzone.etat; \
		docker rm -f $$ids >/dev/null && echo "devzone supprimé (désinstallation complète : make desinstaller)"; fi

rebuild: hors-conteneur ## Reconstruit de zéro (après modif de .devcontainer/)
	@bash lancer.sh rebuild "$(CURDIR)"

status: hors-conteneur ## État du conteneur
	@docker ps -a $(FILTRE) --format '{{.Status}}' | grep . || echo "aucun conteneur"

test-fonctionnel: hors-conteneur ## Tests fonctionnels : devzone isolé, construit puis supprimé (5 à 10 min)
	@bash test/fonctionnel.sh

test-cli: hors-conteneur ## Tests de la CLI dans un vrai terminal : devzone isolé, puis supprimé (10 à 15 min)
	@bash test/cli-terminal.sh

desinstaller: hors-conteneur ## Supprime tout ce que devzone a créé, après confirmation (GARDER=connexions : garde les connexions)
	@GARDER="$(GARDER)" bash desinstaller.sh
