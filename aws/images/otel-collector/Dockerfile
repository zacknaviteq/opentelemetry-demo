# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
# Collector contrib with the AWS/CloudWatch pipeline config baked in.
ARG COLLECTOR_CONTRIB_IMAGE=ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.160.0
FROM ${COLLECTOR_CONTRIB_IMAGE}
COPY aws/images/otel-collector/otelcol-config-aws.yml /etc/otelcol-contrib/config.yaml
