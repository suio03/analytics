defmodule Plausible.Economics.Source do
  @moduledoc "A site's cost report endpoint (the app's own JSON) and its encrypted bearer token."
  use Ecto.Schema
  import Ecto.Changeset

  schema "economics_sources" do
    belongs_to(:site, Plausible.Site)
    field(:url, :string)
    field(:token, Plausible.Payments.Secret, redact: true)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:url, :token])
    |> update_change(:url, &(&1 && String.trim(&1)))
    |> validate_required([:url, :token])
    |> validate_length(:url, max: 500)
    |> validate_change(:url, fn :url, url ->
      case URI.parse(url) do
        %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
        _ -> [url: "must be an https:// URL"]
      end
    end)
    |> unique_constraint(:site_id)
  end
end

defmodule Plausible.Economics do
  @moduledoc """
  Free cost against sign-up revenue, read live from the site's own app (docs/economics.md).
  The app computes the report; this only stores where to fetch it and renders it.
  """
  import Ecto.Query
  alias Plausible.Repo
  alias Plausible.Economics.Source

  def source(site_id), do: Repo.one(from(s in Source, where: s.site_id == ^site_id))

  def save_source(site_id, attrs) do
    existing = source(site_id)
    # A blank token keeps the saved one, as with payment secrets.
    attrs =
      if existing,
        do: Map.reject(attrs, fn {k, v} -> k == "token" and v in [nil, ""] end),
        else: attrs

    (existing || %Source{site_id: site_id})
    |> Source.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "The report as decoded JSON, or `{:error, reason}`."
  def fetch(%Source{} = source, days \\ 56) do
    opts = Application.get_env(:plausible, __MODULE__, [])

    case Req.get(
           [
             url: source.url,
             headers: [{"authorization", "Bearer #{source.token}"}],
             params: [days: days],
             receive_timeout: 30_000,
             retry: false,
             redirect: false
           ] ++ opts
         ) do
      {:ok, %{status: 200, body: %{"daily" => d, "weeks" => w, "sources" => s} = body}}
      when is_list(d) and is_list(w) and is_list(s) ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, "The endpoint did not return a cost report."}

      {:ok, %{status: 403}} ->
        {:error, "The endpoint refused the token (403)."}

      {:ok, %{status: status}} ->
        {:error, "The endpoint answered HTTP #{status}."}

      {:error, _} ->
        {:error, "Could not reach the endpoint."}
    end
  end

  @doc "Totals over the latest `n` daily rows."
  def recent(daily, n \\ 7) do
    rows = Enum.take(daily, n)
    free = sum(rows, "freeUsd")
    revenue = sum(rows, "revenue")

    %{
      free: free,
      revenue: revenue,
      share: if(revenue > 0, do: free / revenue),
      signups: sum(rows, "signups")
    }
  end

  @doc "Payback over weekly cohorts that have had their full window."
  def mature_payback(weeks, cohort_days) do
    full = Enum.filter(weeks, &(&1["age"] >= cohort_days))
    free = sum(full, "freeUsd")
    if free > 0, do: sum(full, "revenue") / free
  end

  defp sum(rows, key), do: Enum.reduce(rows, 0, &((&1[key] || 0) + &2))
end
