#!/usr/bin/env bash
set -euo pipefail

NS="minecraft"
APP="minecraft"
NODEPORT=30065
PVC_SIZE="5Gi"

usage() {
  echo "Usage: $0 {up|down|status|logs}"
  exit 1
}

up() {
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

  # --- Editable settings live here (tune with autoschematic) ---
  cat <<'EOF' | kubectl -n "$NS" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: minecraft-config
data:
  # server.properties (edit these with autoschematic and restart the pod)
  server.properties: |
    motd=Autoschematic Demo Server \u2605
    difficulty=easy
    gamemode=survival
    max-players=10
    online-mode=true
    view-distance=10
    allow-nether=false
    spawn-animals=false
    spawn-monsters=false
    enable-command-block=false
    enforce-secure-profile=false
    level-seed=
    pvp=true
    white-list=false
    enable-query=false
    enable-rcon=false
  eula.txt: |
    eula=true
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minecraft-data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minecraft
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minecraft
  template:
    metadata:
      labels:
        app: minecraft
    spec:
      # Copy config from ConfigMap into the data volume on every start
      initContainers:
        - name: seed-config
          image: busybox:1.36
          command: ["sh","-c","cp -f /config/* /data/"]
          volumeMounts:
            - name: config
              mountPath: /config
            - name: data
              mountPath: /data
      containers:
        - name: server
          image: itzg/minecraft-server:latest
          imagePullPolicy: IfNotPresent
          env:
            - name: EULA
              value: "TRUE"
            - name: TYPE
              value: "VANILLA"   # Change to PAPER/SPIGOT/FORGE as desired
            - name: MEMORY
              value: "1G"        # Change to allocate more/less RAM
            - name: JVM_OPTS
              value: "-XX:+UseG1GC"
          ports:
            - name: mc
              containerPort: 25565
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: 25565
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 25565
            initialDelaySeconds: 60
            periodSeconds: 20
          volumeMounts:
            - name: data
              mountPath: /data
        # graceful termination on delete
      terminationGracePeriodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minecraft-data
        - name: config
          configMap:
            name: minecraft-config
---
apiVersion: v1
kind: Service
metadata:
  name: minecraft
spec:
  type: NodePort
  selector:
    app: minecraft
  ports:
    - name: mc
      port: 25565
      targetPort: 25565
      nodePort: 30065
EOF

  echo "Deployed. Connect to: <node-ip>:${NODEPORT}"
  echo "Tip: kubectl -n ${NS} rollout status deploy/${APP}"
}

down() {
  kubectl -n "$NS" delete deploy,svc,cm,pvc -l app="$APP" --ignore-not-found
  # also catch by name (in case labels changed)
  kubectl -n "$NS" delete deploy/$APP svc/$APP cm/${APP}-config pvc/${APP}-data --ignore-not-found
  echo "Removed minecraft workload from namespace ${NS}."
}

status() {
  echo "# Pods"
  kubectl -n "$NS" get pods -l app="$APP" -o wide || true
  echo
  echo "# Service"
  kubectl -n "$NS" get svc "$APP" -o wide || true
  echo
  echo "# PVC"
  kubectl -n "$NS" get pvc "${APP}-data" || true
}

logs() {
  POD=$(kubectl -n "$NS" get pods -l app="$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "${POD}" ]] || { echo "No pod found."; exit 1; }
  kubectl -n "$NS" logs -f "$POD"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  logs) logs ;;
  *) usage ;;
esac

