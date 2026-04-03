FROM temporalio/ui:2.43.3

ENTRYPOINT ["/bin/sh", "-c", "TEMPORAL_ADDRESS=$TEMPORAL_GRPC_HOST:7233 TEMPORAL_UI_PORT=${PORT:-8080} ./start-ui-server.sh"]
