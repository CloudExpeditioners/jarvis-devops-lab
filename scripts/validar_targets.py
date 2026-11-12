#!/usr/bin/env python3
"""Valida los targets pedidos a reconcile.yml (segunda barrera, independiente del agente)."""
import os
import re
import sys

PERMITIDOS = ("azurerm_network_security_group.", "azurerm_storage_account.", "azurerm_key_vault.",
              "azurerm_mssql_server.", "azurerm_linux_web_app.", "azurerm_private_endpoint.",
              "azurerm_virtual_network.")
targets = [t.strip() for t in os.environ.get("TARGETS", "").split(",") if t.strip()]
maximo = int(os.environ.get("MAX_TARGETS", "5"))

if not targets:
    sys.exit("No hay targets.")
if len(targets) > maximo:
    sys.exit(f"Radio de impacto excedido: {len(targets)} > {maximo}.")
for t in targets:
    if not re.fullmatch(r'[A-Za-z0-9_.\[\]"-]+', t):
        sys.exit(f"Dirección inválida: {t}")
    if not t.startswith(PERMITIDOS):
        sys.exit(f"Fuera del catálogo permitido: {t}")

args = " ".join(f"-target='{t}'" for t in targets)
with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
    f.write(f"args={args}\n")
print("Targets válidos:", targets)
