#!/usr/bin/env python3
"""Actualiza una variable permitida en infra/neobanco/terraform.tfvars (catálogo cerrado)."""
import os
import re
import sys

PERMITIDAS = {"app_service_sku": r"^(B[1-3]|P[0-3]v3)$"}
var, valor = os.environ["VARIABLE"], os.environ["VALOR"]
if var not in PERMITIDAS or not re.fullmatch(PERMITIDAS[var], valor):
    sys.exit(f"Cambio no permitido: {var}={valor}")

ruta = "infra/neobanco/terraform.tfvars"
texto = open(ruta, encoding="utf-8").read()
nuevo, n = re.subn(rf'^(\s*{var}\s*=\s*)"[^"]*"', rf'\g<1>"{valor}"', texto, flags=re.M)
if n != 1:
    sys.exit(f"No se encontró exactamente una línea para {var}")
if nuevo == texto:
    sys.exit("Git ya tiene ese valor: no hay nada que codificar.")
open(ruta, "w", encoding="utf-8").write(nuevo)
print(f"{var} -> {valor}")
