# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
#  packer-imaging-runner
# -----------------------------------------------------------------------------
#  The image every build CronJob runs. See kubernetes/charts/packer-imaging.
#
#  It deliberately does NOT install Packer plugins. Each project pins its own in
#  a `required_plugins` block, and `packer init .` installs them into
#  PACKER_PLUGIN_PATH at the start of every run. Baking a plugin version in here
#  would silently drift from the templates and defeat the pinning.
#
#  Build and publish:
#    docker build -t ghcr.io/sbeaver21/packer-imaging-runner:1.0.0 kubernetes/runner
#    docker push ghcr.io/sbeaver21/packer-imaging-runner:1.0.0
# -----------------------------------------------------------------------------
FROM hashicorp/packer:1.11.3

USER root

# ansible-core and py3-netaddr are for the Linux baseline playbooks; xorriso is
# used when a build stages an ISO outside vSphere. git is not here because the
# checkout is done by the init container in the CronJob.
RUN apk add --no-cache \
      ansible-core \
      bash \
      ca-certificates \
      curl \
      jq \
      openssh-client \
      py3-netaddr \
      py3-pip \
      tzdata \
      xorriso

ENV PACKER_PLUGIN_PATH=/var/cache/packer \
    CHECKPOINT_DISABLE=1 \
    HOME=/tmp

# Owned by the uid the CronJob runs as (1000), so `packer init` can write the
# plugin cache and the manifest post-processor can write into the checkout.
RUN mkdir -p "${PACKER_PLUGIN_PATH}" /workspace \
 && chown -R 1000:1000 "${PACKER_PLUGIN_PATH}" /workspace \
 && chmod 1777 /tmp

USER 1000:1000
WORKDIR /workspace

# The chart sets an explicit command and args; this entrypoint only matters if
# the image is run by hand.
ENTRYPOINT ["/bin/sh", "-c"]
CMD ["packer version"]
