#!/usr/bin/env bash
# W's admission probes (design section 3). Each attempt creates a fresh, uniquely named
# object and records the request, the exact API response and the resulting object; any
# object that was created is deleted once observed. Source after lab/collect.sh with
# RUN_DIR set; do not execute.

admission_render() { # TEMPLATE NAME: lab/admission/TEMPLATE.yaml with NAME substituted
  local tpl="$LAB_DIR/admission/${1:?admission_render: TEMPLATE required}.yaml"
  [ -f "$tpl" ] || die "admission_render: no template $tpl (run Task 11's discovery first)"
  # shellcheck disable=SC2016
  NAME="${2:?admission_render: NAME required}" envsubst '${NAME} ${LAB_NS} ${IMAGE_BUSYBOX}' < "$tpl"
}

admission_attempt() { # PHASE OBJECT TEMPLATE
  local phase="$1" obj="$2" tpl="$3" dir="$RUN_DIR/admission/$1"
  mkdir -p "$dir"
  [ ! -e "$dir/$obj.request.yaml" ] || die "admission_attempt: $dir/$obj.request.yaml exists; evidence is written once"
  admission_render "$tpl" "$obj" > "$dir/$obj.request.yaml"
  capture "admission/$phase/$obj.response.txt" kubectl create -f "$dir/$obj.request.yaml"
  capture "admission/$phase/$obj.observed.yaml" kubectl get -f "$dir/$obj.request.yaml" -o yaml
  if [ "$(tail -n 1 "$dir/$obj.observed.yaml")" = "[exit 0]" ]; then
    capture "admission/$phase/$obj.delete.txt" kubectl delete -f "$dir/$obj.request.yaml" --wait=false
  fi
}

admission_probes() { # PHASE SUFFIX: probes (a)-(d), one fresh object each
  local phase="$1" s="$2"
  admission_attempt "$phase" "inject-probe-$s" inject-probe
  admission_attempt "$phase" "policy-invalid-$s" policy-invalid
  admission_attempt "$phase" "serviceprofile-invalid-$s" serviceprofile-invalid
  admission_attempt "$phase" "policy-valid-$s" policy-valid
  admission_attempt "$phase" "serviceprofile-valid-$s" serviceprofile-valid
}
