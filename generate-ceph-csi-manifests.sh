#!/bin/bash
# =============================================================================
# generate-ceph-csi-manifests.sh
# =============================================================================
# Generates all ceph-csi RBD manifests for OpenShift.
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
# 02-csi-config.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/02-csi-config.yaml" <<EOF
---
# ceph-csi config - cluster connection info
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-config
  namespace: openshift-storage
data:
  config.json: |
    [
      {
        "clusterID": "${CEPH_FSID}",
        "monitors": [
          "${CEPH_MON_IP}:6789"
        ]
      }
    ]
---
# KMS config (empty - required by ceph-csi even if not using encryption)
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-encryption-kms-config
  namespace: openshift-storage
data:
  config.json: "{}"
---
# ceph.conf override
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-config
  namespace: openshift-storage
data:
  ceph.conf: |
    [global]
    auth_cluster_required = cephx
    auth_service_required = cephx
    auth_client_required = cephx
    mon_host = ${CEPH_MON_IP}
EOF
echo "  ✓ 02-csi-config.yaml"

# =============================================================================
# 03-csi-secret.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/03-csi-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: csi-rbd-secret
  namespace: openshift-storage
stringData:
  userID: openshift
  userKey: ${CEPH_USER_KEY}
EOF
echo "  ✓ 03-csi-secret.yaml"

