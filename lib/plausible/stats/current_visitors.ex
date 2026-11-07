defmodule Plausible.Stats.CurrentVisitors do
  use Plausible.ClickhouseRepo
  use Plausible.Stats.SQL.Fragments

  @doc """
  Unique human visitors in the last 5 minutes (or `duration`).

  Suspicious and bot traffic is left out, see `Plausible.Ingestion.Traffic`.
  """
  @spec current_visitors(Plausible.Site.t(), Duration.duration()) :: non_neg_integer
  def current_visitors(site, duration \\ Duration.new!(minute: -5)) do
    ClickhouseRepo.one(
      from e in base_query(site, duration),
        where: e.traffic == 0,
        select: uniq(e.user_id)
    )
  end

  @doc "Like `current_visitors/2`, split into human, suspicious and bot visitors."
  @spec current_visitors_by_traffic(Plausible.Site.t(), Duration.duration()) :: %{
          human: non_neg_integer,
          suspicious: non_neg_integer,
          bot: non_neg_integer
        }
  def current_visitors_by_traffic(site, duration \\ Duration.new!(minute: -5)) do
    {human, suspicious, bot} =
      ClickhouseRepo.one(
        from e in base_query(site, duration),
          select: {
            fragment("uniqIf(?, ? = 0)", e.user_id, e.traffic),
            fragment("uniqIf(?, ? = 1)", e.user_id, e.traffic),
            fragment("uniqIf(?, ? = 2)", e.user_id, e.traffic)
          }
      )

    %{human: human, suspicious: suspicious, bot: bot}
  end

  defp base_query(site, duration) do
    first_datetime =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.shift(duration)
      |> NaiveDateTime.truncate(:second)

    from e in "events_v2",
      where: e.site_id == ^site.id,
      where: e.timestamp >= ^first_datetime
  end
end
