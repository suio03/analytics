defmodule Plausible.Payments.ProviderTest do
  use ExUnit.Case, async: false
  alias Plausible.Payments.{Provider, Integration}

  setup do
    Application.put_env(:plausible, Provider, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:plausible, Provider) end)
    :ok
  end

  test "Paddle pagination uses IDs, includes related records and does not follow arbitrary URLs" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.host == "sandbox-api.paddle.com"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-api-key"]

      if conn.query_params["after"] do
        assert conn.query_params["after"] == "txn_first"
        Req.Test.json(conn, %{"data" => [], "meta" => %{"pagination" => %{"has_more" => false}}})
      else
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "txn_first",
              "status" => "draft",
              "currency_code" => "USD",
              "created_at" => "2026-09-07T00:00:00Z"
            }
          ],
          "meta" => %{
            "pagination" => %{"has_more" => true, "next" => "https://untrusted.example/steal"}
          }
        })
      end
    end)

    assert :ok =
             Provider.sync(
               %Integration{provider: "paddle", environment: "sandbox", api_key: "test-api-key"},
               fn t ->
                 send(parent, t.external_id)
                 :ok
               end
             )

    assert_received "txn_first"
  end

  test "Creem scopes each search to mapped products, enriches the customer and follows pagination" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.host == "api.creem.io"

      case conn.request_path do
        "/v1/products" ->
          Req.Test.json(conn, %{"id" => "prod_pixfy", "name" => "Pixfy Pro"})

        "/v1/customers" ->
          Req.Test.json(conn, %{"email" => "buyer@example.test"})

        "/v1/transactions/search" ->
          assert conn.query_params["product_id"] == "prod_pixfy"

          if conn.query_params["page_number"] == "1" do
            Req.Test.json(conn, %{
              "items" => [
                %{
                  "id" => "tran_1",
                  "mode" => "prod",
                  "customer" => "cust_1",
                  "status" => "paid",
                  "type" => "payment",
                  "amount" => 1299,
                  "currency" => "USD",
                  "created_at" => 1_788_796_800_000
                }
              ],
              "pagination" => %{"total_pages" => 2}
            })
          else
            Req.Test.json(conn, %{"items" => [], "pagination" => %{"total_pages" => 2}})
          end
      end
    end)

    assert :ok =
             Provider.sync(
               %Integration{
                 provider: "creem",
                 environment: "live",
                 api_key: "test",
                 product_ids: ["prod_pixfy"]
               },
               fn t ->
                 send(parent, t)
                 :ok
               end
             )

    assert_received %{
      external_id: "tran_1",
      customer_email: "buyer@example.test",
      product_ids: ["prod_pixfy"]
    }
  end

  test "provider failures do not return response bodies or credentials" do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 401, "sensitive-error-response")
    end)

    assert {:error, {:http, 401}} =
             Provider.sync(
               %Integration{provider: "paddle", environment: "live", api_key: "test"},
               fn _ -> :ok end
             )
  end
end
