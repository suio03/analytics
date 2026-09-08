defmodule Plausible.Payments.Provider do
  @moduledoc "Read-only Paddle Billing and Creem API adapters. Never follows untrusted pagination URLs."
  alias Plausible.Payments.Normalize

  def sync(%{provider: "paddle"} = integration, consume) do
    paddle_page(integration, nil, consume)
  end

  def sync(%{provider: "creem"} = integration, consume) do
    Enum.reduce_while(integration.product_ids, :ok, fn product_id, :ok ->
      with {:ok, product} <- get(integration, "/v1/products", product_id: product_id),
           :ok <- creem_page(integration, product, 1, consume) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp paddle_page(integration, cursor, consume) do
    params = [per_page: 30, include: "customer,address,adjustments", order_by: "id[ASC]"]
    params = if cursor, do: Keyword.put(params, :after, cursor), else: params

    with {:ok, %{"data" => rows, "meta" => meta}} when is_list(rows) <-
           get(integration, "/transactions", params),
         :ok <- consume_all(rows, fn row -> consume.(Normalize.paddle(row)) end) do
      if get_in(meta, ["pagination", "has_more"]) == true do
        next = rows |> List.last() |> Normalize.id()

        if next && next != cursor,
          do: paddle_page(integration, next, consume),
          else: {:error, :invalid_pagination}
      else
        :ok
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  defp creem_page(integration, product, page, consume) do
    with {:ok, %{"items" => rows, "pagination" => pagination}} when is_list(rows) <-
           get(integration, "/v1/transactions/search",
             product_id: product["id"],
             page_number: page,
             page_size: 50
           ),
         :ok <- consume_all(rows, &consume_creem(&1, integration, product, consume)) do
      total_pages = pagination["totalPages"] || pagination["total_pages"]
      more = if is_number(total_pages), do: page < total_pages, else: length(rows) == 50
      if more && rows != [], do: creem_page(integration, product, page + 1, consume), else: :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  defp consume_creem(row, integration, product, consume) do
    modes = if integration.environment == "sandbox", do: ["test", "sandbox"], else: ["prod"]

    with {:ok, customer} <- customer(integration, row["customer"]) do
      if row["mode"] in modes do
        consume.(Normalize.creem(row, product, customer))
      else
        {:error, :environment_mismatch}
      end
    end
  end

  defp customer(_, nil), do: {:ok, %{}}
  defp customer(_, %{} = customer), do: {:ok, customer}
  defp customer(integration, id), do: get(integration, "/v1/customers", customer_id: id)

  defp consume_all(rows, fun) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case fun.(row) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp get(integration, path, params) do
    {base, headers} =
      case {integration.provider, integration.environment} do
        {"paddle", "live"} ->
          {"https://api.paddle.com",
           [{"authorization", "Bearer " <> integration.api_key}, {"paddle-version", "1"}]}

        {"paddle", "sandbox"} ->
          {"https://sandbox-api.paddle.com",
           [{"authorization", "Bearer " <> integration.api_key}, {"paddle-version", "1"}]}

        {"creem", "live"} ->
          {"https://api.creem.io", [{"x-api-key", integration.api_key}]}

        {"creem", "sandbox"} ->
          {"https://test-api.creem.io", [{"x-api-key", integration.api_key}]}
      end

    opts = Application.get_env(:plausible, __MODULE__, [])

    case Req.get(
           [
             url: base <> path,
             headers: headers,
             params: params,
             receive_timeout: 30_000,
             retry: false,
             redirect: false
           ] ++ opts
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, _} -> {:error, :connection_failed}
    end
  end
end
