# Top-level dispatcher. This repo houses many demos; each lives under demos/<name>/.
set shell := ["bash", "-cu"]

# List available demos
demos:
    @ls -1 demos

# Run a demo target, e.g. `just demo spiffe-cross-boundary status`
demo NAME *ARGS:
    @just --justfile demos/{{NAME}}/Justfile --working-directory demos/{{NAME}} {{ARGS}}
