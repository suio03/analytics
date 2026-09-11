defmodule PlausibleWeb.Api.AdminEventsController do
  use PlausibleWeb, :controller
  use Plausible.Repo

  alias Plausible.EventGoals
  alias Plausible.Sites
  alias PlausibleWeb.Api.Helpers, as: H

  def sites(conn, _params) do
    sites =
      conn.assigns.current_user
      |> Sites.for_user_query()
      |> Repo.all()
      |> Enum.map(&%{domain: &1.domain, timezone: &1.timezone})
      |> Enum.sort_by(& &1.domain)

    json(conn, %{sites: sites})
  end

  def properties(conn, params) do
    case get_site(conn, params) do
      {:ok, site} ->
        result = %{site_id: site.domain, properties: site.allowed_event_props || []}

        result =
          if params["discover"] == "true",
            do: Map.put(result, :discovered, Plausible.Props.suggest_keys_to_allow(site)),
            else: result

        json(conn, result)

      error ->
        respond_error(conn, error)
    end
  end

  def add_properties(conn, params) do
    with {:ok, site} <- get_site(conn, params),
         {:ok, properties} <- fetch_properties(params),
         {:ok, result} <-
           Repo.transaction(fn ->
             # Serialize additive updates so concurrent clients preserve each other's properties.
             site =
               Repo.one!(from s in Plausible.Site, where: s.id == ^site.id, lock: "FOR UPDATE")

             previous = site.allowed_event_props || []

             case Plausible.Props.allow(site, properties) do
               {:ok, updated} ->
                 %{
                   site_id: updated.domain,
                   properties: updated.allowed_event_props,
                   added: updated.allowed_event_props -- previous
                 }

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           end) do
      json(conn, result)
    else
      error -> respond_error(conn, error)
    end
  end

  defp fetch_properties(%{"properties" => properties}) when is_list(properties) do
    if length(properties) <= Plausible.Props.max_props() and
         Enum.all?(properties, &is_binary/1),
       do: {:ok, properties},
       else: {:error, :invalid_properties}
  end

  defp fetch_properties(_params), do: {:error, :invalid_properties}

  def index(conn, params) do
    case get_site(conn, params) do
      {:ok, site} ->
        json(conn, %{
          site_id: site.domain,
          events: Enum.map(EventGoals.list(site), &serialize/1)
        })

      error ->
        respond_error(conn, error)
    end
  end

  def create(conn, params) do
    with {:ok, site} <- get_site(conn, params),
         {:ok, events} <- fetch_events(params),
         {:ok, result} <- EventGoals.add(site, events) do
      json(conn, serialize_result(site, result))
    else
      error -> respond_error(conn, error)
    end
  end

  def sync(conn, params) do
    with {:ok, site} <- get_site(conn, params),
         {:ok, events} <- fetch_events(params),
         {:ok, prune?} <- fetch_prune(params),
         {:ok, result} <- EventGoals.sync(site, events, prune?: prune?) do
      json(conn, serialize_result(site, result))
    else
      error -> respond_error(conn, error)
    end
  end

  def delete(conn, %{"goal_id" => goal_id} = params) do
    with {:ok, site} <- get_site(conn, params),
         {goal_id, ""} <- Integer.parse(goal_id),
         :ok <- EventGoals.delete(site, goal_id) do
      json(conn, %{deleted: true})
    else
      :error ->
        H.bad_request(conn, "goal_id must be an integer")

      {parsed_id, _remainder} when is_integer(parsed_id) ->
        H.bad_request(conn, "goal_id must be an integer")

      error ->
        respond_error(conn, error)
    end
  end

  defp get_site(conn, %{"site_id" => site_id}) when is_binary(site_id) do
    case Sites.get_for_user(conn.assigns.current_user, site_id, [:owner, :admin]) do
      nil -> {:error, :site_not_found}
      site -> {:ok, site}
    end
  end

  defp get_site(_conn, _params), do: {:error, :missing_site_id}

  defp fetch_events(%{"events" => events}) when is_list(events), do: {:ok, events}
  defp fetch_events(_params), do: {:error, :invalid_events}

  defp fetch_prune(%{"prune" => prune?}) when is_boolean(prune?), do: {:ok, prune?}
  defp fetch_prune(%{"prune" => _}), do: {:error, :invalid_prune}
  defp fetch_prune(_params), do: {:ok, false}

  defp respond_error(conn, {:error, :site_not_found}),
    do: H.not_found(conn, "Site could not be found or is not editable by this API key")

  defp respond_error(conn, {:error, :missing_site_id}),
    do: H.bad_request(conn, "Parameter `site_id` is required")

  defp respond_error(conn, {:error, :invalid_events}),
    do: H.bad_request(conn, "Parameter `events` must be a JSON array of event names")

  defp respond_error(conn, {:error, :blank_event_name}),
    do: H.bad_request(conn, "Event names cannot be blank")

  defp respond_error(conn, {:error, :too_many_events}),
    do: H.bad_request(conn, "A request can contain at most 500 event names")

  defp respond_error(conn, {:error, :invalid_prune}),
    do: H.bad_request(conn, "Parameter `prune` must be true or false")

  defp respond_error(conn, {:error, {:invalid_event, changeset}}) do
    message =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
      |> Enum.map_join(", ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)

    H.bad_request(conn, message)
  end

  defp respond_error(conn, {:error, :invalid_properties}),
    do: H.bad_request(conn, "Parameter `properties` must be an array of at most 300 strings")

  defp respond_error(conn, {:error, :upgrade_required}),
    do:
      conn |> put_status(402) |> json(%{error: "Custom Properties is not available on this plan"})

  defp respond_error(conn, {:error, %Ecto.Changeset{}}),
    do:
      H.bad_request(
        conn,
        "Property names must be 1–300 characters; at most 300 properties per site"
      )

  defp respond_error(conn, {:error, :not_found}), do: H.not_found(conn, "Event goal not found")
  defp respond_error(conn, _error), do: H.bad_request(conn, "Unable to update event goals")

  defp serialize(goal), do: %{id: goal.id, event_name: goal.event_name}

  defp serialize_result(site, result) do
    %{
      site_id: site.domain,
      events: Enum.map(result.events, &serialize/1),
      created: result.created,
      deleted: result.deleted
    }
  end
end
