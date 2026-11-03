# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


FROM ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.82.0-1@sha256:924a4f85393da2d7ce4ef2f001f6dca6944eb4f93bdc2896dbfb5c870c741bfb AS otelagent

# -----------------------------------------------------------------------------

FROM docker.io/library/node:26.12.1-slim@sha256:36793bcbb160a6a16cede1e62b93f84e26b78a972a8a4c0b879c1c12f22761ec AS builder

WORKDIR /usr/src/app/

COPY ./src/payment/package.json package.json
COPY ./src/payment/package-lock.json package-lock.json

RUN npm ci --omit=dev

# -----------------------------------------------------------------------------

FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:cb606325b7ec4af55462cb0b424a53b452a5b4a894ffe841fcf1048d216fb9f8

WORKDIR /usr/src/app/

COPY --from=builder /usr/src/app/node_modules/ node_modules/

# Path and NODE_OPTIONS value match what the OpenTelemetry Operator injects, so a
# statically built image and an operator-injected pod behave identically. Changing
# either breaks that equivalence.
COPY --from=otelagent /autoinstrumentation /otel-auto-instrumentation-nodejs

COPY ./pb/demo.proto demo.proto

COPY ./src/payment/charge.js charge.js
COPY ./src/payment/index.js index.js
COPY ./src/payment/logger.js logger.js

ARG PAYMENT_PORT=50051
EXPOSE ${PAYMENT_PORT}

ENV NODE_OPTIONS="--require /otel-auto-instrumentation-nodejs/autoinstrumentation.js"

CMD ["index.js"]
