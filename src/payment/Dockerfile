# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


FROM ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:0.82.0-5@sha256:fec6d251e1d6de952c4e2f913378a9f3566d3daacca86b44900f3625f39bb297 AS otelagent

# -----------------------------------------------------------------------------

FROM docker.io/library/node:26.13.0-slim@sha256:5adad64f9a1fca2d51972caa65983634c8a774eb300d72b20f7f2a0f60368072 AS builder

WORKDIR /usr/src/app/

COPY ./src/payment/package.json package.json
COPY ./src/payment/package-lock.json package-lock.json

RUN npm ci --omit=dev

# -----------------------------------------------------------------------------

FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:088a01637f22908632ba09018be2e0b516f2fa6f7869c191d29491139db43c78

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
