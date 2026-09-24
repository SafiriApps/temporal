FROM temporalio/ui:2.43.3

COPY --from=quay.io/oauth2-proxy/oauth2-proxy:v7.15.4 /bin/oauth2-proxy /usr/local/bin/oauth2-proxy

# The UI loads config/base.yaml before docker.yaml. Binding it to localhost means it's reachable only through oauth2-proxy.
RUN echo 'host: 127.0.0.1' > config/base.yaml

# oauth2-proxy owns the public $PORT and forwards to the UI only after a Google sign-in (OAUTH2_PROXY_* env vars).
# The UI runs as PID 1, so the container stops if it dies; if oauth2-proxy dies, Render's /ping health check restarts the instance.
ENTRYPOINT ["/bin/sh", "-c", "/usr/local/bin/oauth2-proxy --http-address=0.0.0.0:${PORT:-8080} --upstream=http://127.0.0.1:8081 & exec env TEMPORAL_ADDRESS=$TEMPORAL_GRPC_HOST:7233 TEMPORAL_UI_PORT=8081 ./start-ui-server.sh"]
