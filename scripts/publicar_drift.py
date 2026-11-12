#!/usr/bin/env python3
"""
Publica el reporte de drift y despierta a JARVIS solo con lo NUEVO.

  1) Deduplicación por recurso: guarda en blob qué (recurso, diferencia) ya se notificó.
     Un drift que sigue igual (p. ej. un PR pendiente de aprobación) no se vuelve a enviar.
     Cuando un recurso deja de tener drift, se olvida (si reaparece, se notifica de nuevo).
  2) Sube el reporte a blob (drift/latest.json y drift/historico/<id>.json).
  3) Envía un mensaje a la cola Service Bus jarvis-drift (disparador del agente).

Autenticación: AzureCliCredential (sesión OIDC creada por azure/login). Sin secretos.
Uso:     python publicar_drift.py reporte.json
Entorno: TFSTATE_SA, SB_FQDN
"""
import hashlib
import json
import os
import sys

from azure.core.exceptions import ResourceNotFoundError
from azure.identity import AzureCliCredential
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from azure.storage.blob import BlobServiceClient

cred = AzureCliCredential()
reporte = json.load(open(sys.argv[1], encoding="utf-8"))
cont = BlobServiceClient(f"https://{os.environ['TFSTATE_SA']}.blob.core.windows.net", credential=cred) \
    .get_container_client("drift")


def huella(c):
    return hashlib.sha256(json.dumps(c["atributos"], sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:16]


try:
    notificados = json.loads(cont.download_blob("notificados.json").readall())
except ResourceNotFoundError:
    notificados = {}

actuales = {c["direccion"]: huella(c) for c in reporte["cambios"]}
nuevos = [c for c in reporte["cambios"] if notificados.get(c["direccion"]) != actuales[c["direccion"]]]
for c in reporte["cambios"]:
    c["ya_notificado"] = c not in nuevos

# Olvidar lo que ya no tiene drift y registrar lo nuevo
notificados = {k: v for k, v in notificados.items() if k in actuales}
notificados.update({c["direccion"]: actuales[c["direccion"]] for c in nuevos})
cont.upload_blob("notificados.json", json.dumps(notificados).encode(), overwrite=True)

if reporte["tipo"] == "sin_cambios":
    # Sobrescribir latest.json: si no, el agente lee un drift viejo ya resuelto
    cont.upload_blob("latest.json", json.dumps(reporte, ensure_ascii=False, indent=2).encode("utf-8"), overwrite=True)
    print("Sin drift. latest.json actualizado y notificaciones limpiadas.")
    sys.exit(0)
if reporte["tipo"] == "drift" and not nuevos:
    print("Todo el drift actual ya fue notificado a JARVIS: no se duplica el incidente.")
    sys.exit(0)

datos = json.dumps(reporte, ensure_ascii=False, indent=2).encode("utf-8")
cont.upload_blob("latest.json", datos, overwrite=True)
cont.upload_blob(f"historico/{reporte['id']}.json", datos, overwrite=True)

mensaje = {
    "id": reporte["id"],
    "tipo": reporte["tipo"],
    "recursos_nuevos": [
        {"direccion": c["direccion"], "severidad_sugerida": c["severidad_sugerida"],
         "atributos": [a["atributo"] for a in c["atributos"]]}
        for c in nuevos
    ],
    "evento_origen": reporte.get("evento_origen", {}),
    "run_url": reporte["run_url"],
    "instruccion_fija": "Analiza este drift de NeoBanco aplicando la Política de Gestión de Cambios.",
}
with ServiceBusClient(os.environ["SB_FQDN"], credential=cred) as sb:
    with sb.get_queue_sender("jarvis-drift") as sender:
        sender.send_messages(ServiceBusMessage(json.dumps(mensaje, ensure_ascii=False),
                                               content_type="application/json", subject=reporte["tipo"]))
print(f"Publicado {reporte['id']} ({reporte['tipo']}): {len(nuevos)} recurso(s) nuevo(s) enviados a JARVIS.")
