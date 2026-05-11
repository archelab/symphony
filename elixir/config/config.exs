import Config

config :phoenix, :json_library, Jason

# SPEC §13.1 worker-stop structured-log metadata keys. Listed here so credo's
# `MissedMetadataKeyInLoggerConfig` check (and any structured-log backend)
# acknowledges them as known keys.
config :logger, :default_formatter,
  metadata: [
    :issue_id,
    :issue_identifier,
    :session_id,
    :reason,
    :owner,
    :project_number,
    :project_id,
    :status_field,
    :retry_after_seconds,
    :context
  ]

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
