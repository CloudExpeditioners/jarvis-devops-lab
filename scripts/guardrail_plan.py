#!/usr/bin/env python3
"""
Guardrail sobre el plan de reconciliación: bloquea destroy/replace y planes demasiado grandes.
Uso: python guardrail_plan.py plan.json
"""
import json
import os
import sys

plan = json.load(open(sys.argv[1], encoding="utf-8"))
maximo = int(os.environ.get("MAX_TARGETS", "5"))
cambios = [rc for rc in plan.get("resource_changes", []) if rc["change"]["actions"] not in (["no-op"], ["read"])]
peligrosos = [rc["address"] for rc in cambios if "delete" in rc["change"]["actions"]]

print(f"Recursos a cambiar: {len(cambios)}")
for rc in cambios:
    print(f"  {rc['change']['actions']}  {rc['address']}")
if peligrosos:
    sys.exit(f"BLOQUEADO: el plan destruye o reemplaza recursos: {peligrosos}. Requiere un humano.")
if len(cambios) > maximo:
    sys.exit(f"BLOQUEADO: {len(cambios)} recursos superan el radio de impacto ({maximo}).")
print("Guardrail OK.")
