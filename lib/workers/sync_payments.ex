defmodule Plausible.Workers.SyncPayments do
  @moduledoc "Imports an atomic, serialized snapshot of one payment connection."
  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 60, keys: [:integration_id], states: [:available, :scheduled, :retryable]]

  import Ecto.Query
  alias Plausible.Repo
  alias Plausible.Payments.{Integration, Provider}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration_id" => id}}) do
    # Serialize snapshots across workers/nodes; failed imports roll back as a unit.
    result =
      Repo.transaction(
        fn ->
          case Repo.one(from(i in Integration, where: i.id == ^id, lock: "FOR UPDATE")) do
            nil ->
              :ok

            integration ->
              sync_integration(integration)
          end
        end,
        timeout: :timer.minutes(30)
      )

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        message = error_message(reason)
        Repo.update_all(from(i in Integration, where: i.id == ^id), set: [last_error: message])
        {:error, message}
    end
  end

  defp sync_integration(integration) do
    observed_at = DateTime.utc_now()

    case Provider.sync(integration, &Plausible.Payments.store(integration, &1, observed_at)) do
      :ok ->
        integration
        |> Ecto.Changeset.change(last_synced_at: DateTime.utc_now(), last_error: nil)
        |> Repo.update!()

        :ok

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp error_message({:http, status}) when status in [401, 403],
    do: "Access denied. Check the API key and read permissions."

  defp error_message({:http, 429}),
    do: "Provider rate limit reached. Sync will retry automatically."

  defp error_message({:http, status}), do: "Provider returned HTTP #{status}. Sync will retry."

  defp error_message(:environment_mismatch),
    do: "The provider returned records from a different environment. Check the API key."

  defp error_message(_),
    do: "Could not complete sync. Existing transactions are unchanged; sync will retry."
end

defmodule Plausible.Workers.ReconcilePayments do
  @moduledoc "Queues periodic reconciliation for all payment connections."
  use Oban.Worker, queue: :payments
  import Ecto.Query

  @impl Oban.Worker
  def perform(_) do
    Plausible.Repo.all(from(i in Plausible.Payments.Integration, select: i.id))
    |> Enum.each(&Plausible.Payments.enqueue/1)

    :ok
  end
end
