defmodule SymphonyElixir.Github.AdapterTest do
  use SymphonyElixir.TestSupport

  # Must remain sync — tests share `Application.put_env(:symphony_elixir,
  # :github_client, ...)` and would race under `async: true`. The
  # `SymphonyElixir.TestSupport` macro defaults to sync (no `async: true`).
  # Do NOT flip to async without removing the shared Application env state.
  @moduletag :async_unsafe

  alias SymphonyElixir.Github.{Adapter, RateLimitGate}

  defmodule FakeClient do
    @moduledoc false
    def respond(payloads) do
      pid = self()

      fn query, vars, _opts ->
        send(pid, {:graphql, query, vars})
        lookup_response(payloads, query)
      end
    end

    defp lookup_response(payloads, query) do
      case Enum.find(payloads, fn {pat, _} -> String.contains?(query, pat) end) do
        {_pat, response} -> response
        nil -> {:error, {:github_unknown_payload, "no fake match"}}
      end
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Agent Ready", "In Progress", "Rework"],
      tracker_terminal_states: ["Done"],
      tracker_include_kinds: ["issue", "pull_request"]
    )

    payload = "test/fixtures/github/items_page.json" |> File.read!() |> Jason.decode!()
    project_resolved = {:ok, %{id: "PVT_kwDODDTPxM4BXSCK", title: "Symphony", number: 1}}

    status_probed =
      {:ok,
       %{
         id: "PVTSSF_x",
         name: "Status",
         options: [
           {"todo", "f75ad846"},
           {"agent ready", "5264dd8c"},
           {"in progress", "47fc9ee4"},
           {"in review", "593a70e3"},
           {"rework", "a3ea437a"},
           {"blocked", "9bb46c25"},
           {"done", "98236657"}
         ]
       }}

    fake =
      FakeClient.respond([
        {"SymphonyResolveProjectByOrg", project_resolved |> wrap_resolve()},
        {"SymphonyStatusFieldProbe", status_probed |> wrap_probe()},
        {"SymphonyProjectItems", {:ok, payload}}
      ])

    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)
    Adapter.invalidate_cache()
    RateLimitGate.clear()

    :ok
  end

  defp wrap_resolve({:ok, p}),
    do:
      {:ok,
       %{
         "data" => %{
           "organization" => %{"projectV2" => %{"id" => p.id, "title" => p.title, "number" => p.number}}
         }
       }}

  defp wrap_probe({:ok, p}),
    do:
      {:ok,
       %{
         "data" => %{
           "node" => %{
             "field" => %{
               "__typename" => "ProjectV2SingleSelectField",
               "id" => p.id,
               "name" => p.name,
               "options" => Enum.map(p.options, fn {n, id} -> %{"id" => id, "name" => String.capitalize(n)} end)
             }
           }
         }
       }}

  test "fetch_candidate_issues filters terminal-OR (merged PR), archived, REDACTED, <no status>" do
    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    ids = Enum.map(issues, & &1.id)

    assert "PVTI_iss1" in ids
    refute "PVTI_pr_merged" in ids
    refute "PVTI_archived" in ids
    refute "PVTI_redacted" in ids
    refute "PVTI_no_status" in ids
    refute "PVTI_draft1" in ids
  end

  test "workflow reload re-resolves the project (cache invalidation)" do
    resolve_calls = :counters.new(1, [:atomics])

    fake = fn query, vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          :counters.add(resolve_calls, 1, 1)
          number = vars["number"]

          {:ok,
           %{
             "data" => %{
               "organization" => %{
                 "projectV2" => %{"id" => "PVT_#{number}", "title" => "x", "number" => number}
               }
             }
           }}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "field" => %{
                   "__typename" => "ProjectV2SingleSelectField",
                   "id" => "PVTSSF_x",
                   "name" => "Status",
                   "options" => []
                 }
               }
             }
           }}

        true ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "id" => "x",
                 "title" => "x",
                 "number" => 1,
                 "items" => %{"pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}, "nodes" => []}
               }
             }
           }}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client) end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_number: 1)
    Adapter.invalidate_cache()
    {:ok, _} = Adapter.fetch_candidate_issues()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_number: 2)
    {:ok, _} = Adapter.fetch_candidate_issues()

    assert :counters.get(resolve_calls, 1) == 2
  end

  # ------------------------------------------------------------------
  # Coverage gates
  # ------------------------------------------------------------------

  test "fetch_issues_by_states([]) short-circuits without calling client" do
    Application.put_env(:symphony_elixir, :github_client, fn _, _, _ ->
      flunk("client must not be called for empty list")
    end)

    assert {:ok, []} = Adapter.fetch_issues_by_states([])
  end

  test "fetch_issue_states_by_ids([]) short-circuits without calling client" do
    Application.put_env(:symphony_elixir, :github_client, fn _, _, _ ->
      flunk("client must not be called for empty list")
    end)

    assert {:ok, []} = Adapter.fetch_issue_states_by_ids([])
  end

  test "fetch_issues_by_states/1 returns issues whose Project Status matches" do
    assert {:ok, issues} = Adapter.fetch_issues_by_states(["In Progress"])
    ids = Enum.map(issues, & &1.id)
    assert "PVTI_pr_merged" in ids
  end

  test "fetch_issue_states_by_ids/1 normalizes Issue/PR/Draft + skips REDACTED/archived" do
    refresh_payload = %{
      "data" => %{
        "rateLimit" => %{"remaining" => 4_000, "resetAt" => "2026-05-10T13:00:00Z"},
        "nodes" => [
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_iss1",
            "type" => "ISSUE",
            "isArchived" => false,
            "fieldValueByName" => %{"name" => "Agent Ready"},
            "content" => %{
              "__typename" => "Issue",
              "number" => 42,
              "state" => "OPEN",
              "repository" => %{"nameWithOwner" => "archelab/symphony"},
              "trackedIssues" => %{
                "nodes" => [
                  %{
                    "id" => "I_blocker1",
                    "number" => 11,
                    "state" => "OPEN",
                    "repository" => %{"nameWithOwner" => "archelab/symphony"}
                  },
                  %{
                    "id" => "I_blocker2",
                    "number" => 12,
                    "state" => "CLOSED",
                    "repository" => %{"nameWithOwner" => "archelab/symphony"}
                  }
                ]
              }
            }
          },
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_iss_closed",
            "type" => "ISSUE",
            "isArchived" => false,
            "fieldValueByName" => %{"name" => "Agent Ready"},
            "content" => %{
              "__typename" => "Issue",
              "number" => 99,
              "state" => "CLOSED",
              "repository" => %{"nameWithOwner" => "archelab/symphony"},
              "trackedIssues" => %{"nodes" => []}
            }
          },
          # Issue row with `trackedIssues` field absent altogether — exercises
          # the fallback to `[]` in `blocked_by_from_refresh/1`.
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_iss_no_tracked",
            "type" => "ISSUE",
            "isArchived" => false,
            "fieldValueByName" => %{"name" => "Agent Ready"},
            "content" => %{
              "__typename" => "Issue",
              "number" => 77,
              "state" => "OPEN",
              "repository" => %{"nameWithOwner" => "archelab/symphony"}
            }
          },
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_pr_open",
            "type" => "PULL_REQUEST",
            "isArchived" => false,
            "fieldValueByName" => %{"name" => "In Progress"},
            "content" => %{
              "__typename" => "PullRequest",
              "number" => 5,
              "state" => "OPEN",
              "merged" => false,
              "repository" => %{"nameWithOwner" => "archelab/symphony"}
            }
          },
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_pr_merged",
            "type" => "PULL_REQUEST",
            "isArchived" => false,
            "fieldValueByName" => %{"name" => "In Progress"},
            "content" => %{
              "__typename" => "PullRequest",
              "number" => 3,
              "state" => "MERGED",
              "merged" => true,
              "repository" => %{"nameWithOwner" => "archelab/symphony"}
            }
          },
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_draft",
            "type" => "DRAFT_ISSUE",
            "isArchived" => false,
            "fieldValueByName" => nil,
            "content" => %{"__typename" => "DraftIssue", "id" => "DI_AAAAbbbb1234ZZZZ"}
          },
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_archived",
            "type" => "ISSUE",
            "isArchived" => true,
            "content" => nil
          },
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_redacted",
            "type" => "REDACTED",
            "isArchived" => false,
            "content" => nil
          },
          # Unknown content shape — must be filtered out by the
          # __typename allowlist guard (no `unknown:<id>` phantom result).
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_unknown",
            "type" => "ISSUE",
            "isArchived" => false,
            "fieldValueByName" => %{"name" => "Agent Ready"},
            "content" => %{"__typename" => "OtherShape"}
          },
          # Missing content entirely — same allowlist guard kicks in.
          %{
            "__typename" => "ProjectV2Item",
            "id" => "PVTI_no_content",
            "type" => "ISSUE",
            "isArchived" => false,
            "fieldValueByName" => %{"name" => "Agent Ready"},
            "content" => nil
          },
          # Random non-map and non-ProjectV2Item — exercise filter clauses.
          nil,
          %{"__typename" => "Other"}
        ]
      }
    }

    fake = fn _query, _vars, _opts -> {:ok, refresh_payload} end
    Application.put_env(:symphony_elixir, :github_client, fake)

    assert {:ok, results} = Adapter.fetch_issue_states_by_ids(["x"])
    by_id = Map.new(results, &{&1.id, &1})

    assert by_id["PVTI_iss1"].state == "Agent Ready"
    assert by_id["PVTI_iss1"].identifier == "archelab/symphony#42"
    assert by_id["PVTI_iss_closed"].state == "<closed>"
    assert by_id["PVTI_pr_open"].state == "In Progress"
    assert by_id["PVTI_pr_merged"].state == "<merged>"
    assert by_id["PVTI_draft"].state == "<no status>"
    assert String.starts_with?(by_id["PVTI_draft"].identifier, "draft:")
    refute Map.has_key?(by_id, "PVTI_unknown")
    refute Map.has_key?(by_id, "PVTI_no_content")
    refute Map.has_key?(by_id, "PVTI_archived")
    refute Map.has_key?(by_id, "PVTI_redacted")

    # SPEC §8.5 Part C — refresh-result `blocked_by` must mirror the live
    # trackedIssues set so the running-worker reconcile can detect a CLOSED→
    # OPEN transition on a dependency.
    assert by_id["PVTI_iss1"].blocked_by == [
             %{id: "I_blocker1", identifier: "archelab/symphony#11", state: "OPEN"},
             %{id: "I_blocker2", identifier: "archelab/symphony#12", state: "CLOSED"}
           ]

    # Empty trackedIssues → empty list (Issue with no dependencies).
    assert by_id["PVTI_iss_closed"].blocked_by == []

    # Issue row with the trackedIssues field absent altogether also yields [].
    assert by_id["PVTI_iss_no_tracked"].blocked_by == []

    # Non-Issue rows (PR, Draft) carry an empty `blocked_by` list — the
    # refresh-side reconcile only fires `:dependencies_reopened` on Issues,
    # but the field is always present so downstream code can pattern-match it.
    assert by_id["PVTI_pr_open"].blocked_by == []
    assert by_id["PVTI_pr_merged"].blocked_by == []
    assert by_id["PVTI_draft"].blocked_by == []
  end

  test "fetch_issue_states_by_ids/1 propagates client errors" do
    fake = fn _q, _v, _o -> {:error, {:github_api_request, :timeout}} end
    Application.put_env(:symphony_elixir, :github_client, fake)

    assert {:error, {:github_api_request, :timeout}} = Adapter.fetch_issue_states_by_ids(["x"])
  end

  test "paginate_items handles multi-page responses" do
    page2 = %{
      "data" => %{
        "node" => %{
          "items" => %{
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
            "nodes" => []
          }
        }
      }
    }

    page1 = %{
      "data" => %{
        "node" => %{
          "items" => %{
            "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-2"},
            "nodes" => [
              %{
                "id" => "PVTI_p1",
                "type" => "ISSUE",
                "isArchived" => false,
                "fieldValueByName" => %{"name" => "Agent Ready"},
                "content" => %{
                  "__typename" => "Issue",
                  "id" => "I_p1",
                  "number" => 1,
                  "title" => "x",
                  "state" => "OPEN",
                  "url" => "u",
                  "repository" => %{
                    "nameWithOwner" => "archelab/symphony",
                    "owner" => %{"login" => "archelab"},
                    "name" => "symphony",
                    "defaultBranchRef" => %{"name" => "main"}
                  },
                  "labels" => %{"nodes" => []},
                  "trackedIssues" => %{"nodes" => []}
                }
              }
            ]
          }
        }
      }
    }

    fake = fn query, vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          {:ok,
           %{
             "data" => %{
               "organization" => %{"projectV2" => %{"id" => "PVT_x", "title" => "x", "number" => 1}}
             }
           }}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "field" => %{
                   "__typename" => "ProjectV2SingleSelectField",
                   "id" => "f",
                   "name" => "Status",
                   "options" => []
                 }
               }
             }
           }}

        vars["after"] == nil ->
          {:ok, page1}

        true ->
          {:ok, page2}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    Adapter.invalidate_cache()

    assert {:ok, [issue]} = Adapter.fetch_candidate_issues()
    assert issue.id == "PVTI_p1"
  end

  test "paginate_items malformed payload returns :github_unknown_payload" do
    fake = fn query, _vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          {:ok,
           %{
             "data" => %{
               "organization" => %{"projectV2" => %{"id" => "PVT_x", "title" => "x", "number" => 1}}
             }
           }}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "field" => %{
                   "__typename" => "ProjectV2SingleSelectField",
                   "id" => "f",
                   "name" => "Status",
                   "options" => []
                 }
               }
             }
           }}

        true ->
          {:ok, %{"data" => %{"unexpected" => true}}}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    Adapter.invalidate_cache()

    assert {:error, {:github_unknown_payload, "candidate items"}} = Adapter.fetch_candidate_issues()
  end

  test "paginate_items propagates client errors" do
    fake = fn query, _vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          {:ok,
           %{
             "data" => %{
               "organization" => %{"projectV2" => %{"id" => "PVT_x", "title" => "x", "number" => 1}}
             }
           }}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "field" => %{
                   "__typename" => "ProjectV2SingleSelectField",
                   "id" => "f",
                   "name" => "Status",
                   "options" => []
                 }
               }
             }
           }}

        true ->
          {:error, {:github_api_request, :boom}}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    Adapter.invalidate_cache()

    assert {:error, {:github_api_request, :boom}} = Adapter.fetch_candidate_issues()
  end

  test "paginate_items detects hasNextPage:true with nil endCursor" do
    fake = fn query, _vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          {:ok,
           %{
             "data" => %{
               "organization" => %{"projectV2" => %{"id" => "PVT_x", "title" => "x", "number" => 1}}
             }
           }}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "field" => %{
                   "__typename" => "ProjectV2SingleSelectField",
                   "id" => "f",
                   "name" => "Status",
                   "options" => []
                 }
               }
             }
           }}

        true ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "items" => %{"pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}, "nodes" => []}
               }
             }
           }}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    Adapter.invalidate_cache()

    assert {:error, {:github_missing_end_cursor, %{}}} = Adapter.fetch_candidate_issues()
  end

  test "keep_repo? cross-owner long form keeps matching, drops mismatch" do
    # Long form via tracker.repo == "archelab/symphony" — already matches the
    # fixture issue. Switch to "otherorg/symphony" to drive the mismatch path.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_repo: "otherorg/symphony",
      tracker_active_states: ["Agent Ready", "In Progress"],
      tracker_terminal_states: ["Done"]
    )

    Adapter.invalidate_cache()
    assert {:ok, []} = Adapter.fetch_candidate_issues()
  end

  test "keep_repo? long-form match still keeps matching items" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_repo: "archelab/symphony",
      tracker_active_states: ["Agent Ready", "In Progress"],
      tracker_terminal_states: ["Done"]
    )

    Adapter.invalidate_cache()
    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    assert Enum.any?(issues, &(&1.id == "PVTI_iss1"))
  end

  test "active? draft_issue branch dispatches drafts when included" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_include_kinds: ["draft_issue"],
      tracker_active_states: ["Agent Ready"],
      tracker_terminal_states: ["Done"]
    )

    Adapter.invalidate_cache()
    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    assert Enum.any?(issues, &(&1.kind == "draft_issue"))
  end

  test "active? terminal_state branch drops issue" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Agent Ready"],
      tracker_terminal_states: ["Agent Ready"]
    )

    Adapter.invalidate_cache()
    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    refute Enum.any?(issues, &(&1.id == "PVTI_iss1"))
  end

  test "active? falls through to false when state matches neither active nor terminal" do
    # PVTI_iss1's state is "Agent Ready"; if neither list contains it AND it's
    # OPEN, the cond falls through to the catch-all `true -> false` clause.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Triage"],
      tracker_terminal_states: ["Done"]
    )

    Adapter.invalidate_cache()
    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    refute Enum.any?(issues, &(&1.id == "PVTI_iss1"))
  end

  test "keep_repo? with empty/nil repo filter returns true" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_repo: "",
      tracker_active_states: ["Agent Ready", "In Progress"],
      tracker_terminal_states: ["Done"]
    )

    Adapter.invalidate_cache()
    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    assert Enum.any?(issues, &(&1.id == "PVTI_iss1"))
  end

  test "keep_repo? with nil repository on the issue drops it" do
    # Drive a synthetic issue page where the issue lacks a repository payload.
    payload = %{
      "data" => %{
        "node" => %{
          "items" => %{
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
            "nodes" => [
              %{
                "id" => "PVTI_no_repo",
                "type" => "ISSUE",
                "isArchived" => false,
                "fieldValueByName" => %{"name" => "Agent Ready"},
                "content" => %{
                  "__typename" => "Issue",
                  "id" => "I_nr",
                  "number" => 99,
                  "title" => "x",
                  "state" => "OPEN",
                  "url" => nil,
                  "repository" => nil,
                  "labels" => %{"nodes" => []},
                  "trackedIssues" => %{"nodes" => []}
                }
              }
            ]
          }
        }
      }
    }

    fake = fn query, _vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          {:ok,
           %{
             "data" => %{
               "organization" => %{"projectV2" => %{"id" => "PVT_x", "title" => "x", "number" => 1}}
             }
           }}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "field" => %{
                   "__typename" => "ProjectV2SingleSelectField",
                   "id" => "f",
                   "name" => "Status",
                   "options" => []
                 }
               }
             }
           }}

        true ->
          {:ok, payload}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_repo: "symphony",
      tracker_active_states: ["Agent Ready"],
      tracker_terminal_states: ["Done"]
    )

    Adapter.invalidate_cache()
    assert {:ok, []} = Adapter.fetch_candidate_issues()
  end

  test "graphql/3 short-circuits when RateLimitGate is gated" do
    RateLimitGate.record_secondary(60)

    Application.put_env(:symphony_elixir, :github_client, fn _, _, _ ->
      flunk("must not call client when gated")
    end)

    Adapter.invalidate_cache()
    assert {:error, {:github_rate_limited, %{retry_after_seconds: n}}} = Adapter.fetch_candidate_issues()
    assert is_integer(n) and n >= 1
  end

  test "graphql/3 records :github_rate_limited from response" do
    fake = fn _q, _v, _o ->
      {:error, {:github_rate_limited, %{retry_after_seconds: 45}}}
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    Adapter.invalidate_cache()
    RateLimitGate.clear()

    assert {:error, {:github_rate_limited, %{retry_after_seconds: 45}}} = Adapter.fetch_candidate_issues()
    assert {:gated, _} = RateLimitGate.gated?()
  end

  test "graphql/3 records primary rate limit when remaining: 0" do
    future = DateTime.utc_now() |> DateTime.add(30, :second) |> DateTime.to_iso8601()

    fake = fn query, _vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          {:ok,
           %{
             "data" => %{
               "organization" => %{"projectV2" => %{"id" => "PVT_x", "title" => "x", "number" => 1}}
             }
           }}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "field" => %{
                   "__typename" => "ProjectV2SingleSelectField",
                   "id" => "f",
                   "name" => "Status",
                   "options" => []
                 }
               }
             }
           }}

        true ->
          {:ok,
           %{
             "data" => %{
               "rateLimit" => %{"remaining" => 0, "resetAt" => future},
               "node" => %{
                 "items" => %{"pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}, "nodes" => []}
               }
             }
           }}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    Adapter.invalidate_cache()
    RateLimitGate.clear()

    {:ok, []} = Adapter.fetch_candidate_issues()
    assert {:gated, _} = RateLimitGate.gated?()
  end

  test "ensure_resolved cache HIT path skips re-resolution on second call" do
    resolve_calls = :counters.new(1, [:atomics])

    fake = fn query, _vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          :counters.add(resolve_calls, 1, 1)

          {:ok,
           %{
             "data" => %{
               "organization" => %{"projectV2" => %{"id" => "PVT_x", "title" => "x", "number" => 1}}
             }
           }}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "field" => %{
                   "__typename" => "ProjectV2SingleSelectField",
                   "id" => "f",
                   "name" => "Status",
                   "options" => []
                 }
               }
             }
           }}

        true ->
          {:ok,
           %{
             "data" => %{
               "node" => %{
                 "items" => %{"pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}, "nodes" => []}
               }
             }
           }}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    Adapter.invalidate_cache()

    {:ok, _} = Adapter.fetch_candidate_issues()
    {:ok, _} = Adapter.fetch_candidate_issues()
    assert :counters.get(resolve_calls, 1) == 1
  end

  test "ensure_resolved propagates ProjectResolver errors" do
    fake = fn query, _vars, _opts ->
      if query =~ "SymphonyResolveProjectByOrg" do
        {:error, {:github_api_request, :down}}
      else
        {:error, {:github_unknown_payload, "x"}}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    Adapter.invalidate_cache()

    assert {:error, {:github_api_request, :down}} = Adapter.fetch_candidate_issues()
  end

  test "ensure_resolved propagates probe_status_field errors" do
    fake = fn query, _vars, _opts ->
      cond do
        query =~ "SymphonyResolveProjectByOrg" ->
          {:ok,
           %{
             "data" => %{
               "organization" => %{"projectV2" => %{"id" => "PVT_x", "title" => "x", "number" => 1}}
             }
           }}

        query =~ "SymphonyStatusFieldProbe" ->
          {:ok, %{"data" => %{"node" => %{"field" => nil}}}}

        true ->
          {:ok, %{}}
      end
    end

    Application.put_env(:symphony_elixir, :github_client, fake)
    Adapter.invalidate_cache()

    assert {:error, {:tracker_status_field_missing, _}} = Adapter.fetch_candidate_issues()
  end
end
