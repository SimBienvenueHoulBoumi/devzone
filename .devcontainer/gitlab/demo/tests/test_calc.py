# Tests unitaires pour le module calc.
# Exécutés par pytest dans la CI GitLab.

from calc import addition, soustraction


def test_addition():
    assert addition(2, 3) == 5
    assert addition(-1, 1) == 0
    assert addition(0, 0) == 0


def test_soustraction():
    assert soustraction(5, 3) == 2
    assert soustraction(-1, 1) == -2
    assert soustraction(0, 0) == 0
