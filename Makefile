# Pilotage du devcontainer sans VS Code
DC     := npx -y @devcontainers/cli
WS     := --workspace-folder $(CURDIR)
FILTRE := --filter "label=devcontainer.local_folder=$(CURDIR)"
LOG    := $(CURDIR)/.devzone.log

.DEFAULT_GOAL := help
.PHONY: help up shell stop down rebuild status test-fonctionnel desinstaller

help: ## Liste les commandes
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-16s %s\n", $$1, $$2}'

up: ## Lance le conteneur (le crée si absent)
	@$(DC) up $(WS) >$(LOG) 2>&1 && echo "devzone lancé" \
		|| { tail -15 $(LOG); echo "échec — log complet : .devzone.log"; exit 1; }

shell: up ## Ouvre un shell dans le conteneur
	@$(DC) exec $(WS) bash

stop: ## Arrête le conteneur (état conservé)
	@ids=$$(docker ps -q $(FILTRE)); if [ -z "$$ids" ]; then echo "déjà arrêté"; else docker stop $$ids >/dev/null && echo "devzone arrêté"; fi

down: ## Supprime le conteneur (volumes, image et Docker interne conservés)
	@ids=$$(docker ps -aq $(FILTRE)); if [ -z "$$ids" ]; then echo "aucun conteneur"; else \
		docker inspect $$ids --format 'IMAGE={{.Config.Image}}{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}} DIND={{.Name}}{{end}}{{end}}' | head -1 | tr ' ' '\n' > .devzone.etat; \
		docker rm -f $$ids >/dev/null && echo "devzone supprimé (désinstallation complète : make desinstaller)"; fi

rebuild: ## Reconstruit de zéro (après modif de .devcontainer/)
	@$(DC) up $(WS) --remove-existing-container >$(LOG) 2>&1 && echo "devzone reconstruit" \
		|| { tail -15 $(LOG); echo "échec — log complet : .devzone.log"; exit 1; }

status: ## État du conteneur
	@docker ps -a $(FILTRE) --format '{{.Status}}' | grep . || echo "aucun conteneur"

test-fonctionnel: ## Tests fonctionnels : devzone isolé, construit puis supprimé (5 à 10 min)
	@bash test/fonctionnel.sh

desinstaller: ## Supprime tout ce que devzone a créé, après confirmation (GARDER=connexions : garde les connexions)
	@GARDER="$(GARDER)" bash desinstaller.sh
