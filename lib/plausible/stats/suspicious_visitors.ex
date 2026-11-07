defmodule Plausible.Stats.SuspiciousVisitors do
  @moduledoc """
  Lists the individual sessions that were classified as suspicious or bot
  traffic (see `Plausible.Ingestion.Traffic`), with the reasons why.

  Dashboard filters are not applied, only the site, the time range and the
  traffic class.
  """

  use Plausible.ClickhouseRepo
  import Ecto.Query

  alias Plausible.Stats.{Query, SQL.WhereBuilder}

  @default_limit 100

  @spec list(Plausible.Site.t(), Query.t(), keyword()) :: %{
          visits: [map()],
          reasons: [%{reason: String.t(), visits: non_neg_integer()}],
          total: non_neg_integer()
        }
  def list(site, %Query{} = query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    query =
      query
      |> Query.set(filters: [])
      |> Query.set(traffic: nonhuman_class(query.traffic))

    sessions = sessions_query(site, query)

    visits =
      from(s in subquery(sessions),
        order_by: [desc: s.start],
        limit: ^limit
      )
      |> ClickhouseRepo.all()
      |> Enum.map(&format_visit(&1, site.timezone))

    {total, reasons} = reason_counts(sessions)

    %{visits: visits, reasons: reasons, total: total}
  end

  defp nonhuman_class(class) when class in [:suspicious, :bot], do: class
  defp nonhuman_class(_), do: :nonhuman

  defp sessions_query(site, query) do
    from(s in "sessions_v2",
      where: ^WhereBuilder.build(:sessions, site, query),
      group_by: s.session_id,
      having: fragment("sum(?) > 0", s.sign),
      select: %{
        session_id: s.session_id,
        start: fragment("min(?)", s.start),
        traffic: fragment("argMax(?, ?)", s.traffic, s.timestamp),
        reasons: fragment("argMax(?, ?)", s.traffic_reasons, s.timestamp),
        interacted: fragment("max(?)", s.interacted),
        pageviews: fragment("argMax(?, ?)", s.pageviews, s.timestamp),
        duration: fragment("argMax(?, ?)", s.duration, s.timestamp),
        entry_page: fragment("argMax(?, ?)", s.entry_page, s.timestamp),
        exit_page: fragment("argMax(?, ?)", s.exit_page, s.timestamp),
        country: fragment("argMax(?, ?)", s.country_code, s.timestamp),
        browser: fragment("argMax(?, ?)", s.browser, s.timestamp),
        operating_system: fragment("argMax(?, ?)", s.operating_system, s.timestamp),
        device: fragment("argMax(?, ?)", s.screen_size, s.timestamp),
        source: fragment("argMax(?, ?)", s.referrer_source, s.timestamp)
      }
    )
  end

  defp reason_counts(sessions) do
    total = ClickhouseRepo.one(from(s in subquery(sessions), select: count()))

    reasons_per_visit =
      from(s in subquery(sessions), select: %{reason: fragment("arrayJoin(?)", s.reasons)})

    reasons =
      from(r in subquery(reasons_per_visit),
        group_by: r.reason,
        select: %{reason: r.reason, visits: count()},
        order_by: [desc: count(), asc: r.reason]
      )
      |> ClickhouseRepo.all()

    {total, reasons}
  end

  defp format_visit(row, timezone) do
    start =
      row.start
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.shift_zone!(timezone)
      |> DateTime.to_naive()
      |> NaiveDateTime.to_iso8601()

    %{
      start: start,
      class: class_name(row.traffic),
      reasons: row.reasons,
      interacted: row.interacted == 1,
      pageviews: row.pageviews,
      duration: row.duration,
      entry_page: row.entry_page,
      exit_page: row.exit_page,
      country: blank_to_nil(row.country),
      browser: blank_to_nil(row.browser),
      operating_system: blank_to_nil(row.operating_system),
      device: blank_to_nil(row.device),
      source: blank_to_nil(row.source)
    }
  end

  defp class_name(2), do: "bot"
  defp class_name(_), do: "suspicious"

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(<<0, 0>>), do: nil
  defp blank_to_nil(value), do: value
end
