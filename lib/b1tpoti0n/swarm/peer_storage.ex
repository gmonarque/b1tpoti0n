defmodule B1tpoti0n.Swarm.PeerStorage do
  @moduledoc """
  Behaviour for peer storage backends.

  Two implementations available:
  - `PeerStorage.Memory` - In-memory storage (default, single node)
  - `PeerStorage.Redis` - Redis-based storage (multi-node, high-traffic)

  ## Configuration

      config :b1tpoti0n,
        peer_storage: :memory  # or :redis

  When using Redis, ensure Redis is configured:

      config :b1tpoti0n, :redis,
        enabled: true,
        url: "redis://localhost:6379"
  """

  @type info_hash :: binary()
  @type peer_key :: {String.t(), non_neg_integer()}
  @type peer_data :: map()

  @callback get_peer(info_hash(), peer_key()) :: peer_data() | nil
  @callback put_peer(info_hash(), peer_key(), peer_data()) :: :ok
  @callback delete_peer(info_hash(), peer_key()) :: :ok
  @callback get_all_peers(info_hash()) :: %{peer_key() => peer_data()}
  @callback count_peers(info_hash()) :: non_neg_integer()
  @callback cleanup_expired(info_hash(), cutoff_time :: integer()) :: non_neg_integer()
  @callback get_counts(info_hash()) ::
              {seeders :: non_neg_integer(), leechers :: non_neg_integer()}
  @callback clear(info_hash()) :: :ok

  @doc """
  Get the configured storage backend module.
  """
  @spec backend() :: module()
  def backend do
    case Application.get_env(:b1tpoti0n, :peer_storage, :memory) do
      :redis -> B1tpoti0n.Swarm.PeerStorage.Redis
      _ -> B1tpoti0n.Swarm.PeerStorage.Memory
    end
  end

  @doc """
  Delegate to the configured backend.
  """
  def get_peer(info_hash, key), do: backend().get_peer(info_hash, key)
  def put_peer(info_hash, key, data), do: backend().put_peer(info_hash, key, data)
  def delete_peer(info_hash, key), do: backend().delete_peer(info_hash, key)
  def get_all_peers(info_hash), do: backend().get_all_peers(info_hash)
  def count_peers(info_hash), do: backend().count_peers(info_hash)
  def cleanup_expired(info_hash, cutoff), do: backend().cleanup_expired(info_hash, cutoff)
  def get_counts(info_hash), do: backend().get_counts(info_hash)
  def clear(info_hash), do: backend().clear(info_hash)
end
