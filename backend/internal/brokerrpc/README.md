# MQTTS authorization contract snapshot

`authorization.proto` and `authzv1/*.go` are copied unchanged from the independently
versioned MQTTS `modules/authz` module. Generated headers record compiler versions.
The application imports only these generated messages and management client; no
MQTTS source checkout or application-server code is required by the other project.

For a contract upgrade, copy the canonical proto and generated Go files from the
tested MQTTS revision, then update `broker/mqtts/compatibility.json`. Consumer CI
checks the proto SHA-256 against the independently built image metadata and tests
the real backend, broker and authorization service together.

The backend publishes application permissions in `service/broker_security_service.go`.
No broker authorization query is served by this application.
