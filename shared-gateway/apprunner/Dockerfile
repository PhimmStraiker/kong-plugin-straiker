# Shared Straiker-guardrailed Claude Code gateway — a Konnect hybrid DATA PLANE with
# the straiker + straiker-coding plugins baked in, for AWS App Runner.
#
# The Konnect cluster cert/key are injected at runtime (App Runner env/secrets, base64)
# and materialized by the entrypoint — never baked into the image.
FROM kong/kong-gateway:3.14

USER root
# bake the plugins into the image
COPY kong/plugins/straiker        /usr/local/share/lua/5.1/kong/plugins/straiker
COPY kong/plugins/straiker-coding /usr/local/share/lua/5.1/kong/plugins/straiker-coding
COPY shared-gateway/apprunner/entrypoint.sh /entrypoint-konggw.sh
RUN chmod +x /entrypoint-konggw.sh

# App Runner routes to one port; Kong proxy listens on 8000.
EXPOSE 8000
USER kong
ENTRYPOINT ["/entrypoint-konggw.sh"]
