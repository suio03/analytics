defmodule Plausible.EventGoals do
  @moduledoc """
  Operations used by the self-hosted admin API to manage custom event goals.
  """

  alias Plausible.Goal
  alias Plausible.Goals
  alias Plausible.Repo

  @max_events 500

  @spec list(Plausible.Site.t()) :: [Goal.t()]
  def list(site) do
    site
    |> Goals.for_site(preload_funnels?: false)
    |> Enum.filter(&is_binary(&1.event_name))
    |> Enum.sort_by(& &1.event_name)
  end

  @spec add(Plausible.Site.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def add(site, event_names), do: sync(site, event_names, prune?: false)

  @spec sync(Plausible.Site.t(), [String.t()], Keyword.t()) ::
          {:ok, map()} | {:error, term()}
  def sync(site, event_names, opts \\ []) do
    with {:ok, event_names} <- normalize(event_names) do
      prune? = Keyword.get(opts, :prune?, false)

      Repo.transaction(fn ->
        existing_by_name = Map.new(list(site), &{&1.event_name, &1})
        created = create_missing_goals(site, event_names, existing_by_name)
        deleted = delete_missing_goals(site, event_names, existing_by_name, prune?)

        %{
          events: list(site),
          created: created |> Enum.map(& &1.event_name) |> Enum.sort(),
          deleted: deleted |> Enum.map(& &1.event_name) |> Enum.sort()
        }
      end)
    end
  end

  @spec delete(Plausible.Site.t(), pos_integer()) :: :ok | {:error, :not_found}
  def delete(site, goal_id) when is_integer(goal_id) do
    case Goals.get(site, goal_id) do
      %Goal{event_name: event_name} when is_binary(event_name) -> Goals.delete(goal_id, site)
      _ -> {:error, :not_found}
    end
  end

  defp delete_goal!(site, goal) do
    case Goals.delete(goal.id, site) do
      :ok -> goal
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp create_missing_goals(site, event_names, existing_by_name) do
    event_names
    |> Enum.reject(&Map.has_key?(existing_by_name, &1))
    |> Enum.map(&create_goal!(site, &1))
  end

  defp create_goal!(site, event_name) do
    case Goals.find_or_create(site, %{"goal_type" => "event", "event_name" => event_name}) do
      {:ok, goal} -> goal
      {:error, changeset} -> Repo.rollback({:invalid_event, changeset})
    end
  end

  defp delete_missing_goals(_site, _event_names, _existing_by_name, false), do: []

  defp delete_missing_goals(site, event_names, existing_by_name, true) do
    existing_by_name
    |> Map.drop(event_names)
    |> Map.values()
    |> Enum.map(&delete_goal!(site, &1))
  end

  defp normalize(event_names) when is_list(event_names) and length(event_names) <= @max_events do
    if Enum.all?(event_names, &is_binary/1) do
      names = event_names |> Enum.map(&String.trim/1) |> Enum.uniq()

      if Enum.any?(names, &(&1 == "")), do: {:error, :blank_event_name}, else: {:ok, names}
    else
      {:error, :invalid_events}
    end
  end

  defp normalize(event_names) when is_list(event_names), do: {:error, :too_many_events}
  defp normalize(_event_names), do: {:error, :invalid_events}
end
