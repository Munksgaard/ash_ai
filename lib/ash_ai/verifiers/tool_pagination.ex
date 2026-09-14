# SPDX-FileCopyrightText: 2024 ash_ai contributors <https://github.com/ash-project/ash_ai/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshAi.Verifiers.ToolPagination do
  @moduledoc "Verifies that tools opting into pagination can return counted offset pages."
  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> AshAi.Info.tools()
    |> Enum.filter(& &1.pagination?)
    |> Enum.find(fn tool ->
      action = Ash.Resource.Info.action(tool.resource, tool.action)
      not supported_action?(action) or not exposes_pagination?(tool.action_parameters)
    end)
    |> case do
      nil ->
        :ok

      tool ->
        {:error,
         Spark.Error.DslError.exception(
           message:
             "pagination? requires a non-single-result read action with countable offset pagination " <>
               "and exposed :limit and :offset action parameters",
           path: [:tools, tool.name, :pagination?],
           module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module)
         )}
    end
  end

  defp supported_action?(%Ash.Resource.Actions.Read{
         get?: false,
         pagination: %Ash.Resource.Actions.Read.Pagination{offset?: true, countable: countable}
       })
       when countable in [true, :by_default],
       do: true

  defp supported_action?(_), do: false

  defp exposes_pagination?(nil), do: true
  defp exposes_pagination?(parameters), do: :limit in parameters and :offset in parameters
end
