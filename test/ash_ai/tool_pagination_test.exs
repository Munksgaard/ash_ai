# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.ToolPaginationTest do
  use ExUnit.Case, async: true

  alias __MODULE__.{Domain, Record}

  defmodule Record do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private? true
    end

    multitenancy do
      strategy :attribute
      attribute :tenant_id
    end

    attributes do
      uuid_primary_key :id
      attribute :position, :integer, public?: true
      attribute :owner_id, :integer
      attribute :tenant_id, :string
      attribute :private_notes, :string
      attribute :loaded_notes, :string
    end

    actions do
      defaults [:read, create: [:position, :owner_id, :private_notes, :loaded_notes]]

      read :small_pages do
        pagination offset?: true, countable: true, default_limit: 3, max_page_size: 5
      end

      read :prepared_limit do
        pagination offset?: true, countable: true
        prepare build(limit: 7)
      end

      read :with_input do
        argument :minimum, :integer, allow_nil?: false
        pagination offset?: true, countable: true
        filter expr(position >= ^arg(:minimum))
      end

      read :unpaginated

      read :uncountable do
        pagination offset?: true, countable: false
      end

      read :keyset_only do
        pagination keyset?: true, countable: true
      end

      read :single do
        get? true
        pagination offset?: true, countable: true
      end
    end

    policies do
      policy action_type(:create) do
        authorize_if always()
      end

      policy action_type(:read) do
        authorize_if expr(owner_id == ^actor(:id))
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, extensions: [AshAi]

    resources do
      resource Record
    end

    tools do
      tool :list_records, Record, :read do
        pagination?(true)
        description "List visible records."
        load [:loaded_notes]
      end

      tool :legacy_records, Record, :read, load: [:loaded_notes]
      tool :small_pages, Record, :small_pages, pagination?: true
      tool :prepared_limit, Record, :prepared_limit, pagination?: true
      tool :with_input, Record, :with_input, pagination?: true
    end
  end

  setup do
    actor = %{id: 1}
    context = %{actor: actor, tenant: "first"}

    for {tenant, owner, positions} <- [
          {"first", 1, 1..32},
          {"first", 2, 33..36},
          {"second", 1, 37..39}
        ],
        position <- positions do
      Record
      |> Ash.Changeset.for_create(
        :create,
        %{
          position: position,
          owner_id: owner,
          private_notes: "not exposed",
          loaded_notes: "explicitly loaded"
        },
        tenant: tenant,
        actor: actor
      )
      |> Ash.create!()
    end

    %{context: context}
  end

  test "default reads already support countable offset pagination" do
    action = Ash.Resource.Info.action(Record, :read)
    assert action.pagination.offset?
    assert action.pagination.countable
  end

  test "default page reports fetched and authorized tenant total, preserving raw records", %{
    context: context
  } do
    assert {:ok, json, raw} = execute(:list_records, %{}, context)
    result = Jason.decode!(json)

    assert %{
             "fetched_count" => 25,
             "total_count" => 32,
             "has_more" => true,
             "next_offset" => 25
           } = result

    assert Enum.map(result["results"], & &1["position"]) == Enum.to_list(1..25)
    assert Enum.map(raw, & &1.position) == Enum.to_list(1..25)
    assert Enum.all?(raw, &match?(%Record{}, &1))
    assert Enum.all?(result["results"], &(&1["loaded_notes"] == "explicitly loaded"))
    refute Enum.any?(result["results"], &Map.has_key?(&1, "private_notes"))
    refute Enum.any?(result["results"], &Map.has_key?(&1, "owner_id"))
  end

  test "next_offset reaches the last page without changing the total", %{context: context} do
    assert {:ok, first_json, _} = execute(:list_records, %{}, context)
    next_offset = Jason.decode!(first_json)["next_offset"]
    assert {:ok, json, _} = execute(:list_records, %{"offset" => next_offset}, context)

    assert %{
             "results" => records,
             "fetched_count" => 7,
             "total_count" => 32,
             "has_more" => false,
             "next_offset" => nil
           } = Jason.decode!(json)

    assert Enum.map(records, & &1["position"]) == Enum.to_list(26..32)
  end

  test "filters and sorting apply to the page and full count", %{context: context} do
    arguments = %{
      "filter" => %{"position" => %{"gte" => 26}},
      "sort" => [%{"field" => "position", "direction" => "desc"}],
      "limit" => 3,
      "offset" => 2
    }

    assert {:ok, json, _} = execute(:list_records, arguments, context)
    result = Jason.decode!(json)
    assert result["total_count"] == 7
    assert result["fetched_count"] == 3
    assert result["next_offset"] == 5
    assert result["has_more"]
    assert Enum.map(result["results"], & &1["position"]) == [30, 29, 28]
  end

  test "action arguments apply to the full count", %{context: context} do
    assert {:ok, json, _} =
             execute(:with_input, %{"input" => %{"minimum" => 30}, "limit" => 2}, context)

    assert %{"total_count" => 3, "fetched_count" => 2, "has_more" => true} =
             Jason.decode!(json)
  end

  test "empty matches report a zero total", %{context: context} do
    assert {:ok, json, []} =
             execute(:list_records, %{"filter" => %{"position" => %{"gt" => 100}}}, context)

    assert Jason.decode!(json) == %{
             "results" => [],
             "fetched_count" => 0,
             "total_count" => 0,
             "has_more" => false,
             "next_offset" => nil
           }
  end

  test "offset beyond the last page retains the full total", %{context: context} do
    assert {:ok, json, []} = execute(:list_records, %{"offset" => 100}, context)

    assert %{
             "results" => [],
             "fetched_count" => 0,
             "total_count" => 32,
             "has_more" => false,
             "next_offset" => nil
           } = Jason.decode!(json)
  end

  test "exactly full last page has no continuation", %{context: context} do
    assert {:ok, json, _} = execute(:list_records, %{"limit" => 16, "offset" => 16}, context)

    assert %{"fetched_count" => 16, "has_more" => false, "next_offset" => nil} =
             Jason.decode!(json)
  end

  test "respects configured default and maximum page sizes", %{context: context} do
    assert {:ok, default_json, _} = execute(:small_pages, %{}, context)
    assert %{"fetched_count" => 3, "total_count" => 32} = Jason.decode!(default_json)

    assert {:ok, max_json, _} = execute(:small_pages, %{"limit" => 100}, context)
    assert %{"fetched_count" => 5, "total_count" => 32} = Jason.decode!(max_json)
  end

  test "preserves intentional limits from action preparations", %{context: context} do
    assert {:ok, json, _} = execute(:prepared_limit, %{"limit" => 3}, context)
    assert %{"fetched_count" => 3, "total_count" => 7} = Jason.decode!(json)
  end

  test "without opt-in, JSON and raw results remain lists", %{context: context} do
    assert {:ok, json, raw} = execute(:legacy_records, %{}, context)
    assert is_list(Jason.decode!(json))
    assert length(Jason.decode!(json)) == 25
    assert length(raw) == 25
  end

  test "count and exists operations keep scalar results", %{context: context} do
    for {result_type, expected} <- [{"count", 32}, {"exists", true}] do
      assert {:ok, json, ^expected} =
               execute(:list_records, %{"result_type" => result_type}, context)

      assert Jason.decode!(json) == expected
    end
  end

  test "aggregate operations keep their existing result shape and behavior", %{context: context} do
    arguments = %{"result_type" => %{"aggregate" => "max", "field" => "position"}}
    assert {:ok, json, raw} = execute(:legacy_records, arguments, context)
    assert {:ok, ^json, ^raw} = execute(:list_records, arguments, context)
  end

  test "invalid page options return an error", %{context: context} do
    assert {:error, _} = execute(:list_records, %{"offset" => -1}, context)
    assert {:error, _} = execute(:list_records, %{"limit" => 0}, context)
  end

  test "nil arguments use the default page", %{context: context} do
    assert {:ok, json, _} = AshAi.Tools.execute(tool(:list_records), nil, context)
    assert %{"fetched_count" => 25, "total_count" => 32} = Jason.decode!(json)
  end

  test "tool description explains the envelope without changing the input schema" do
    paginated = AshAi.Tools.to_function(tool(:list_records))
    legacy = AshAi.Tools.to_function(tool(:legacy_records))

    assert paginated.description =~ "List visible records."
    assert paginated.description =~ "total_count"
    assert paginated.description =~ "offset set to next_offset"
    refute legacy.description =~ "next_offset"
    assert paginated.parameters_schema == legacy.parameters_schema
  end

  test "verifier rejects incompatible actions and hidden pagination parameters" do
    for action <- [:unpaginated, :uncountable, :keyset_only, :single, :create] do
      assert {:error, %Spark.Error.DslError{}} = verify(%{tool(:list_records) | action: action})
    end

    for parameters <- [[], [:limit], [:offset], [:input]] do
      assert {:error, %Spark.Error.DslError{}} =
               verify(%{tool(:list_records) | action: :read, action_parameters: parameters})
    end

    assert :ok = verify(%{tool(:list_records) | action: :read})
    assert :ok = verify(%{tool(:legacy_records) | action: :unpaginated})
  end

  defp execute(name, arguments, context) do
    arguments =
      Map.put_new(arguments, "sort", [%{"field" => "position", "direction" => "asc"}])

    AshAi.Tools.execute(tool(name), arguments, context)
  end

  defp tool(name) do
    tool = Enum.find(AshAi.Info.tools(Domain), &(&1.name == name))
    %{tool | domain: Domain, action: Ash.Resource.Info.action(Record, tool.action)}
  end

  defp verify(tool) do
    AshAi.Verifiers.ToolPagination.verify(%{
      [:tools] => %{entities: [tool]},
      :persist => %{module: Domain}
    })
  end
end
