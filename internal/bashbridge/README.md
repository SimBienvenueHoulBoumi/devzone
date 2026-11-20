# internal/bashbridge

- Rôle : exécute le point d'entrée bash (`manage/devzone`) comme processus enfant, en conservant entrées, sorties, environnement et code de sortie (#358).
- Peut importer : la bibliothèque standard uniquement.
- Ne doit pas importer : aucun paquet du dépôt (ni `internal/command`, ni `cmd/...`), pour rester réutilisable et sans cycle.
- Localisation : `DEVZONE_BASH_ENTRY` si définie, sinon `manage/devzone` à côté du binaire, dans son dossier parent, puis dans le dossier courant.
- Tests : `go test ./internal/bashbridge/` ; les scripts temporaires sont créés dans `t.TempDir()`.
