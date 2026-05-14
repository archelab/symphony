defmodule SymphonyElixirWeb.IssueLive do
  @moduledoc """
  Live issue/session detail page for the observability dashboard.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Observability.Notifications
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @impl true
  def mount(params, _session, socket) do
    issue_identifier = issue_identifier_from_params(params)

    socket =
      socket
      |> assign(:issue_identifier, issue_identifier)
      |> assign(:payload, load_payload(issue_identifier))

    _ =
      if connected?(socket) do
        :ok = Notifications.subscribe()
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    issue_identifier = issue_identifier_from_params(params)

    {:noreply,
     socket
     |> assign(:issue_identifier, issue_identifier)
     |> assign(:payload, load_payload(issue_identifier))}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload, load_payload(socket.assigns.issue_identifier))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card detail-hero">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Issue drilldown
            </p>
            <h1 class="detail-title">
              <%= @issue_identifier || "Issue not selected" %>
            </h1>
            <p class="hero-copy">
              Session metadata, attempts, token usage, and the best available runtime event timeline.
            </p>
          </div>

          <div class="status-stack">
            <a class="subtle-link" href="/">Dashboard</a>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Issue unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Status</p>
            <p class="metric-value metric-value-tight"><%= @payload.status %></p>
            <p class="metric-detail"><%= value_or_na(@payload.issue[:state]) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Attempt</p>
            <p class="metric-value numeric"><%= @payload.workpad.current_attempt %></p>
            <p class="metric-detail">Prior sessions: <%= @payload.workpad.prior_sessions %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.session.tokens.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.session.tokens.input_tokens) %> / Out <%= format_int(@payload.session.tokens.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Stop reason</p>
            <p class="metric-value metric-value-tight"><%= value_or_na(@payload.session.stop_reason) %></p>
            <p class="metric-detail">Latest completed session.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Workspace and session</h2>
              <p class="section-copy">Runtime identifiers and workspace location.</p>
            </div>
          </div>

          <dl class="detail-list">
            <div>
              <dt>Workspace path</dt>
              <dd class="mono"><%= value_or_na(@payload.workspace.path) %></dd>
            </div>
            <div>
              <dt>Worker host</dt>
              <dd><%= value_or_na(@payload.workspace.host) %></dd>
            </div>
            <div>
              <dt>Session id</dt>
              <dd class="mono"><%= value_or_na(@payload.session.session_id) %></dd>
            </div>
            <div>
              <dt>Thread id</dt>
              <dd class="mono"><%= value_or_na(@payload.session.thread_id) %></dd>
            </div>
            <div>
              <dt>Model</dt>
              <dd><%= value_or_na(@payload.session.model) %></dd>
            </div>
            <div>
              <dt>Dispatched</dt>
              <dd class="mono"><%= value_or_na(@payload.session.dispatched_at) %></dd>
            </div>
          </dl>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Links</h2>
              <p class="section-copy">Raw diagnostics remain available beside the normal UI.</p>
            </div>
          </div>

          <div class="link-row">
            <a :if={@payload.links.github} class="subtle-link" href={@payload.links.github}>
              <%= @payload.links.github_label %>
            </a>
            <a class="subtle-link" href={@payload.links.api}>Raw JSON</a>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Event timeline</h2>
              <p class="section-copy">Chronological stream from currently persisted runtime state.</p>
            </div>
          </div>

          <%= if @payload.timeline == [] do %>
            <p class="empty-state">No events recorded yet.</p>
          <% else %>
            <ol class="timeline-list">
              <li :for={event <- @payload.timeline}>
                <span class="timeline-time mono numeric"><%= event.at %></span>
                <span class="timeline-event"><%= event.event %></span>
                <span class="timeline-message"><%= value_or_na(event.message) %></span>
              </li>
            </ol>
          <% end %>

          <div class="timeline-note">
            <p><%= @payload.timeline_gap.current_projection %></p>
            <p><%= @payload.timeline_gap.next_persistence_step %></p>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Attempt history</h2>
              <p class="section-copy">Recent completed sessions for this issue.</p>
            </div>
          </div>

          <%= if @payload.completed == [] do %>
            <p class="empty-state">No completed attempts for this issue.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Attempt</th>
                    <th>Thread</th>
                    <th>Completed</th>
                    <th>Duration</th>
                    <th>Model</th>
                    <th>Tokens</th>
                    <th>Stop reason</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.completed}>
                    <td class="numeric"><%= entry.attempt %></td>
                    <td class="mono"><%= value_or_na(entry.thread_id) %></td>
                    <td class="mono"><%= value_or_na(entry.completed_at) %></td>
                    <td class="numeric"><%= format_duration_ms(entry.duration_ms) %></td>
                    <td><%= value_or_na(entry.model) %></td>
                    <td class="numeric"><%= format_int(entry.tokens.total_tokens) %></td>
                    <td><%= value_or_na(entry.stop_reason) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Recent Codex events</h2>
              <p class="section-copy">Latest event retained for the active session.</p>
            </div>
          </div>

          <%= if @payload.recent_events == [] do %>
            <p class="empty-state">No active Codex event retained.</p>
          <% else %>
            <pre class="code-panel"><%= pretty_value(@payload.recent_events) %></pre>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp issue_identifier_from_params(%{"issue" => issue}) when is_binary(issue), do: issue
  defp issue_identifier_from_params(%{"issue_identifier" => issue}) when is_binary(issue), do: issue
  defp issue_identifier_from_params(_params), do: nil

  defp load_payload(nil), do: %{error: %{code: "issue_required", message: "Issue identifier required"}}

  defp load_payload(issue_identifier) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> payload
      {:error, :issue_not_found} -> %{error: %{code: "issue_not_found", message: "Issue not found"}}
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp value_or_na(nil), do: "n/a"
  defp value_or_na(""), do: "n/a"
  defp value_or_na(value), do: value

  defp format_duration_ms(ms) when is_integer(ms) do
    total_seconds = div(ms, 1_000)
    mins = div(total_seconds, 60)
    secs = rem(total_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_duration_ms(_ms), do: "n/a"

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
