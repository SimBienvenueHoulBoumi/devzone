#!/usr/bin/env python3
"""Lance une commande dans un pseudo-terminal, comme un humain dans un terminal.

Usage : terminal.py <délai_s> [--envoyer MOTIF TEXTE]... -- commande [args...]

Pourquoi : sans terminal, beaucoup d'outils ne posent aucune question ; un
test sans terminal ne voit donc jamais une commande qui attend une entrée
(make rebuild figé, ticket #109). Le module pty de Python se comporte de même
sous macOS et Linux, contrairement à script(1) dont la syntaxe diffère.

- La sortie de la commande est recopiée telle quelle sur la sortie standard.
- --envoyer : dès que MOTIF (expression régulière) apparaît dans la sortie,
  TEXTE est tapé (les envois se font dans l'ordre, chacun une fois).
- Délai dépassé : la commande et ses enfants sont arrêtés, code 124 (la
  commande attend sans doute une entrée). Sinon : code de la commande.
"""

import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time


def lire_arguments(
    argv: list[str],
) -> tuple[float, list[tuple[re.Pattern, bytes]], list[str]]:
    """Délai, envois à faire et commande ; usage affiché si invalide."""
    try:
        delai = float(argv[0])
        envois = []
        i = 1
        while argv[i] == "--envoyer":
            envois.append((re.compile(argv[i + 1]), argv[i + 2].encode()))
            i += 3
        if argv[i] != "--" or len(argv) <= i + 1:
            raise ValueError
        return delai, envois, argv[i + 1 :]
    except (IndexError, ValueError, re.error):
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        sys.exit(2)


def arreter(pid: int) -> None:
    """Arrête la commande et tout son groupe (enfants compris), poliment puis non."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            return
        except PermissionError:  # macOS : groupe dont le chef est déjà fini
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                return
        for _ in range(50):
            if os.waitpid(pid, os.WNOHANG)[0]:
                return
            time.sleep(0.1)


def code_de_sortie(statut: int) -> int:
    """Code de sortie à la manière du shell (128 + signal)."""
    if os.WIFSIGNALED(statut):
        return 128 + os.WTERMSIG(statut)
    return os.WEXITSTATUS(statut)


def main(argv: list[str]) -> int:
    delai, envois, commande = lire_arguments(argv)
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(commande[0], commande)
        finally:
            os._exit(127)
    # Taille d'un terminal ordinaire : certains outils s'y adaptent
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    fin = time.monotonic() + delai
    sortie = ""
    depuis = (
        0  # position dans la sortie à partir de laquelle chercher le prochain motif
    )
    statut = None
    while True:
        reste = fin - time.monotonic()
        if reste <= 0 and statut is not None:
            break
        if reste <= 0:
            arreter(pid)
            sys.stdout.flush()
            sys.stderr.write(
                f"\n[terminal.py] délai de {delai:g} s dépassé : la commande attend sans doute une entrée\n"
            )
            return 124
        pret, _, _ = select.select([fd], [], [], min(reste, 0.5))
        if pret:
            try:
                donnees = os.read(fd, 65536)
            except OSError:  # Linux : EIO quand plus personne n'écrit
                donnees = b""
            if not donnees:
                break
            sys.stdout.buffer.write(donnees)
            sys.stdout.flush()
            sortie += donnees.decode("utf-8", "replace")
            while envois:
                trouve = envois[0][0].search(sortie, depuis)
                if not trouve:
                    break
                os.write(fd, envois.pop(0)[1])
                depuis = trouve.end()
        elif statut is None:
            # Commande finie mais terminal gardé ouvert par un enfant détaché
            fini, statut_lu = os.waitpid(pid, os.WNOHANG)
            if fini:
                statut = statut_lu
                fin = min(fin, time.monotonic() + 2)
    if statut is None:
        _, statut = os.waitpid(pid, 0)
    os.close(fd)
    return code_de_sortie(statut)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
