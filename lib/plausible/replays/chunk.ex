defmodule Plausible.Replays.Chunk do
  @moduledoc "One batch of rrweb events as the recorder posted it."
  use Ecto.Schema

  @primary_key false
  schema "replay_chunks" do
    field :site_id, Ch, type: "UInt64"
    field :session_id, :string
    field :visitor_id, :string
    field :load_id, :string
    field :seq, Ch, type: "UInt32"
    field :started_at, Ch, type: "DateTime64(3, 'UTC')"
    field :ended_at, Ch, type: "DateTime64(3, 'UTC')"
    field :received_at, Ch, type: "DateTime64(3, 'UTC')"
    field :events, Ch, type: "UInt32"
    field :data, :string
  end
end
