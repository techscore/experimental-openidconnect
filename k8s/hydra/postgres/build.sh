#!/bin/bash

mkdir -p generated
for target in local; do
  kustomize build $target > generated/hydra-postgres.$target.all.yaml
done