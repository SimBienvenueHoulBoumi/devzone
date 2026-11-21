# internal/command

- Rôle : reçoit la ligne de commande devzone ; exécute en Go les commandes de la table `ported`, délègue les autres au pont bash (#358).
- Peut importer : la bibliothèque standard, `internal/bashbridge` et `internal/workspace`.
- Ne doit pas importer : `cmd/...` (le binaire dépend de ce paquet, jamais l'inverse) ni un paquet métier qui dépendrait de bash.
- La table `ported` liste les commandes portées : `--version`, `-v`, `help`, `-h`, `--help`, seules, sans autre argument ; et `workspace`, pour la seule sous-commande `status` (#712, `workspaceCommand` dans `workspace.go`). Une commande y entre quand elle est portée, et sort de la délégation dans le même changement. `devzone workspace` suivi d'autre chose que `status` (ou `status` suivi d'un mot) reste délégué au bash.
- Tests : `go test ./internal/command/` ; les tests de délégation utilisent un faux point d'entrée bash, ceux de `workspace status` un faux `kubectl` dans le PATH.
