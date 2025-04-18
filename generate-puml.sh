#!/usr/bin/env bash

for f in plantuml/*.puml; do
  echo "Rendering $f..."
  java -jar lib/plantuml.jar -tpng -o "../images/generated" "$f"
done
