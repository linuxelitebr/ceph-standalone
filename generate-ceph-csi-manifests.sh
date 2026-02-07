#!/bin/bash
# =============================================================================
# generate-ceph-csi-manifests.sh
# =============================================================================
# Generates all ceph-csi RBD manifests for OpenShift.
#
# Based on OFFICIAL upstream manifests from:
#   https://github.com/ceph/ceph-csi/tree/master/deploy/rbd/kubernetes
#
# Adaptations for OpenShift:
#   - Namespace: openshift-storage (instead of default)
#   - Image tag: pinned to CSI_VERSION (instead of canary)
#   - ceph-config volume: emptyDir (workaround for v3.13.0 keyring write issue)
#   - SCC helper script for privileged access
#
# Usage:
#   ./generate-ceph-csi-manifests.sh
#
# All configuration can be set via environment variables:
#   export CEPH_VM=ceph-standalone
#   export CEPH_MON_IP=10.X.X.X
#   export CEPH_FSID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   export CEPH_USER_KEY=AQBxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx==
#   export CSI_VERSION=v3.13.0
#   export OUTPUT_DIR=./ceph-csi-manifests
#   export POOL_GENERAL=openshift
#   export POOL_VMS=openshift-vms
#   ./generate-ceph-csi-manifests.sh
#
# Requirements:
#   - SSH access to the Ceph VM (unless CEPH_FSID and CEPH_USER_KEY are set)
#   - Pool 'openshift' already created in Ceph
#   - User 'client.openshift' already created in Ceph
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration — override via environment variables or use defaults
# -----------------------------------------------------------------------------
CEPH_VM="${CEPH_VM:-ceph-standalone}"                # hostname or IP of the Ceph VM
CEPH_MON_IP="${CEPH_MON_IP:-10.X.X.X}"         # MON IP (same as the VM in standalone)
CSI_VERSION="${CSI_VERSION:-v3.13.0}"                 # ceph-csi version
OUTPUT_DIR="${OUTPUT_DIR:-./ceph-csi-manifests}"      # output directory
POOL_GENERAL="${POOL_GENERAL:-openshift}"             # pool for general workloads
POOL_VMS="${POOL_VMS:-openshift-vms}"                 # pool for VMs (optional)

# Sidecar versions (from upstream master, compatible with v3.13.0+)
PROVISIONER_VERSION="${PROVISIONER_VERSION:-v6.0.0}"
SNAPSHOTTER_VERSION="${SNAPSHOTTER_VERSION:-v8.4.0}"
ATTACHER_VERSION="${ATTACHER_VERSION:-v4.10.0}"
RESIZER_VERSION="${RESIZER_VERSION:-v2.0.0}"
REGISTRAR_VERSION="${REGISTRAR_VERSION:-v2.15.0}"

# Deployment sizing
CONTROLLER_REPLICAS="${CONTROLLER_REPLICAS:-2}"       # upstream default is 3, 2 for lab

# -----------------------------------------------------------------------------
# Collect data from Ceph (skips SSH if CEPH_FSID and CEPH_USER_KEY are set)
# -----------------------------------------------------------------------------
if [ -n "${CEPH_FSID:-}" ] && [ -n "${CEPH_USER_KEY:-}" ]; then
  echo "=== Using CEPH_FSID and CEPH_USER_KEY from environment ==="
else
  echo "=== Collecting data from Ceph at ${CEPH_VM} via SSH ==="

  if [ -z "${CEPH_FSID:-}" ]; then
    CEPH_FSID=$(ssh ${CEPH_VM} 'sudo ceph fsid' 2>/dev/null) || {
      echo "ERROR: Could not connect via SSH to '${CEPH_VM}'."
      echo "Set CEPH_FSID as environment variable or enter manually:"
      read -rp "CEPH_FSID: " CEPH_FSID
    }
  fi

  if [ -z "${CEPH_USER_KEY:-}" ]; then
    CEPH_USER_KEY=$(ssh ${CEPH_VM} 'sudo ceph auth get-key client.openshift' 2>/dev/null) || {
      echo "ERROR: Could not get the client.openshift key."
      echo "Set CEPH_USER_KEY as environment variable or enter manually:"
      read -rp "CEPH_USER_KEY: " CEPH_USER_KEY
    }
  fi
