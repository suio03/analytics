defmodule Plausible.Economics.Secret do
  @moduledoc "An encrypted credential; uses the application's existing managed vault."
  use Cloak.Ecto.Binary, vault: Plausible.Auth.TOTP.Vault
end

defmodule Plausible.Economics.Source do
  @moduledoc "A site's cost report endpoint (the app's own JSON) and its encrypted bearer token."
  use Ecto.Schema
  import Ecto.Changeset

  schema "economics_sources" do
    belongs_to(:site, Plausible.Site)
    field(:url, :string)
    field(:token, Plausible.Economics.Secret, redact: true)
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
  alias Plausible.Economics.{Report, Source}

  def source(site_id), do: Repo.one(from(s in Source, where: s.site_id == ^site_id))

  def save_source(site_id, attrs) do
    existing = source(site_id)
    # A blank token keeps the saved one.
    attrs =
      if existing,
        do: Map.reject(attrs, fn {k, v} -> k == "token" and v in [nil, ""] end),
        else: attrs

    (existing || %Source{site_id: site_id})
    |> Source.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  The report for the last `days` local days in `tz`, or `{:error, reason}`. Apps that export raw
  data (format 2) get `since` and their export is computed here; a format 1 app computes the report
  itself from `days` (UTC days) and it is shown as is.
  """
  def fetch(%Source{} = source, days \\ 28, tz \\ "Etc/UTC") do
    opts = Application.get_env(:plausible, __MODULE__, [])

    case Req.get(
           [
             url: source.url,
             headers: [{"authorization", "Bearer #{source.token}"}],
             params: [days: days, since: Report.since(tz, days), format: 2],
             receive_timeout: 30_000,
             retry: false,
             redirect: false
           ] ++ opts
         ) do
      {:ok, %{status: 200, body: %{} = body}} when is_map_key(body, "users") ->
        if Report.raw?(body),
          do: {:ok, Report.build(body, tz, days)},
          else: {:error, "The endpoint did not return a cost report."}

      {:ok, %{status: 200, body: %{"daily" => d, "weeks" => w, "sources" => s} = body}}
      when is_list(d) and is_list(w) and is_list(s) ->
        {:ok, Map.put_new(body, "timezone", "Etc/UTC")}

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

  @doc "Totals over the report's daily rows (the whole window)."
  def totals(rows) do
    free = sum(rows, "freeUsd")
    paid = sum(rows, "paidUsd")
    revenue = sum(rows, "revenue")

    %{
      free: free,
      paid: paid,
      revenue: revenue,
      profit: revenue - free - paid,
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

  @doc "Summary tiles for the paying users section."
  def payers_summary(payers) do
    count = length(payers)
    paid = sum(payers, "usd")

    %{
      count: count,
      new: Enum.count(payers, & &1["new"]),
      repeat: if(count > 0, do: Enum.count(payers, &(&1["orders"] >= 2)) / count),
      per_payer: if(count > 0, do: paid / count),
      margin: sum(payers, "margin"),
      credits_left: sum(payers, "creditsLeft")
    }
  end

  @doc """
  Splits source rows for display: sources with at least `min` sign-ups, the smaller ones folded
  into one "Other" row (nil when there are none) with the rows it folds, and the sign-ups from
  before source tracking, which go last because their payback means nothing.
  """
  def split_sources(rows, min \\ 5) do
    {before, tracked} = Enum.split_with(rows, &(&1["key"] == "(before tracking)"))
    {major, minor} = Enum.split_with(tracked, &((&1["signups"] || 0) >= min))

    other =
      if minor != [] do
        free = sum(minor, "freeUsd")
        signups = sum(minor, "signups")

        %{
          "count" => length(minor),
          "signups" => signups,
          "freeUsd" => free,
          "freePerSignup" => if(signups > 0, do: free / signups, else: 0),
          "revenue" => sum(minor, "revenue"),
          "buyers" => sum(minor, "buyers"),
          "payback" => if(free > 0, do: sum(minor, "revenue") / free)
        }
      end

    %{major: major, other: other, minor: minor, before: before}
  end

  defp sum(rows, key), do: Enum.reduce(rows, 0, &((&1[key] || 0) + &2))
end
