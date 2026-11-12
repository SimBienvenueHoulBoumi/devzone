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