fi

echo ""
echo "  FSID:     ${CEPH_FSID}"
echo "  MON IP:   ${CEPH_MON_IP}"
echo "  User Key: ${CEPH_USER_KEY:0:8}..."
echo "  CSI:      ${CSI_VERSION}"
echo "  Sidecars: provisioner=${PROVISIONER_VERSION} snapshotter=${SNAPSHOTTER_VERSION}"
echo "            attacher=${ATTACHER_VERSION} resizer=${RESIZER_VERSION}"
echo "            registrar=${REGISTRAR_VERSION}"
echo ""

# -----------------------------------------------------------------------------
# Create output directory
# -----------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
echo "=== Generating manifests in ${OUTPUT_DIR}/ ==="

# =============================================================================
# 01-namespace.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/01-namespace.yaml" <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
EOF
echo "  ✓ 01-namespace.yaml"

# =============================================================================
# 02-csi-config.yaml (ConfigMaps)
# =============================================================================
cat > "${OUTPUT_DIR}/02-csi-config.yaml" <<EOF
---
# ceph-csi-config: CSI driver configuration (cluster ID + monitors)
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-config
  namespace: openshift-storage
data:
  config.json: |-
    [
      {
        "clusterID": "${CEPH_FSID}",
        "monitors": [
          "${CEPH_MON_IP}:6789"
        ]
      }
    ]
---
# ceph-csi-encryption-kms-config: KMS encryption config (empty = disabled)
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-encryption-kms-config
  namespace: openshift-storage
data:
  config.json: "{}"
---
# ceph-config: Native Ceph configuration (empty for standalone)
# NOTE: In the actual Deployment/DaemonSet, this is mounted as emptyDir
# instead of ConfigMap because ceph-csi v3.13.0 needs to write /etc/ceph/keyring
# at startup. The ConfigMap makes the directory read-only, causing CrashLoopBackOff.
# This ConfigMap is kept for documentation purposes only.
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-config
  namespace: openshift-storage
data:
  ceph.conf: ""
EOF
echo "  ✓ 02-csi-config.yaml"

# =============================================================================
# 03-csi-secret.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/03-csi-secret.yaml" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: csi-rbd-secret
  namespace: openshift-storage
type: Opaque
stringData:
  userID: openshift
  userKey: ${CEPH_USER_KEY}
EOF
echo "  ✓ 03-csi-secret.yaml"

