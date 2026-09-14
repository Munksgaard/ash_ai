# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.ToolPaginationPostgresTest do
  use AshAi.RepoCase, async: true

  alias AshAi.Test.Music
  alias AshAi.Test.Music.ArtistManual

  test "Postgres counts all matches independently of the current page" do
    for position <- 1..34 do
      Ash.create!(ArtistManual, %{
        name: "Artist #{String.pad_leading(to_string(position), 2, "0")}",
        bio: if(position <= 32, do: "included", else: "excluded")
      })
    end

    tool = %AshAi.Tool{
      name: :paginated_artists,
      domain: Music,
      resource: ArtistManual,
      action: Ash.Resource.Info.action(ArtistManual, :read),
      pagination?: true,
      arguments: [],
      load: []
    }

    arguments = %{
      "filter" => %{"bio" => %{"eq" => "included"}},
      "sort" => [%{"field" => "name", "direction" => "asc"}]
    }

    assert {:ok, first_json, first_records} = AshAi.Tools.execute(tool, arguments, %{})

    assert %{
             "fetched_count" => 25,
             "total_count" => 32,
             "has_more" => true,
             "next_offset" => next_offset
           } = Jason.decode!(first_json)

    assert next_offset == 25
    assert length(first_records) == 25
    assert hd(first_records).name == "Artist 01"

    assert {:ok, last_json, last_records} =
             AshAi.Tools.execute(tool, Map.put(arguments, "offset", next_offset), %{})

    assert %{
             "fetched_count" => 7,
             "total_count" => 32,
             "has_more" => false,
             "next_offset" => nil
           } = Jason.decode!(last_json)

    assert Enum.map(last_records, & &1.name) == Enum.map(26..32, &"Artist #{&1}")

    assert {:ok, empty_json, []} =
             AshAi.Tools.execute(tool, Map.put(arguments, "offset", 100), %{})

    assert %{"fetched_count" => 0, "total_count" => 32, "has_more" => false} =
             Jason.decode!(empty_json)
  end
end
