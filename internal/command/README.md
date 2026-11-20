# internal/command

- Rôle : reçoit la ligne de commande devzone ; exécute en Go les commandes de la table `ported`, délègue les autres au pont bash (#358).
- Peut importer : la bibliothèque standard et `internal/bashbridge`.
- Ne doit pas importer : `cmd/...` (le binaire dépend de ce paquet, jamais l'inverse) ni un paquet métier qui dépendrait de bash.
- La table `ported` est vide au départ : une commande y entre quand elle est portée, et sort de la délégation dans le même changement.
- Tests : `go test ./internal/command/` ; les tests de délégation utilisent un faux point d'entrée bash.