# =============================================================================
# 04-rbac-provisioner.yaml
# Source: https://raw.githubusercontent.com/ceph/ceph-csi/master/deploy/rbd/kubernetes/csi-provisioner-rbac.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/04-rbac-provisioner.yaml" <<'EOF'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rbd-csi-provisioner
  namespace: openshift-storage
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: rbd-external-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "update", "delete", "patch"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims/status"]
    verbs: ["update", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshots"]
    verbs: ["get", "list", "watch", "update", "patch", "create"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshots/status"]
    verbs: ["get", "list", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotcontents"]
    verbs: ["create", "get", "list", "watch", "update", "delete", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments/status"]
    verbs: ["patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["csinodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotcontents/status"]
    verbs: ["update", "patch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    verbs: ["create"]
  - apiGroups: ["groupsnapshot.storage.k8s.io"]
    resources: ["volumegroupsnapshotclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["groupsnapshot.storage.k8s.io"]
    resources: ["volumegroupsnapshotcontents"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["groupsnapshot.storage.k8s.io"]
    resources: ["volumegroupsnapshotcontents/status"]
    verbs: ["update", "patch"]
  - apiGroups: ["replication.storage.openshift.io"]
    resources: ["volumegroupreplicationcontents"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["replication.storage.openshift.io"]
    resources: ["volumegroupreplicationclasses"]
    verbs: ["get"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: rbd-csi-provisioner-role
subjects:
  - kind: ServiceAccount
    name: rbd-csi-provisioner
    namespace: openshift-storage
roleRef:
  kind: ClusterRole
  name: rbd-external-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: openshift-storage
  name: rbd-external-provisioner-cfg
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "watch", "list", "delete", "update", "create"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: rbd-csi-provisioner-role-cfg
  namespace: openshift-storage
subjects:
  - kind: ServiceAccount
    name: rbd-csi-provisioner
    namespace: openshift-storage
roleRef:
  kind: Role
  name: rbd-external-provisioner-cfg
  apiGroup: rbac.authorization.k8s.io
EOF
echo "  ✓ 04-rbac-provisioner.yaml"

# =============================================================================
# 05-rbac-node.yaml
# Source: https://raw.githubusercontent.com/ceph/ceph-csi/master/deploy/rbd/kubernetes/csi-nodeplugin-rbac.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/05-rbac-node.yaml" <<'EOF'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rbd-csi-nodeplugin
  namespace: openshift-storage
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: rbd-csi-nodeplugin
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments"]
    verbs: ["list", "get"]
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    verbs: ["create"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: rbd-csi-nodeplugin
subjects:
  - kind: ServiceAccount
    name: rbd-csi-nodeplugin
    namespace: openshift-storage
roleRef:
  kind: ClusterRole
  name: rbd-csi-nodeplugin
  apiGroup: rbac.authorization.k8s.io
EOF
echo "  ✓ 05-rbac-node.yaml"

# =============================================================================
# 06-csidriver.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/06-csidriver.yaml" <<'EOF'
---
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: rbd.csi.ceph.com
spec:
  attachRequired: true
  podInfoOnMount: false
  fsGroupPolicy: File
EOF
echo "  ✓ 06-csidriver.yaml"

# =============================================================================
# 07-csi-rbd-controller.yaml (Deployment + Service)
# Source: https://raw.githubusercontent.com/ceph/ceph-csi/master/deploy/rbd/kubernetes/csi-rbdplugin-provisioner.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/07-csi-rbd-controller.yaml" <<EOF
---
# Metrics Service for controller
kind: Service
apiVersion: v1
metadata:
  name: csi-rbdplugin-provisioner
  namespace: openshift-storage
  labels:
    app: csi-metrics
spec:
  selector:
    app: csi-rbdplugin-provisioner
  ports:
    - name: http-metrics
      port: 8080
      protocol: TCP
      targetPort: 8680
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: csi-rbdplugin-provisioner
  namespace: openshift-storage
spec:
  replicas: ${CONTROLLER_REPLICAS}
  selector:
    matchLabels:
      app: csi-rbdplugin-provisioner
  template:
    metadata:
      labels:
        app: csi-rbdplugin-provisioner
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - csi-rbdplugin-provisioner
              topologyKey: "kubernetes.io/hostname"
      serviceAccountName: rbd-csi-provisioner
      priorityClassName: system-cluster-critical
      containers:
        # ---------------------------------------------------------------
        # 1. csi-rbdplugin (main CSI driver - controller mode)
        # ---------------------------------------------------------------
        - name: csi-rbdplugin
          image: quay.io/cephcsi/cephcsi:${CSI_VERSION}
          args:
            - "--nodeid=\$(NODE_ID)"
            - "--type=rbd"
            - "--controllerserver=true"
            - "--endpoint=\$(CSI_ENDPOINT)"
            - "--csi-addons-endpoint=\$(CSI_ADDONS_ENDPOINT)"
            - "--v=5"
            - "--drivername=rbd.csi.ceph.com"
            - "--pidlimit=-1"
            - "--rbdhardmaxclonedepth=8"
            - "--rbdsoftmaxclonedepth=4"
            - "--enableprofiling=false"
            - "--setmetadata=true"
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: CSI_ENDPOINT
              value: unix:///csi/csi-provisioner.sock
            - name: CSI_ADDONS_ENDPOINT
              value: unix:///csi/csi-addons.sock
          imagePullPolicy: "IfNotPresent"
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
            - mountPath: /dev
              name: host-dev
            - mountPath: /sys
              name: host-sys
            - mountPath: /lib/modules
              name: lib-modules
              readOnly: true
            - name: ceph-csi-config
              mountPath: /etc/ceph-csi-config/
            - name: ceph-csi-encryption-kms-config
              mountPath: /etc/ceph-csi-encryption-kms-config/
            - name: keys-tmp-dir
              mountPath: /tmp/csi/keys
            - name: ceph-config
              mountPath: /etc/ceph/
            - name: oidc-token
              mountPath: /run/secrets/tokens
              readOnly: true
        # ---------------------------------------------------------------
        # 2. csi-provisioner
        # ---------------------------------------------------------------
        - name: csi-provisioner
          image: registry.k8s.io/sig-storage/csi-provisioner:${PROVISIONER_VERSION}
          args:
            - "--csi-address=\$(ADDRESS)"
            - "--v=1"
            - "--timeout=150s"
            - "--retry-interval-start=500ms"
            - "--leader-election=true"
            - "--feature-gates=HonorPVReclaimPolicy=true"
            - "--prevent-volume-mode-conversion=true"
            - "--default-fstype=ext4"
            - "--extra-create-metadata=true"
            - "--immediate-topology=false"
            - "--http-endpoint=\$(POD_IP):8090"
          env:
            - name: ADDRESS
              value: unix:///csi/csi-provisioner.sock
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          imagePullPolicy: "IfNotPresent"
          ports:
            - containerPort: 8090
              name: provisioner
              protocol: TCP
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
        # ---------------------------------------------------------------
        # 3. csi-snapshotter
        # ---------------------------------------------------------------
        - name: csi-snapshotter
          image: registry.k8s.io/sig-storage/csi-snapshotter:${SNAPSHOTTER_VERSION}
          args:
            - "--csi-address=\$(ADDRESS)"
            - "--v=1"
            - "--timeout=150s"
            - "--leader-election=true"
            - "--extra-create-metadata=true"
            - "--feature-gates=CSIVolumeGroupSnapshot=true"
            - "--http-endpoint=\$(POD_IP):8092"
          env:
            - name: ADDRESS
              value: unix:///csi/csi-provisioner.sock
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          imagePullPolicy: "IfNotPresent"
          ports:
            - containerPort: 8092
              name: snapshotter
              protocol: TCP
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
        # ---------------------------------------------------------------
        # 4. csi-attacher
        # ---------------------------------------------------------------
        - name: csi-attacher
          image: registry.k8s.io/sig-storage/csi-attacher:${ATTACHER_VERSION}
          args:
            - "--v=1"
            - "--csi-address=\$(ADDRESS)"
            - "--leader-election=true"
            - "--retry-interval-start=500ms"
            - "--default-fstype=ext4"
            - "--http-endpoint=\$(POD_IP):8093"
          env:
            - name: ADDRESS
              value: /csi/csi-provisioner.sock
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          imagePullPolicy: "IfNotPresent"
          ports:
            - containerPort: 8093
              name: attacher
              protocol: TCP
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
        # ---------------------------------------------------------------
        # 5. csi-resizer
        # ---------------------------------------------------------------
        - name: csi-resizer
          image: registry.k8s.io/sig-storage/csi-resizer:${RESIZER_VERSION}
          args:
            - "--csi-address=\$(ADDRESS)"
            - "--v=1"
            - "--timeout=150s"
            - "--leader-election"
            - "--retry-interval-start=500ms"
            - "--handle-volume-inuse-error=false"
            - "--feature-gates=RecoverVolumeExpansionFailure=true"
            - "--http-endpoint=\$(POD_IP):8091"
          env:
            - name: ADDRESS
              value: unix:///csi/csi-provisioner.sock
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          imagePullPolicy: "IfNotPresent"
          ports:
            - containerPort: 8091
              name: resizer
              protocol: TCP
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
        # ---------------------------------------------------------------
        # 6. csi-rbdplugin-controller (metadata management)
        # ---------------------------------------------------------------
        - name: csi-rbdplugin-controller
          image: quay.io/cephcsi/cephcsi:${CSI_VERSION}
          args:
            - "--type=controller"
            - "--v=5"
            - "--drivername=rbd.csi.ceph.com"
            - "--drivernamespace=\$(DRIVER_NAMESPACE)"
            - "--setmetadata=true"
          env:
            - name: DRIVER_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          imagePullPolicy: "IfNotPresent"
          volumeMounts:
            - name: ceph-csi-config
              mountPath: /etc/ceph-csi-config/
            - name: keys-tmp-dir
              mountPath: /tmp/csi/keys
            - name: ceph-config
              mountPath: /etc/ceph/
        # ---------------------------------------------------------------
        # 7. liveness-prometheus (health/metrics)
        # ---------------------------------------------------------------
        - name: liveness-prometheus
          image: quay.io/cephcsi/cephcsi:${CSI_VERSION}
          args:
            - "--type=liveness"
            - "--endpoint=\$(CSI_ENDPOINT)"
            - "--metricsport=8680"
            - "--metricspath=/metrics"
            - "--polltime=60s"
            - "--timeout=3s"
          env:
            - name: CSI_ENDPOINT
              value: unix:///csi/csi-provisioner.sock
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          ports:
            - containerPort: 8680
              name: http-metrics
              protocol: TCP
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
          imagePullPolicy: "IfNotPresent"
      volumes:
        - name: host-dev
          hostPath:
            path: /dev
        - name: host-sys
          hostPath:
            path: /sys
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: socket-dir
          emptyDir:
            medium: "Memory"
        # WORKAROUND: ceph-csi v3.13.0 writes /etc/ceph/keyring at startup.
        # Upstream uses configMap here, but ConfigMap mounts are read-only,
        # causing CrashLoopBackOff. Using emptyDir as workaround.
        # For v3.14.0+, test switching back to configMap: ceph-config
        - name: ceph-config
          emptyDir:
            medium: "Memory"
        - name: ceph-csi-config
          configMap:
            name: ceph-csi-config
        - name: ceph-csi-encryption-kms-config
          configMap:
            name: ceph-csi-encryption-kms-config
        - name: keys-tmp-dir
          emptyDir:
            medium: "Memory"
        - name: oidc-token
          projected:
            sources:
              - serviceAccountToken:
                  path: oidc-token
                  expirationSeconds: 3600
                  audience: ceph-csi-kms
EOF
echo "  ✓ 07-csi-rbd-controller.yaml"

# =============================================================================
# 08-csi-rbd-node.yaml (DaemonSet + Service)
# Source: https://raw.githubusercontent.com/ceph/ceph-csi/master/deploy/rbd/kubernetes/csi-rbdplugin.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/08-csi-rbd-node.yaml" <<EOF
---
kind: DaemonSet
apiVersion: apps/v1
metadata:
  name: csi-rbdplugin
  namespace: openshift-storage
spec:
  selector:
    matchLabels:
      app: csi-rbdplugin
  template:
    metadata:
      labels:
        app: csi-rbdplugin
    spec:
      serviceAccountName: rbd-csi-nodeplugin
      hostNetwork: true
      hostPID: true
      priorityClassName: system-node-critical
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        # ---------------------------------------------------------------
        # 1. csi-rbdplugin (main CSI driver - node mode)
        # ---------------------------------------------------------------
        - name: csi-rbdplugin
          securityContext:
            privileged: true
            capabilities:
              add: ["SYS_ADMIN"]
            allowPrivilegeEscalation: true
          image: quay.io/cephcsi/cephcsi:${CSI_VERSION}
          args:
            - "--nodeid=\$(NODE_ID)"
            - "--pluginpath=/var/lib/kubelet/plugins"
            - "--stagingpath=/var/lib/kubelet/plugins/kubernetes.io/csi/"
            - "--type=rbd"
            - "--nodeserver=true"
            - "--endpoint=\$(CSI_ENDPOINT)"
            - "--csi-addons-endpoint=\$(CSI_ADDONS_ENDPOINT)"
            - "--v=5"
            - "--drivername=rbd.csi.ceph.com"
            - "--enableprofiling=false"
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: CSI_ENDPOINT
              value: unix:///csi/csi.sock
            - name: CSI_ADDONS_ENDPOINT
              value: unix:///csi/csi-addons.sock
          imagePullPolicy: "IfNotPresent"
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
            - mountPath: /dev
              name: host-dev
            - mountPath: /sys
              name: host-sys
            - mountPath: /run/mount
              name: host-mount
            - mountPath: /etc/selinux
              name: etc-selinux
              readOnly: true
            - mountPath: /lib/modules
              name: lib-modules
              readOnly: true
            - name: ceph-csi-config
              mountPath: /etc/ceph-csi-config/
            - name: ceph-csi-encryption-kms-config
              mountPath: /etc/ceph-csi-encryption-kms-config/
            - name: plugin-dir
              mountPath: /var/lib/kubelet/plugins
              mountPropagation: "Bidirectional"
            - name: mountpoint-dir
              mountPath: /var/lib/kubelet/pods
              mountPropagation: "Bidirectional"
            - name: keys-tmp-dir
              mountPath: /tmp/csi/keys
            - name: ceph-logdir
              mountPath: /var/log/ceph
            - name: ceph-config
              mountPath: /etc/ceph/
            - name: oidc-token
              mountPath: /run/secrets/tokens
              readOnly: true
        # ---------------------------------------------------------------
        # 2. driver-registrar
        # ---------------------------------------------------------------
        - name: driver-registrar
          securityContext:
            privileged: true
            allowPrivilegeEscalation: true
          image: registry.k8s.io/sig-storage/csi-node-driver-registrar:${REGISTRAR_VERSION}
          args:
            - "--v=1"
            - "--csi-address=/csi/csi.sock"
            - "--kubelet-registration-path=/var/lib/kubelet/plugins/rbd.csi.ceph.com/csi.sock"
          env:
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
            - name: registration-dir
              mountPath: /registration
        # ---------------------------------------------------------------
        # 3. liveness-prometheus (health/metrics)
        # ---------------------------------------------------------------
        - name: liveness-prometheus
          securityContext:
            privileged: true
            allowPrivilegeEscalation: true
          image: quay.io/cephcsi/cephcsi:${CSI_VERSION}
          args:
            - "--type=liveness"
            - "--endpoint=\$(CSI_ENDPOINT)"
            - "--metricsport=8680"
            - "--metricspath=/metrics"
            - "--polltime=60s"
            - "--timeout=3s"
          env:
            - name: CSI_ENDPOINT
              value: unix:///csi/csi.sock
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
          imagePullPolicy: "IfNotPresent"
      volumes:
        - name: socket-dir
          hostPath:
            path: /var/lib/kubelet/plugins/rbd.csi.ceph.com
            type: DirectoryOrCreate
        - name: plugin-dir
          hostPath:
            path: /var/lib/kubelet/plugins
            type: Directory
        - name: mountpoint-dir
          hostPath:
            path: /var/lib/kubelet/pods
            type: DirectoryOrCreate
        - name: ceph-logdir
          hostPath:
            path: /var/log/ceph
            type: DirectoryOrCreate
        - name: registration-dir
          hostPath:
            path: /var/lib/kubelet/plugins_registry/
            type: Directory
        - name: host-dev
          hostPath:
            path: /dev
        - name: host-sys
          hostPath:
            path: /sys
        - name: etc-selinux
          hostPath:
            path: /etc/selinux
        - name: host-mount
          hostPath:
            path: /run/mount
        - name: lib-modules
          hostPath:
            path: /lib/modules
        # WORKAROUND: same as controller - emptyDir for v3.13.0 keyring write
        - name: ceph-config
          emptyDir:
            medium: "Memory"
        - name: ceph-csi-config
          configMap:
            name: ceph-csi-config
        - name: ceph-csi-encryption-kms-config
          configMap:
            name: ceph-csi-encryption-kms-config
        - name: keys-tmp-dir
          emptyDir:
            medium: "Memory"
        - name: oidc-token
          projected:
            sources:
              - serviceAccountToken:
                  path: oidc-token
                  expirationSeconds: 3600
                  audience: ceph-csi-kms
---
# Metrics Service for node plugin
apiVersion: v1
kind: Service
metadata:
  name: csi-metrics-rbdplugin
  namespace: openshift-storage
  labels:
    app: csi-metrics
spec:
  ports:
    - name: http-metrics
      port: 8080
      protocol: TCP
      targetPort: 8680
  selector:
    app: csi-rbdplugin
EOF
echo "  ✓ 08-csi-rbd-node.yaml"

# =============================================================================
# 09-storageclass.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/09-storageclass.yaml" <<EOF
---
# StorageClass for general workloads (RWO, filesystem)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: ${CEPH_FSID}
  pool: ${POOL_GENERAL}
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
reclaimPolicy: Delete
allowVolumeExpansion: true
mountOptions:
  - discard
volumeBindingMode: Immediate
EOF
echo "  ✓ 09-storageclass.yaml"

# =============================================================================
# 10-storageclass-vms.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/10-storageclass-vms.yaml" <<EOF
---
# StorageClass for VMs (RWX Block - Live Migration)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd-virtualization
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: ${CEPH_FSID}
  pool: ${POOL_VMS}
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF
echo "  ✓ 10-storageclass-vms.yaml"

# =============================================================================
# 11-apply-scc.sh (OpenShift SCC helper)
# =============================================================================
cat > "${OUTPUT_DIR}/11-apply-scc.sh" <<'EOF'
#!/bin/bash
# Apply required SCCs for ceph-csi on OpenShift
echo "Applying privileged SCCs for ceph-csi service accounts..."
oc adm policy add-scc-to-user privileged system:serviceaccount:openshift-storage:rbd-csi-provisioner
oc adm policy add-scc-to-user privileged system:serviceaccount:openshift-storage:rbd-csi-nodeplugin
echo "✓ SCCs applied"
EOF
chmod +x "${OUTPUT_DIR}/11-apply-scc.sh"
echo "  ✓ 11-apply-scc.sh"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Manifests generated successfully! ==="
echo ""
echo "Files in ${OUTPUT_DIR}/:"
ls -1 "${OUTPUT_DIR}/"
echo ""
echo "=== Changes from upstream ==="
echo "  - Namespace: openshift-storage (upstream uses 'default')"
echo "  - ceph-csi image: ${CSI_VERSION} (upstream uses 'canary')"
echo "  - ceph-config volume: emptyDir (v3.13.0 keyring write workaround)"
echo "  - Controller replicas: ${CONTROLLER_REPLICAS} (upstream default: 3)"
echo ""
echo "=== To apply ==="
echo ""
echo "  # 1. Apply SCCs (required on OpenShift - do this FIRST):"
echo "  ${OUTPUT_DIR}/11-apply-scc.sh"
echo ""
echo "  # 2. Apply all manifests:"
echo "  oc apply -f ${OUTPUT_DIR}/"
echo ""
echo "  # 3. Verify:"
echo "  oc get pods -n openshift-storage"
echo "  oc get sc"
echo ""
