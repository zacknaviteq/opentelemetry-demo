# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
# Seeds the shared flags volume of the flagd ECS task (flagd + flagd-ui), replacing
# the ./src/flagd bind mount used by compose.
FROM public.ecr.aws/docker/library/busybox:1.37
COPY src/flagd/demo.flagd.json /seed/demo.flagd.json
CMD ["sh", "-c", "cp /seed/demo.flagd.json /data/demo.flagd.json && chmod 0777 /data && chmod 0666 /data/demo.flagd.json"]
