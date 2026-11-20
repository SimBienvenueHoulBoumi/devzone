# Contribuer à devzone

## Langues

- Le **code** est en anglais : identifiants, noms de fichiers, commentaires,
  tests, messages et commandes de la CLI.
- La **documentation** est en français : README, `manage/docs/` et ce fichier.
- Les noms français de la CLI sont retirés (#695) : devzone les refuse et
  affiche le nouveau nom (table dans `manage/docs/reference.md`, « Noms retirés »).

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