# =============================================================================
# 04-rbac-provisioner.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/04-rbac-provisioner.yaml" <<'EOF'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rbd-csi-provisioner
  namespace: openshift-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
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
    resources: ["volumesnapshotclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotcontents"]
    verbs: ["get", "list", "watch", "create", "update", "delete", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotcontents/status"]
    verbs: ["update", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments/status"]
    verbs: ["patch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["csinodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
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
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rbd-external-provisioner-cfg
  namespace: openshift-storage
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "watch", "list", "delete", "update", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
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
# =============================================================================
cat > "${OUTPUT_DIR}/05-rbac-node.yaml" <<'EOF'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rbd-csi-nodeplugin
  namespace: openshift-storage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rbd-csi-nodeplugin
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
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
# 07-csi-rbd-controller.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/07-csi-rbd-controller.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: csi-rbdplugin-provisioner
  namespace: openshift-storage
  labels:
    app: csi-rbdplugin-provisioner
spec:
  replicas: 2
  selector:
    matchLabels:
      app: csi-rbdplugin-provisioner
  template:
    metadata:
      labels:
        app: csi-rbdplugin-provisioner
    spec:
      serviceAccountName: rbd-csi-provisioner
      priorityClassName: system-cluster-critical
      containers:
        # -- csi-provisioner sidecar --
        - name: csi-provisioner
          image: registry.k8s.io/sig-storage/csi-provisioner:v5.1.0
          args:
            - "--csi-address=\$(ADDRESS)"
            - "--v=5"
            - "--timeout=150s"
            - "--retry-interval-start=500ms"
            - "--leader-election=true"
            - "--default-fstype=ext4"
            - "--extra-create-metadata=true"
          env:
            - name: ADDRESS
              value: unix:///csi/csi-provisioner.sock
          volumeMounts:
            - name: socket-dir
              mountPath: /csi

        # -- csi-attacher sidecar --
        - name: csi-attacher
          image: registry.k8s.io/sig-storage/csi-attacher:v4.7.0
          args:
            - "--v=5"
            - "--csi-address=\$(ADDRESS)"
            - "--leader-election=true"
            - "--retry-interval-start=500ms"
          env:
            - name: ADDRESS
              value: /csi/csi-provisioner.sock
          volumeMounts:
            - name: socket-dir
              mountPath: /csi

        # -- csi-resizer sidecar --
        - name: csi-resizer
          image: registry.k8s.io/sig-storage/csi-resizer:v1.12.0
          args:
            - "--csi-address=\$(ADDRESS)"
            - "--v=5"
            - "--timeout=150s"
            - "--leader-election=true"
            - "--handle-volume-inuse-error=false"
          env:
            - name: ADDRESS
              value: unix:///csi/csi-provisioner.sock
          volumeMounts:
            - name: socket-dir
              mountPath: /csi

        # -- csi-snapshotter sidecar --
        - name: csi-snapshotter
          image: registry.k8s.io/sig-storage/csi-snapshotter:v8.2.0
          args:
            - "--csi-address=\$(ADDRESS)"
            - "--v=5"
            - "--timeout=150s"
            - "--leader-election=true"
          env:
            - name: ADDRESS
              value: unix:///csi/csi-provisioner.sock
          volumeMounts:
            - name: socket-dir
              mountPath: /csi

        # -- ceph-csi RBD plugin --
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
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
            - name: host-dev
              mountPath: /dev
            - name: host-sys
              mountPath: /sys
            - name: lib-modules
              mountPath: /lib/modules
              readOnly: true
            - name: ceph-csi-config
              mountPath: /etc/ceph-csi-config
            - name: ceph-config
              mountPath: /etc/ceph
            - name: keys-tmp-dir
              mountPath: /tmp/csi/keys
            - name: ceph-csi-encryption-kms-config
              mountPath: /etc/ceph-csi-encryption-kms-config

      volumes:
        - name: socket-dir
          emptyDir:
            medium: Memory
        - name: host-dev
          hostPath:
            path: /dev
        - name: host-sys
          hostPath:
            path: /sys
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: ceph-csi-config
          configMap:
            name: ceph-csi-config
        - name: ceph-config
          configMap:
            name: ceph-config
        - name: keys-tmp-dir
          emptyDir:
            medium: Memory
        - name: ceph-csi-encryption-kms-config
          configMap:
            name: ceph-csi-encryption-kms-config
EOF
echo "  ✓ 07-csi-rbd-controller.yaml"

# =============================================================================
# 08-csi-rbd-node.yaml
# =============================================================================
cat > "${OUTPUT_DIR}/08-csi-rbd-node.yaml" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: csi-rbdplugin
  namespace: openshift-storage
  labels:
    app: csi-rbdplugin
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
      priorityClassName: system-node-critical
      hostNetwork: true
      hostPID: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        # -- driver-registrar sidecar --
        - name: driver-registrar
          image: registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.12.0
          args:
            - "--v=5"
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
          securityContext:
            privileged: true

        # -- ceph-csi RBD node plugin --
        - name: csi-rbdplugin
          image: quay.io/cephcsi/cephcsi:${CSI_VERSION}
          args:
            - "--nodeid=\$(NODE_ID)"
            - "--type=rbd"
            - "--nodeserver=true"
            - "--endpoint=\$(CSI_ENDPOINT)"
            - "--csi-addons-endpoint=\$(CSI_ADDONS_ENDPOINT)"
            - "--v=5"
            - "--drivername=rbd.csi.ceph.com"
            - "--stagingpath=/var/lib/kubelet/plugins/kubernetes.io/csi/"
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
          securityContext:
            privileged: true
            capabilities:
              add: ["SYS_ADMIN"]
            allowPrivilegeEscalation: true
          volumeMounts:
            - name: socket-dir
              mountPath: /csi
            - name: mountpoint-dir
              mountPath: /var/lib/kubelet/pods
              mountPropagation: Bidirectional
            - name: plugin-dir
              mountPath: /var/lib/kubelet/plugins
              mountPropagation: Bidirectional
            - name: host-dev
              mountPath: /dev
            - name: host-sys
              mountPath: /sys
            - name: etc-selinux
              mountPath: /etc/selinux
              readOnly: true
            - name: lib-modules
              mountPath: /lib/modules
              readOnly: true
            - name: ceph-csi-config
              mountPath: /etc/ceph-csi-config
            - name: ceph-config
              mountPath: /etc/ceph
            - name: keys-tmp-dir
              mountPath: /tmp/csi/keys
            - name: ceph-csi-encryption-kms-config
              mountPath: /etc/ceph-csi-encryption-kms-config

      volumes:
        - name: socket-dir
          hostPath:
            path: /var/lib/kubelet/plugins/rbd.csi.ceph.com
            type: DirectoryOrCreate
        - name: registration-dir
          hostPath:
            path: /var/lib/kubelet/plugins_registry
        - name: mountpoint-dir
          hostPath:
            path: /var/lib/kubelet/pods
            type: DirectoryOrCreate
        - name: plugin-dir
          hostPath:
            path: /var/lib/kubelet/plugins
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
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: ceph-csi-config
          configMap:
            name: ceph-csi-config
        - name: ceph-config
          configMap:
            name: ceph-config
        - name: keys-tmp-dir
          emptyDir:
            medium: Memory
        - name: ceph-csi-encryption-kms-config
          configMap:
            name: ceph-csi-encryption-kms-config
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
# 11-scc.sh (script auxiliar para SCC)
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
echo "=== To apply ==="
echo ""
echo "  # 1. Apply all manifests:"
echo "  oc apply -f ${OUTPUT_DIR}/"
echo ""
echo "  # 2. Apply SCCs (required on OpenShift):"
echo "  ${OUTPUT_DIR}/11-apply-scc.sh"
echo ""
echo "  # 3. Verify:"
echo "  oc get pods -n openshift-storage"
echo "  oc get sc"
echo ""
