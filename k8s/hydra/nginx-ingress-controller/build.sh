#!/bin/bash

mkdir -p generated
for target in local; do
  kustomize build $target > generated/nginx-ingress-controller.$target.all.yaml
done