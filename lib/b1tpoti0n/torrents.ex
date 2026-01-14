defmodule B1tpoti0n.Torrents do
  @moduledoc """
  Torrent management - handles torrent registration, whitelist validation,
  and auto-creation of torrent records.
  """
  import Ecto.Query
  require Logger

  alias B1tpoti0n.Persistence.Repo
  alias B1tpoti0n.Persistence.Schemas.Torrent

  @doc """
  Get or create a torrent record by info_hash.
  Returns {:ok, torrent} or {:error, reason}.

  If `enforce_whitelist` config is true, only returns existing torrents.
  Otherwise, auto-creates new torrents on first announce.
  """
  @spec get_or_create(binary()) :: {:ok, Torrent.t()} | {:error, :not_registered}
  def get_or_create(info_hash) when byte_size(info_hash) == 20 do
    case Repo.get_by(Torrent, info_hash: info_hash) do
      %Torrent{} = torrent ->
        {:ok, torrent}

      nil ->
        if enforce_whitelist?() do
          {:error, :not_registered}
        else
          create_torrent(info_hash)
        end
    end
  end

  @doc """
  Check if a torrent is allowed (exists in DB when whitelist mode is on).
  """
  @spec allowed?(binary()) :: boolean()
  def allowed?(info_hash) do
    if enforce_whitelist?() do
      exists?(info_hash)
    else
      true
    end
  end

  @doc """
  Check if a torrent exists in the database.
  """
  @spec exists?(binary()) :: boolean()
  def exists?(info_hash) do
    Repo.exists?(from t in Torrent, where: t.info_hash == ^info_hash)
  end

  @doc """
  Register a new torrent (for whitelist mode).
  """
  @spec register(binary()) :: {:ok, Torrent.t()} | {:error, Ecto.Changeset.t()}
  def register(info_hash) when byte_size(info_hash) == 20 do
    create_torrent(info_hash)
  end

  @doc """
  Register a torrent by hex-encoded info_hash.
  """
  @spec register_hex(String.t()) :: {:ok, Torrent.t()} | {:error, term()}
  def register_hex(info_hash_hex) when byte_size(info_hash_hex) == 40 do
    case Base.decode16(info_hash_hex, case: :mixed) do
      {:ok, binary} -> register(binary)
      :error -> {:error, :invalid_hex}
    end
  end

  @doc """
  Update torrent stats (seeders, leechers, completed).
  Used by swarm workers for live updates.
  """
  @spec update_stats(integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  def update_stats(torrent_id, seeders, leechers, completed_delta \\ 0) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if completed_delta > 0 do
      Repo.update_all(
        from(t in Torrent, where: t.id == ^torrent_id),
        set: [seeders: seeders, leechers: leechers, updated_at: now],
        inc: [completed: completed_delta]
      )
    else
      Repo.update_all(
        from(t in Torrent, where: t.id == ^torrent_id),
        set: [seeders: seeders, leechers: leechers, updated_at: now]
      )
    end

    :ok
  end

  @doc """
  Set torrent stats directly (for admin corrections).
  Unlike update_stats, this allows setting completed directly.
  """
  @spec set_stats(integer(), keyword()) ::
          {:ok, Torrent.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_stats(torrent_id, stats) do
    case get(torrent_id) do
      nil ->
        {:error, :not_found}

      torrent ->
        changes =
          stats
          |> Keyword.take([:seeders, :leechers, :completed])
          |> Map.new()

        torrent
        |> Torrent.changeset(changes)
        |> Repo.update()
    end
  end

  @doc """
  Get a torrent by ID.
  """
  @spec get(integer()) :: Torrent.t() | nil
  def get(id) do
    Repo.get(Torrent, id)
  end

  @doc """
  Get a torrent by info_hash (binary or hex).
  """
  @spec get_by_info_hash(binary()) :: Torrent.t() | nil
  def get_by_info_hash(info_hash) when byte_size(info_hash) == 20 do
    Repo.get_by(Torrent, info_hash: info_hash)
  end

  def get_by_info_hash(info_hash_hex) when byte_size(info_hash_hex) == 40 do
    case Base.decode16(info_hash_hex, case: :mixed) do
      {:ok, binary} -> get_by_info_hash(binary)
      :error -> nil
    end
  end

  @doc """
  Enable freeleech for a torrent.
  """
  @spec set_freeleech(integer(), boolean(), DateTime.t() | nil) ::
          {:ok, Torrent.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_freeleech(torrent_id, enabled, until \\ nil) do
    case get(torrent_id) do
      nil ->
        {:error, :not_found}

      torrent ->
        torrent
        |> Torrent.changeset(%{freeleech: enabled, freeleech_until: until})
        |> Repo.update()
    end
  end

  @doc """
  Set multipliers for a torrent.
  """
  @spec set_multipliers(integer(), float(), float()) ::
          {:ok, Torrent.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_multipliers(torrent_id, upload_mult, download_mult) do
    case get(torrent_id) do
      nil ->
        {:error, :not_found}

      torrent ->
        torrent
        |> Torrent.changeset(%{
          upload_multiplier: upload_mult,
          download_multiplier: download_mult
        })
        |> Repo.update()
    end
  end

  @doc """
  List all freeleech torrents.
  """
  @spec list_freeleech() :: [Torrent.t()]
  def list_freeleech do
    from(t in Torrent, where: t.freeleech == true)
    |> Repo.all()
  end

  @doc """
  Get torrent settings (freeleech, multipliers) for stats calculation.
  Returns a map with :freeleech_active, :upload_multiplier, :download_multiplier.
  """
  @spec get_settings(Torrent.t()) :: %{
          freeleech_active: boolean(),
          upload_multiplier: float(),
          download_multiplier: float()
        }
  def get_settings(torrent) do
    %{
      freeleech_active: Torrent.freeleech_active?(torrent),
      upload_multiplier: torrent.upload_multiplier,
      download_multiplier: Torrent.effective_download_multiplier(torrent)
    }
  end

  # Private

  defp create_torrent(info_hash) do
    %Torrent{}
    |> Torrent.changeset(%{info_hash: info_hash})
    |> Repo.insert()
    |> case do
      {:ok, torrent} ->
        Logger.info("Auto-registered torrent: #{Base.encode16(info_hash, case: :lower)}")
        {:ok, torrent}

      {:error, %{errors: [info_hash: {"has already been taken", _}]}} ->
        # Race condition - another process created it, fetch it
        {:ok, Repo.get_by!(Torrent, info_hash: info_hash)}

      error ->
        error
    end
  end

  defp enforce_whitelist? do
    Application.get_env(:b1tpoti0n, :enforce_torrent_whitelist, false)
  end
end
