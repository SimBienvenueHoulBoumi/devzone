# Contribuer à devzone

## Langues

- Le **code** est en anglais : identifiants, noms de fichiers, commentaires,
  tests, messages et commandes de la CLI.
- La **documentation** est en français : README, `manage/docs/` et ce fichier.
- Les commandes françaises de la CLI restent des alias : les noms anglais sont
  acceptés dès maintenant (table de `.devcontainer/command-aliases.sh`).

## Bascule progressive par lots (#502)

Le passage du code en anglais se fait par lots. Le fichier `.english` à la
racine recense les fichiers déjà écrits en anglais ; la CI les vérifie à
chaque exécution (`bash manage/scripts/check-english.sh`). Tout nouveau
fichier de code doit y être ajouté.

## Charts des services

Chaque service de devzone a un chart `charts/devzone-<service>` : nom du
dossier, `Chart.yaml`, valeurs communes et étiquettes sont fixés par la
convention de [manage/docs/reference.md](manage/docs/reference.md#convention-des-charts-devzone).
Le contrôle `bash manage/scripts/check-charts.sh` la vérifie.

## Variables des scripts shell

Dans les scripts shell, une variable suivie d'un caractère non ASCII s'écrit `${NOM}` (sous macOS, `$NOM…` lit le caractère comme partie du nom). Le contrôle `bash manage/scripts/check-utf8-vars.sh` le vérifie (#591).
